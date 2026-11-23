import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_provider_config.dart';

/// Supported OpenAI wire protocols.
enum OpenAiWireProtocol {
  /// OpenAI's modern Responses API (`POST /responses`).
  responses,

  /// Traditional OpenAI Chat Completions API (`POST /chat/completions`).
  chatCompletions,
}

/// Normalized API root and optional pinned wire protocol derived from a user's
/// configured base URL.
class OpenAiEndpointTarget {
  const OpenAiEndpointTarget({
    required this.apiBaseUrl,
    this.explicitProtocol,
  });

  final String apiBaseUrl;
  final OpenAiWireProtocol? explicitProtocol;
}

/// Image payload attached to a multimodal OpenAI request.
class OpenAiImageAttachment {
  const OpenAiImageAttachment({
    required this.bytes,
    this.detail = 'auto',
    this.mimeType,
  });

  final Uint8List bytes;
  final String detail;
  final String? mimeType;

  String get resolvedMimeType =>
      mimeType ?? OpenAiApiProtocol.detectImageMimeType(bytes);

  String get dataUrl => 'data:$resolvedMimeType;base64,${base64Encode(bytes)}';
}

typedef OpenAiPostExecutor = Future<Response<dynamic>> Function(
  Dio dio,
  String path, {
  required Map<String, dynamic> data,
  Options? options,
});

class _EndpointCapabilityProfile {
  _EndpointCapabilityProfile({
    this.preferredProtocol,
    required this.responsesIncludeMaxOutputTokens,
    required this.responsesIncludeTemperature,
    required this.responsesIncludeStoreFalse,
    required this.responsesForceStream,
    required this.responsesRequireInstructions,
    required this.chatUseMaxCompletionTokens,
    required this.chatIncludeTemperature,
    required this.chatSystemRole,
  });

  factory _EndpointCapabilityProfile.initial({required String model}) {
    final isModern = OpenAiApiProtocol.isModernOpenAiModel(model);
    return _EndpointCapabilityProfile(
      responsesIncludeMaxOutputTokens: true,
      responsesIncludeTemperature: !isModern,
      responsesIncludeStoreFalse: false,
      responsesForceStream: false,
      responsesRequireInstructions: false,
      chatUseMaxCompletionTokens: isModern,
      chatIncludeTemperature: !isModern,
      chatSystemRole: 'system',
    );
  }

  OpenAiWireProtocol? preferredProtocol;
  bool responsesIncludeMaxOutputTokens;
  bool responsesIncludeTemperature;
  bool responsesIncludeStoreFalse;
  bool responsesForceStream;
  bool responsesRequireInstructions;
  bool chatUseMaxCompletionTokens;
  bool chatIncludeTemperature;
  String chatSystemRole;

  _EndpointCapabilityProfile copy() {
    return _EndpointCapabilityProfile(
      preferredProtocol: preferredProtocol,
      responsesIncludeMaxOutputTokens: responsesIncludeMaxOutputTokens,
      responsesIncludeTemperature: responsesIncludeTemperature,
      responsesIncludeStoreFalse: responsesIncludeStoreFalse,
      responsesForceStream: responsesForceStream,
      responsesRequireInstructions: responsesRequireInstructions,
      chatUseMaxCompletionTokens: chatUseMaxCompletionTokens,
      chatIncludeTemperature: chatIncludeTemperature,
      chatSystemRole: chatSystemRole,
    );
  }
}

class _ErrorDiagnostics {
  const _ErrorDiagnostics({
    required this.statusCode,
    required this.normalizedText,
    required this.code,
    required this.param,
  });

  final int? statusCode;
  final String normalizedText;
  final String code;
  final String param;
}

/// Bridges modern OpenAI Responses API (`/responses`) and OpenAI Chat
/// Completions API (`/chat/completions`), including automatic protocol
/// negotiation, reasoning-model parameter normalization, HTTP 400 parameter
/// self-healing, and unified JSON/SSE response extraction.
class OpenAiApiProtocol {
  static final RegExp _modernGptPattern = RegExp(
    r'^gpt-(?:[5-9]|\d{2,})(?:[.\-_]|$)',
  );
  static final RegExp _oSeriesPattern = RegExp(
    r'^o[1-9]\d*(?:[.\-_]|$)',
  );
  static final RegExp _codexPattern = RegExp(
    r'(?:^|-)codex(?:[.\-_]|$)',
  );
  static final RegExp _computerUsePattern = RegExp(
    r'^computer-use(?:[.\-_]|$)',
  );

  static const int _maxParameterAdjustmentsPerProtocol = 3;

  final Map<String, _EndpointCapabilityProfile> _profiles =
      <String, _EndpointCapabilityProfile>{};

  /// Splits an optional explicit `/responses` or `/chat/completions` suffix
  /// from [AiProviderConfig.effectiveBaseUrl] so `/models` and endpoint routing
  /// both work even when a user pastes a full endpoint URL.
  static OpenAiEndpointTarget resolveEndpointTarget(AiProviderConfig config) {
    final effective = config.effectiveBaseUrl;
    final lower = effective.toLowerCase();
    const responsesSuffix = '/responses';
    const chatSuffix = '/chat/completions';

    if (lower.endsWith(responsesSuffix)) {
      return OpenAiEndpointTarget(
        apiBaseUrl: effective.substring(
          0,
          effective.length - responsesSuffix.length,
        ),
        explicitProtocol: OpenAiWireProtocol.responses,
      );
    }
    if (lower.endsWith(chatSuffix)) {
      return OpenAiEndpointTarget(
        apiBaseUrl: effective.substring(
          0,
          effective.length - chatSuffix.length,
        ),
        explicitProtocol: OpenAiWireProtocol.chatCompletions,
      );
    }
    return OpenAiEndpointTarget(apiBaseUrl: effective);
  }

  /// Strips an optional `provider/` prefix (e.g. `openai/gpt-5.5` -> `gpt-5.5`)
  /// and normalizes casing.
  static String normalizeModelName(String model) {
    final trimmed = model.trim().toLowerCase();
    final slashIndex = trimmed.lastIndexOf('/');
    return slashIndex >= 0 ? trimmed.substring(slashIndex + 1) : trimmed;
  }

  /// Returns `true` for modern OpenAI reasoning / GPT-5+ / GPT-6+ / o-series /
  /// Codex models that target the Responses API and require modern Chat
  /// Completions parameter rules (`max_completion_tokens`, no `temperature`).
  static bool isModernOpenAiModel(String model) {
    final normalized = normalizeModelName(model);
    if (normalized.isEmpty) return false;
    return _modernGptPattern.hasMatch(normalized) ||
        _oSeriesPattern.hasMatch(normalized) ||
        _codexPattern.hasMatch(normalized) ||
        _computerUsePattern.hasMatch(normalized);
  }

  static bool isOfficialOpenAiHost(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase();
    return host == 'api.openai.com';
  }

  /// Returns `true` only when the configuration targets Google's native Gemini
  /// REST API rather than an OpenAI-compatible `/v1` or OpenRouter gateway.
  static bool isGeminiNativeEndpoint(AiProviderConfig config) {
    final target = resolveEndpointTarget(config);
    if (target.explicitProtocol != null) return false;
    final model = config.model.trim().toLowerCase();
    if (!model.contains('gemini')) return false;
    final baseUrl = target.apiBaseUrl.toLowerCase();
    if (baseUrl.contains('/v1') ||
        baseUrl.contains('openrouter') ||
        baseUrl.contains('openai')) {
      return false;
    }
    return true;
  }

  /// Detects common image MIME types from magic bytes instead of assuming JPEG.
  static String detectImageMimeType(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  /// Computes a model-safe token cap:
  /// - Enforces OpenAI Responses API's minimum of `16`.
  /// - Gives modern reasoning models enough headroom so hidden reasoning tokens
  ///   do not exhaust the budget before emitting the answer.
  static int resolveTokenBudget({
    required String model,
    required int requestedMaxTokens,
    required OpenAiWireProtocol protocol,
    required bool isProbe,
  }) {
    final isModern = isModernOpenAiModel(model);
    if (isProbe) {
      if (protocol == OpenAiWireProtocol.responses || isModern) {
        return math.max(64, requestedMaxTokens);
      }
      return math.max(16, requestedMaxTokens);
    }

    if (isModern) {
      if (requestedMaxTokens <= 256) {
        return math.max(512, requestedMaxTokens);
      }
      return math.max(requestedMaxTokens, math.min(requestedMaxTokens * 2, 8192));
    }

    if (protocol == OpenAiWireProtocol.responses) {
      return math.max(16, requestedMaxTokens);
    }
    return requestedMaxTokens;
  }

  /// Builds an OpenAI Responses API (`POST /responses`) request body.
  static Map<String, dynamic> buildResponsesPayload({
    required String model,
    required String prompt,
    String? systemPrompt,
    OpenAiImageAttachment? image,
    required int maxOutputTokens,
    double? temperature,
    bool includeMaxOutputTokens = true,
    bool includeTemperature = false,
    bool includeStoreFalse = false,
    bool forceStream = false,
    bool requireInstructions = false,
  }) {
    final content = <Map<String, dynamic>>[
      if (image != null)
        <String, dynamic>{
          'type': 'input_image',
          'image_url': image.dataUrl,
          'detail': image.detail,
        },
      <String, dynamic>{
        'type': 'input_text',
        'text': prompt,
      },
    ];

    final trimmedSystem = systemPrompt?.trim() ?? '';
    return <String, dynamic>{
      'model': model,
      if (trimmedSystem.isNotEmpty)
        'instructions': trimmedSystem
      else if (requireInstructions)
        'instructions': '',
      'input': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': content,
        },
      ],
      if (includeMaxOutputTokens)
        'max_output_tokens': math.max(16, maxOutputTokens),
      if (includeTemperature && temperature != null) 'temperature': temperature,
      if (includeStoreFalse) 'store': false,
      if (forceStream) 'stream': true,
    };
  }

  /// Builds an OpenAI Chat Completions (`POST /chat/completions`) request body.
  static Map<String, dynamic> buildChatCompletionsPayload({
    required String model,
    required String prompt,
    String? systemPrompt,
    OpenAiImageAttachment? image,
    required int maxTokens,
    double? temperature,
    required bool useMaxCompletionTokens,
    required bool includeTemperature,
    String systemRole = 'system',
  }) {
    final trimmedSystem = systemPrompt?.trim() ?? '';
    final effectivePrompt = (trimmedSystem.isNotEmpty && systemRole == 'inline')
        ? '$trimmedSystem\n\n$prompt'
        : prompt;

    final userContent = image == null
        ? effectivePrompt
        : <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, String>{
                'url': image.dataUrl,
                'detail': image.detail,
              },
            },
            <String, dynamic>{
              'type': 'text',
              'text': effectivePrompt,
            },
          ];

    final messages = <Map<String, dynamic>>[
      if (trimmedSystem.isNotEmpty && systemRole != 'inline')
        <String, dynamic>{
          'role': systemRole,
          'content': trimmedSystem,
        },
      <String, dynamic>{
        'role': 'user',
        'content': userContent,
      },
    ];

    return <String, dynamic>{
      'model': model,
      'messages': messages,
      if (includeTemperature && temperature != null) 'temperature': temperature,
      if (useMaxCompletionTokens)
        'max_completion_tokens': maxTokens
      else
        'max_tokens': maxTokens,
    };
  }

  /// Clears cached protocol/parameter capabilities for [config]. Useful before
  /// an explicit connection probe so endpoint changes take effect immediately.
  void clearCachedProfile(AiProviderConfig config) {
    _profiles.remove(_cacheKey(config));
  }

  /// Selects the initial wire protocol for [config] considering explicit URL
  /// suffixes, cached endpoint capabilities, official OpenAI hosts, and modern
  /// OpenAI model families.
  OpenAiWireProtocol selectProtocol(AiProviderConfig config) {
    final target = resolveEndpointTarget(config);
    if (target.explicitProtocol != null) {
      return target.explicitProtocol!;
    }
    final cached = _profiles[_cacheKey(config)]?.preferredProtocol;
    if (cached != null) return cached;
    if (isOfficialOpenAiHost(target.apiBaseUrl) ||
        isModernOpenAiModel(config.model)) {
      return OpenAiWireProtocol.responses;
    }
    return OpenAiWireProtocol.chatCompletions;
  }

  /// Sends a text or multimodal request using the preferred OpenAI wire
  /// protocol, automatically self-healing HTTP 400 parameter mismatches and
  /// falling back between `/responses` and `/chat/completions` when an endpoint
  /// only supports one protocol.
  Future<Response<dynamic>> sendRequest({
    required Dio dio,
    required AiProviderConfig config,
    required String prompt,
    String? systemPrompt,
    OpenAiImageAttachment? image,
    required int maxTokens,
    double? temperature,
    bool isProbe = false,
    required OpenAiPostExecutor postExecutor,
  }) async {
    final target = resolveEndpointTarget(config);
    final cacheKey = _cacheKey(config);
    final profile = (_profiles[cacheKey] ??
            _EndpointCapabilityProfile.initial(model: config.model))
        .copy();
    final primary = selectProtocol(config);

    try {
      final response = await _sendWithProtocol(
        dio: dio,
        config: config,
        protocol: primary,
        profile: profile,
        prompt: prompt,
        systemPrompt: systemPrompt,
        image: image,
        maxTokens: maxTokens,
        temperature: temperature,
        isProbe: isProbe,
        postExecutor: postExecutor,
      );
      profile.preferredProtocol = primary;
      _profiles[cacheKey] = profile;
      return response;
    } on DioException catch (e) {
      if (target.explicitProtocol != null) rethrow;

      final alternate = primary == OpenAiWireProtocol.responses
          ? OpenAiWireProtocol.chatCompletions
          : OpenAiWireProtocol.responses;
      final canFallback = primary == OpenAiWireProtocol.responses
          ? shouldFallbackResponsesToChat(e)
          : shouldFallbackChatToResponses(e);

      if (!canFallback) rethrow;

      debugPrint(
        '[OpenAiApiProtocol] $primary unsupported for ${config.model} '
        '(HTTP ${e.response?.statusCode}), falling back to $alternate',
      );
      final response = await _sendWithProtocol(
        dio: dio,
        config: config,
        protocol: alternate,
        profile: profile,
        prompt: prompt,
        systemPrompt: systemPrompt,
        image: image,
        maxTokens: maxTokens,
        temperature: temperature,
        isProbe: isProbe,
        postExecutor: postExecutor,
      );
      profile.preferredProtocol = alternate;
      _profiles[cacheKey] = profile;
      return response;
    }
  }

  Future<Response<dynamic>> _sendWithProtocol({
    required Dio dio,
    required AiProviderConfig config,
    required OpenAiWireProtocol protocol,
    required _EndpointCapabilityProfile profile,
    required String prompt,
    String? systemPrompt,
    OpenAiImageAttachment? image,
    required int maxTokens,
    double? temperature,
    required bool isProbe,
    required OpenAiPostExecutor postExecutor,
  }) async {
    for (var attempt = 0;
        attempt <= _maxParameterAdjustmentsPerProtocol;
        attempt++) {
      final tokenBudget = resolveTokenBudget(
        model: config.model,
        requestedMaxTokens: maxTokens,
        protocol: protocol,
        isProbe: isProbe,
      );

      final String path;
      final Map<String, dynamic> payload;
      Options? options;

      if (protocol == OpenAiWireProtocol.responses) {
        path = '/responses';
        payload = buildResponsesPayload(
          model: config.model,
          prompt: prompt,
          systemPrompt: systemPrompt,
          image: image,
          maxOutputTokens: tokenBudget,
          temperature: temperature,
          includeMaxOutputTokens: profile.responsesIncludeMaxOutputTokens,
          includeTemperature: profile.responsesIncludeTemperature,
          includeStoreFalse: profile.responsesIncludeStoreFalse,
          forceStream: profile.responsesForceStream,
          requireInstructions: profile.responsesRequireInstructions,
        );
        if (profile.responsesForceStream) {
          options = Options(responseType: ResponseType.plain);
        }
      } else {
        path = '/chat/completions';
        payload = buildChatCompletionsPayload(
          model: config.model,
          prompt: prompt,
          systemPrompt: systemPrompt,
          image: image,
          maxTokens: tokenBudget,
          temperature: temperature,
          useMaxCompletionTokens: profile.chatUseMaxCompletionTokens,
          includeTemperature: profile.chatIncludeTemperature,
          systemRole: profile.chatSystemRole,
        );
      }

      try {
        return await postExecutor(dio, path, data: payload, options: options);
      } on DioException catch (e) {
        final adjusted = protocol == OpenAiWireProtocol.responses
            ? _tryAdjustResponsesProfile(e, profile)
            : _tryAdjustChatProfile(e, profile);
        if (!adjusted || attempt >= _maxParameterAdjustmentsPerProtocol) {
          rethrow;
        }
        debugPrint(
          '[OpenAiApiProtocol] Adjusted $protocol parameters after HTTP '
          '${e.response?.statusCode}, retrying...',
        );
      }
    }
    throw StateError('Unreachable retry state in OpenAiApiProtocol.');
  }

  /// Extracts assistant text from a Dio [Response] in any supported OpenAI
  /// format: Responses JSON (`output_text` / `output[]`), Chat Completions JSON
  /// (`choices[].message.content` string or part array), Responses SSE, Chat
  /// Completions SSE, or native Gemini JSON.
  static String extractTextFromResponse(Response<dynamic> response) {
    return extractTextFromPayload(response.data);
  }

  /// Extracts assistant text from a raw decoded JSON map or raw response string
  /// (JSON or SSE).
  static String extractTextFromPayload(dynamic rawData) {
    dynamic data = rawData;
    if (data is String) {
      final cleaned = _stripBom(data).trim();
      if (_looksLikeSse(cleaned)) {
        return extractTextFromSse(cleaned);
      }
      data = jsonDecode(cleaned);
    }

    if (data is! Map) {
      throw const FormatException('AI response payload is not a JSON object.');
    }

    final map = Map<String, dynamic>.from(data);

    // 1. OpenAI Responses API format (`output_text` or `output` array).
    final topOutputText = map['output_text'];
    if (topOutputText is String && topOutputText.isNotEmpty) {
      return topOutputText;
    }

    if (map['output'] is List) {
      final extracted = _extractFromResponsesOutput(map['output'] as List);
      if (extracted.text.isNotEmpty) {
        return extracted.text;
      }
      final errMsg = extractErrorMessageFromBody(map);
      if (errMsg != null) {
        throw FormatException('AI response error: $errMsg');
      }
      if (extracted.refusal.isNotEmpty) {
        throw FormatException('AI refused request: ${extracted.refusal}');
      }
      if (map['status'] == 'incomplete') {
        final details = map['incomplete_details'];
        final reason = details is Map ? details['reason'] : null;
        throw FormatException(
          'Incomplete AI response (${reason ?? 'unknown'}): no output text.',
        );
      }
      throw const FormatException('Empty Responses API output text.');
    }

    // Nested Responses envelope (e.g. `{"response": {...}}`).
    if (map['response'] is Map && map['choices'] == null) {
      return extractTextFromPayload(map['response']);
    }

    // 2. OpenAI Chat Completions format (`choices`).
    final choices = map['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final choice = Map<String, dynamic>.from(choices.first as Map);
      final message = choice['message'];
      if (message is Map) {
        final messageMap = Map<String, dynamic>.from(message);
        final text = _extractTextFromContentValue(messageMap['content']);
        if (text != null && text.isNotEmpty) {
          return text;
        }
        final refusal = messageMap['refusal'];
        if (refusal is String && refusal.trim().isNotEmpty) {
          throw FormatException('AI refused request: ${refusal.trim()}');
        }
        if (text != null) {
          if (choice['finish_reason'] == 'length') {
            throw const FormatException(
              'Incomplete AI response (length): empty completion content.',
            );
          }
          return text;
        }
      }

      final delta = choice['delta'];
      if (delta is Map) {
        final text = _extractTextFromContentValue(delta['content']);
        if (text != null) return text;
      }

      final legacyText = choice['text'];
      if (legacyText is String) {
        return legacyText;
      }
    }

    // 3. Gemini native format (`candidates`).
    final candidates = map['candidates'];
    if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
      final candidate = candidates.first as Map;
      final content = candidate['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is List) {
        final buffer = StringBuffer();
        for (final part in parts) {
          if (part is! Map) continue;
          if (part['thought'] == true) continue;
          final text = part['text'];
          if (text is String) buffer.write(text);
        }
        if (buffer.isNotEmpty) {
          return buffer.toString();
        }
      }
    }

    final errorMessage = extractErrorMessageFromBody(map);
    if (errorMessage != null) {
      throw FormatException('AI response error: $errorMessage');
    }

    throw const FormatException('Unrecognized AI response format.');
  }

  /// Extracts assistant text from either Responses API SSE streams
  /// (`response.output_text.delta`, `response.output_text.done`,
  /// `response.output_item.done`, `response.completed`) or Chat Completions SSE
  /// streams (`choices[0].delta.content`).
  static String extractTextFromSse(String body) {
    final responsesDeltaBuffer = StringBuffer();
    final responsesDoneTextBuffer = StringBuffer();
    final responsesItemDoneBuffer = StringBuffer();
    final chatBuffer = StringBuffer();
    Map<String, dynamic>? completedResponse;
    String? sseError;
    String? currentEvent;

    for (final rawLine in const LineSplitter().convert(_stripBom(body))) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        currentEvent = null;
        continue;
      }
      if (trimmed.startsWith(':')) continue;
      if (trimmed.startsWith('event:')) {
        currentEvent = trimmed.substring(6).trim();
        continue;
      }
      if (!trimmed.startsWith('data:')) continue;

      final payload = trimmed.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;

      dynamic decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final json = Map<String, dynamic>.from(decoded);
      final eventType = (json['type'] as String?) ?? currentEvent;

      // Responses API streaming events.
      if (eventType == 'response.output_text.delta') {
        final delta = json['delta'];
        if (delta is String) {
          responsesDeltaBuffer.write(delta);
        }
        continue;
      }
      if (eventType == 'response.output_text.done') {
        final text = json['text'];
        if (text is String && text.isNotEmpty) {
          responsesDoneTextBuffer.write(text);
        }
        continue;
      }
      if (eventType == 'response.output_item.done') {
        final item = json['item'];
        if (item is Map) {
          final extracted = _extractFromResponsesOutput(<dynamic>[item]);
          if (extracted.text.isNotEmpty) {
            responsesItemDoneBuffer.write(extracted.text);
          }
        }
        continue;
      }
      if (eventType == 'response.completed' ||
          eventType == 'response.incomplete') {
        final responseObj = json['response'];
        if (responseObj is Map) {
          completedResponse = Map<String, dynamic>.from(responseObj);
        }
        continue;
      }
      if (eventType == 'response.failed' || eventType == 'error') {
        sseError ??= extractErrorMessageFromBody(json) ??
            extractErrorMessageFromBody(json['response']) ??
            payload;
        continue;
      }

      // Chat Completions streaming chunks.
      final choices = json['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final choice = choices.first as Map;
        final delta = choice['delta'];
        final message = choice['message'];
        final content = delta is Map
            ? _extractTextFromContentValue(delta['content'])
            : message is Map
                ? _extractTextFromContentValue(message['content'])
                : null;
        if (content != null && content.isNotEmpty) {
          chatBuffer.write(content);
        }
      }
    }

    if (responsesDeltaBuffer.isNotEmpty) {
      return responsesDeltaBuffer.toString();
    }
    if (responsesDoneTextBuffer.isNotEmpty) {
      return responsesDoneTextBuffer.toString();
    }
    if (responsesItemDoneBuffer.isNotEmpty) {
      return responsesItemDoneBuffer.toString();
    }
    if (completedResponse != null) {
      try {
        final extracted = extractTextFromPayload(completedResponse);
        if (extracted.isNotEmpty) return extracted;
      } on FormatException {
        // Fall through to chat buffer / error handling.
      }
    }
    if (chatBuffer.isNotEmpty) {
      return chatBuffer.toString();
    }
    if (sseError != null) {
      throw FormatException('SSE error: $sseError');
    }
    throw const FormatException('Empty SSE chat completion content.');
  }

  /// Validates an HTTP 200 connection probe response. Does not require full
  /// visible text (a reasoning model probe with a small token cap may stop with
  /// `status: "incomplete"`), but rejects HTTP 200 error wrappers.
  static void validateProbeResponse(Response<dynamic> response) {
    dynamic data = response.data;
    if (data == null) return;

    if (data is String) {
      final cleaned = _stripBom(data).trim();
      if (cleaned.isEmpty) return;
      if (_looksLikeSse(cleaned)) {
        for (final line in const LineSplitter().convert(cleaned)) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final payload = trimmed.substring(5).trim();
          if (payload.isEmpty || payload == '[DONE]') continue;
          dynamic decoded;
          try {
            decoded = jsonDecode(payload);
          } on FormatException {
            continue;
          }
          if (decoded is Map) {
            final type = decoded['type'];
            if (type == 'error' || type == 'response.failed') {
              final err = extractErrorMessageFromBody(decoded) ??
                  extractErrorMessageFromBody(decoded['response']) ??
                  payload;
              throw FormatException(err);
            }
          }
        }
        return;
      }
      try {
        data = jsonDecode(cleaned);
      } on FormatException {
        return;
      }
    }

    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final errorMessage = extractErrorMessageFromBody(map);
      if (errorMessage != null) {
        throw FormatException(errorMessage);
      }
      if (map['status'] == 'failed') {
        throw const FormatException('模型返回失败状态');
      }
    }
  }

  /// Extracts a human-readable error message from a Map or JSON-encoded String
  /// response body, if an `error` field is present.
  static String? extractErrorMessageFromBody(dynamic body) {
    dynamic decoded = body;
    if (decoded is String) {
      final trimmed = _stripBom(decoded).trim();
      if (trimmed.isEmpty) return null;
      if (trimmed.startsWith('{')) {
        try {
          decoded = jsonDecode(trimmed);
        } on FormatException {
          return null;
        }
      } else {
        return null;
      }
    }

    if (decoded is! Map) return null;
    final error = decoded['error'];
    if (error == null) return null;
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
      return error.toString();
    }
    final text = error.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Returns `true` when an error from `POST /responses` indicates the gateway
  /// does not implement or route the Responses API and should fall back to
  /// `POST /chat/completions`.
  static bool shouldFallbackResponsesToChat(DioException error) {
    final diag = _diagnose(error);
    final status = diag.statusCode;
    if (status == null) return false;
    if (status == 401 ||
        status == 402 ||
        status == 403 ||
        status == 408 ||
        status == 429 ||
        status == 524) {
      return false;
    }

    final text = diag.normalizedText;
    final isModelNotFound = diag.code == 'model_not_found' ||
        (RegExp(r'\bmodel\b.*(not found|does not exist)').hasMatch(text) &&
            !text.contains('responses') &&
            !text.contains('endpoint') &&
            !text.contains('chat/completions'));

    if (status == 404 || status == 405 || status == 501) {
      return !isModelNotFound;
    }

    if (status == 400 ||
        status == 422 ||
        status == 500 ||
        status == 502 ||
        status == 503) {
      if (text.contains('chat/completions')) return true;
      if (text.contains('not implemented') ||
          text.contains('unknown endpoint') ||
          text.contains('unrecognized request url') ||
          text.contains('invalid url') ||
          text.contains('unknown path') ||
          text.contains('route not found')) {
        return true;
      }
      if ((text.contains('responses api') || text.contains('/responses')) &&
          (text.contains('not supported') ||
              text.contains('unsupported') ||
              text.contains('not found') ||
              text.contains('disabled') ||
              text.contains('unknown'))) {
        return true;
      }
      if (text.contains('messages') &&
          (text.contains('required') || text.contains('missing'))) {
        return true;
      }
      if ((diag.param == 'input' ||
              RegExp(r'''['"`]input['"`]''').hasMatch(text)) &&
          (text.contains('unknown parameter') ||
              text.contains('unsupported parameter') ||
              text.contains('unknown field') ||
              text.contains('unrecognized'))) {
        return true;
      }
    }

    return false;
  }

  /// Returns `true` when an error from `POST /chat/completions` indicates the
  /// model or server requires the OpenAI Responses API (`/responses`).
  static bool shouldFallbackChatToResponses(DioException error) {
    final diag = _diagnose(error);
    final status = diag.statusCode;
    if (status == null) return false;
    if (status == 401 ||
        status == 402 ||
        status == 403 ||
        status == 408 ||
        status == 429 ||
        status == 524) {
      return false;
    }

    final text = diag.normalizedText;
    final mentionsResponses = text.contains('v1/responses') ||
        text.contains('/responses') ||
        text.contains('responses api') ||
        text.contains('responses endpoint') ||
        text.contains('not a chat model');

    if (mentionsResponses) {
      return status == 400 ||
          status == 404 ||
          status == 405 ||
          status == 422 ||
          status == 501;
    }

    if (status == 404 || status == 405 || status == 501) {
      final isModelNotFound = diag.code == 'model_not_found' ||
          RegExp(r'\bmodel\b.*(not found|does not exist)').hasMatch(text);
      return !isModelNotFound;
    }

    return false;
  }

  bool _tryAdjustResponsesProfile(
    DioException error,
    _EndpointCapabilityProfile profile,
  ) {
    final diag = _diagnose(error);
    if (diag.statusCode != 400 && diag.statusCode != 422) return false;
    final text = diag.normalizedText;
    final param = diag.param;
    var adjusted = false;

    if (profile.responsesIncludeMaxOutputTokens &&
        (param == 'max_output_tokens' || text.contains('max_output_tokens')) &&
        _looksLikeUnsupportedParam(text)) {
      profile.responsesIncludeMaxOutputTokens = false;
      adjusted = true;
    }

    if (profile.responsesIncludeTemperature &&
        (param == 'temperature' || text.contains('temperature')) &&
        (_looksLikeUnsupportedParam(text) || text.contains('default'))) {
      profile.responsesIncludeTemperature = false;
      adjusted = true;
    }

    if (!profile.responsesIncludeStoreFalse &&
        (param == 'store' || text.contains('store')) &&
        (text.contains('false') ||
            text.contains('must be') ||
            text.contains('required'))) {
      profile.responsesIncludeStoreFalse = true;
      adjusted = true;
    }

    if (!profile.responsesForceStream &&
        (param == 'stream' || text.contains('stream')) &&
        (text.contains('true') ||
            text.contains('must be') ||
            text.contains('required'))) {
      profile.responsesForceStream = true;
      adjusted = true;
    }

    if (!profile.responsesRequireInstructions &&
        (param == 'instructions' || text.contains('instructions')) &&
        (text.contains('required') ||
            text.contains('missing') ||
            text.contains('must be'))) {
      profile.responsesRequireInstructions = true;
      adjusted = true;
    }

    return adjusted;
  }

  bool _tryAdjustChatProfile(
    DioException error,
    _EndpointCapabilityProfile profile,
  ) {
    final diag = _diagnose(error);
    if (diag.statusCode != 400 && diag.statusCode != 422) return false;
    final text = diag.normalizedText;
    final param = diag.param;
    var adjusted = false;

    if (!profile.chatUseMaxCompletionTokens &&
        (param == 'max_tokens' || text.contains('max_tokens')) &&
        (text.contains('max_completion_tokens') ||
            _looksLikeUnsupportedParam(text))) {
      profile.chatUseMaxCompletionTokens = true;
      adjusted = true;
    } else if (profile.chatUseMaxCompletionTokens &&
        (param == 'max_completion_tokens' ||
            text.contains('max_completion_tokens')) &&
        (_looksLikeUnsupportedParam(text) || text.contains('max_tokens'))) {
      profile.chatUseMaxCompletionTokens = false;
      adjusted = true;
    }

    if (profile.chatIncludeTemperature &&
        (param == 'temperature' || text.contains('temperature')) &&
        (_looksLikeUnsupportedParam(text) ||
            text.contains('default') ||
            text.contains('only'))) {
      profile.chatIncludeTemperature = false;
      adjusted = true;
    }

    if (profile.chatSystemRole == 'system' &&
        (param.contains('role') || text.contains('role')) &&
        text.contains('system') &&
        _looksLikeUnsupportedParam(text)) {
      profile.chatSystemRole =
          text.contains('developer') ? 'developer' : 'inline';
      adjusted = true;
    } else if (profile.chatSystemRole == 'developer' &&
        (param.contains('role') || text.contains('role')) &&
        text.contains('developer') &&
        _looksLikeUnsupportedParam(text)) {
      profile.chatSystemRole = 'inline';
      adjusted = true;
    }

    return adjusted;
  }

  static bool _looksLikeUnsupportedParam(String normalizedText) {
    return normalizedText.contains('unsupported') ||
        normalizedText.contains('not supported') ||
        normalizedText.contains('unknown parameter') ||
        normalizedText.contains('unrecognized') ||
        normalizedText.contains('unexpected') ||
        normalizedText.contains('not allowed') ||
        normalizedText.contains('invalid');
  }

  static _ErrorDiagnostics _diagnose(DioException error) {
    final statusCode = error.response?.statusCode;
    dynamic body = error.response?.data;
    if (body is String) {
      final trimmed = _stripBom(body).trim();
      if (trimmed.startsWith('{')) {
        try {
          body = jsonDecode(trimmed);
        } on FormatException {
          // Keep original string for text matching.
        }
      }
    }

    final parts = <String>[];
    var code = '';
    var param = '';

    if (body is Map) {
      final err = body['error'];
      if (err is Map) {
        if (err['message'] != null) parts.add(err['message'].toString());
        if (err['type'] != null) parts.add(err['type'].toString());
        if (err['code'] != null) {
          code = err['code'].toString().toLowerCase();
          parts.add(code);
        }
        if (err['param'] != null) {
          param = err['param'].toString().toLowerCase();
          parts.add(param);
        }
      } else if (err != null) {
        parts.add(err.toString());
      }
      if (body['message'] != null) parts.add(body['message'].toString());
      if (body['detail'] != null) parts.add(body['detail'].toString());
    } else if (body != null) {
      parts.add(body.toString());
    }
    if (error.message != null) {
      parts.add(error.message!);
    }

    return _ErrorDiagnostics(
      statusCode: statusCode,
      normalizedText: parts.join(' ').toLowerCase(),
      code: code,
      param: param,
    );
  }

  static ({String text, String refusal}) _extractFromResponsesOutput(
    List<dynamic> output,
  ) {
    final textBuffer = StringBuffer();
    final refusalBuffer = StringBuffer();

    for (final rawItem in output) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final type = item['type'] as String?;

      // Skip reasoning / tool call items so internal thoughts never pollute
      // structured output.
      if (type == 'reasoning' ||
          type == 'function_call' ||
          type == 'web_search_call' ||
          type == 'file_search_call' ||
          type == 'code_interpreter_call' ||
          type == 'computer_call') {
        continue;
      }

      if (type == 'output_text' || type == 'text') {
        final text = item['text'];
        if (text is String) textBuffer.write(text);
        continue;
      }

      final content = item['content'];
      if (content is String) {
        textBuffer.write(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is String) {
            textBuffer.write(part);
            continue;
          }
          if (part is! Map) continue;
          final partType = part['type'] as String?;
          if (partType == 'refusal') {
            final refusal = part['refusal'];
            if (refusal is String && refusal.trim().isNotEmpty) {
              if (refusalBuffer.isNotEmpty) refusalBuffer.write(' ');
              refusalBuffer.write(refusal.trim());
            }
            continue;
          }
          if (partType == 'reasoning' || partType == 'thinking') continue;
          if (partType == null ||
              partType == 'output_text' ||
              partType == 'text') {
            final text = part['text'];
            if (text is String) textBuffer.write(text);
          }
        }
      }
    }

    return (text: textBuffer.toString(), refusal: refusalBuffer.toString());
  }

  static String? _extractTextFromContentValue(dynamic content) {
    if (content is String) return content;
    if (content is List) {
      final buffer = StringBuffer();
      var sawTextPart = false;
      for (final part in content) {
        if (part is String) {
          buffer.write(part);
          sawTextPart = true;
          continue;
        }
        if (part is! Map) continue;
        final type = part['type'] as String?;
        if (type == 'reasoning' || type == 'thinking') continue;
        if (type == null || type == 'text' || type == 'output_text') {
          final text = part['text'];
          if (text is String) {
            buffer.write(text);
            sawTextPart = true;
          }
        }
      }
      return sawTextPart ? buffer.toString() : null;
    }
    return null;
  }

  static bool _looksLikeSse(String trimmed) {
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return false;
    if (trimmed.startsWith('data:') || trimmed.startsWith('event:')) {
      return true;
    }
    for (final line in const LineSplitter().convert(trimmed)) {
      final candidate = line.trim();
      if (candidate.isEmpty || candidate.startsWith(':')) continue;
      return candidate.startsWith('data:') || candidate.startsWith('event:');
    }
    return false;
  }

  static String _stripBom(String value) {
    return value.startsWith('\uFEFF') ? value.substring(1) : value;
  }

  String _cacheKey(AiProviderConfig config) {
    final target = resolveEndpointTarget(config);
    return '${target.apiBaseUrl.toLowerCase()}|${config.model.trim().toLowerCase()}';
  }
}
