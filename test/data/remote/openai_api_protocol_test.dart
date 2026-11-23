import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_wrong_notebook/src/data/remote/ai/ai_analysis_service.dart';
import 'package:smart_wrong_notebook/src/data/remote/ai/openai_api_protocol.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_provider_config.dart';

void main() {
  group('OpenAiApiProtocol classification & normalization', () {
    test('identifies modern OpenAI reasoning and GPT-5+/GPT-6+/Codex models',
        () {
      for (final model in const <String>[
        'gpt-5',
        'gpt-5-mini',
        'gpt-5-nano',
        'gpt-5-pro',
        'gpt-5-codex',
        'gpt-5.4',
        'gpt-5.5',
        'gpt-5.6-terra',
        'gpt-6',
        'gpt-6-astra',
        'gpt-6.2-sol',
        'openai/gpt-5.5',
        'openai/gpt-6.2-astra',
        'o1',
        'o1-pro',
        'o3',
        'o3-mini',
        'o3-pro',
        'o4-mini',
        'codex-mini-latest',
        'computer-use-preview',
      ]) {
        expect(
          OpenAiApiProtocol.isModernOpenAiModel(model),
          isTrue,
          reason: 'Expected $model to be recognized as modern OpenAI model',
        );
      }

      for (final model in const <String>[
        'gpt-4o',
        'gpt-4o-mini',
        'gpt-4.1',
        'gpt-4-turbo',
        'claude-sonnet-4',
        'deepseek-chat',
        'qwen-vl-max',
        'gemini-2.5-pro',
        'orca-2',
        'omni-moderation-latest',
      ]) {
        expect(
          OpenAiApiProtocol.isModernOpenAiModel(model),
          isFalse,
          reason: 'Expected $model NOT to be recognized as modern OpenAI model',
        );
      }
    });

    test('resolves explicit /responses and /chat/completions suffixes', () {
      final responsesTarget = OpenAiApiProtocol.resolveEndpointTarget(
        const AiProviderConfig(
          id: 'custom',
          displayName: 'OpenAI',
          baseUrl: 'https://api.openai.com/v1/responses/',
          model: 'gpt-5.5',
          apiKey: 'k',
        ),
      );
      expect(responsesTarget.apiBaseUrl, 'https://api.openai.com/v1');
      expect(responsesTarget.explicitProtocol, OpenAiWireProtocol.responses);

      final chatTarget = OpenAiApiProtocol.resolveEndpointTarget(
        const AiProviderConfig(
          id: 'custom',
          displayName: 'Proxy',
          baseUrl: 'https://proxy.example.com/v1/chat/completions',
          model: 'gpt-5.5',
          apiKey: 'k',
        ),
      );
      expect(chatTarget.apiBaseUrl, 'https://proxy.example.com/v1');
      expect(chatTarget.explicitProtocol, OpenAiWireProtocol.chatCompletions);
    });

    test('treats Gemini models on /v1 proxies as OpenAI-compatible', () {
      expect(
        OpenAiApiProtocol.isGeminiNativeEndpoint(
          const AiProviderConfig(
            id: 'vbcode',
            displayName: 'VBcode',
            baseUrl: 'https://www.vbcode.io/v1',
            model: 'gemini-2.5-pro',
            apiKey: 'k',
          ),
        ),
        isFalse,
      );
      expect(
        OpenAiApiProtocol.isGeminiNativeEndpoint(
          const AiProviderConfig(
            id: 'google',
            displayName: 'Gemini Native',
            baseUrl: 'https://generativelanguage.googleapis.com',
            model: 'gemini-2.5-pro',
            apiKey: 'k',
          ),
        ),
        isTrue,
      );
    });

    test('detects image MIME types from magic bytes', () {
      expect(
        OpenAiApiProtocol.detectImageMimeType(
          Uint8List.fromList(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
        ),
        'image/png',
      );
      expect(
        OpenAiApiProtocol.detectImageMimeType(
          Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0]),
        ),
        'image/jpeg',
      );
      expect(
        OpenAiApiProtocol.detectImageMimeType(
          Uint8List.fromList(utf8.encode('GIF89a')),
        ),
        'image/gif',
      );
      expect(
        OpenAiApiProtocol.detectImageMimeType(
          Uint8List.fromList(utf8.encode('RIFF1234WEBP')),
        ),
        'image/webp',
      );
    });

    test('selects Responses API for official OpenAI and modern models', () {
      final protocol = OpenAiApiProtocol();
      expect(
        protocol.selectProtocol(
          const AiProviderConfig(
            id: 'openai',
            displayName: 'OpenAI',
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt-4o',
            apiKey: 'k',
          ),
        ),
        OpenAiWireProtocol.responses,
      );
      expect(
        protocol.selectProtocol(
          const AiProviderConfig(
            id: 'vbcode',
            displayName: 'VBcode',
            baseUrl: 'https://www.vbcode.io/v1',
            model: 'gpt-6.2-astra',
            apiKey: 'k',
          ),
        ),
        OpenAiWireProtocol.responses,
      );
      expect(
        protocol.selectProtocol(
          const AiProviderConfig(
            id: 'custom',
            displayName: 'DeepSeek',
            baseUrl: 'https://api.deepseek.com/v1',
            model: 'deepseek-chat',
            apiKey: 'k',
          ),
        ),
        OpenAiWireProtocol.chatCompletions,
      );
    });
  });

  group('OpenAiApiProtocol response & SSE extraction', () {
    test('extracts Responses API output while ignoring reasoning items', () {
      final content = OpenAiApiProtocol.extractTextFromPayload(<String, dynamic>{
        'id': 'resp_1',
        'status': 'completed',
        'output': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'reasoning',
            'summary': <Map<String, String>>[
              <String, String>{
                'type': 'summary_text',
                'text': 'internal reasoning should not be returned',
              },
            ],
          },
          <String, dynamic>{
            'type': 'message',
            'role': 'assistant',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'output_text', 'text': '{"finalAnswer":'},
              <String, dynamic>{'type': 'output_text', 'text': '"x=2"}'},
            ],
          },
        ],
      });

      expect(content, '{"finalAnswer":"x=2"}');
    });

    test('extracts Responses API top-level output_text', () {
      final content = OpenAiApiProtocol.extractTextFromPayload(<String, dynamic>{
        'id': 'resp_2',
        'output_text': 'OK',
      });

      expect(content, 'OK');
    });

    test('extracts Responses API SSE starting with event: lines', () {
      const sse = '''
event: response.created
data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"{\\"finalAnswer\\":\\"42\\"}"}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[]}}
''';

      expect(OpenAiApiProtocol.extractTextFromPayload(sse),
          '{"finalAnswer":"42"}');
    });

    test('extracts Codex-style Responses SSE from response.output_item.done',
        () {
      const sse = '''
event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"正确"}]}}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_codex","status":"completed","output":[]}}
''';

      expect(OpenAiApiProtocol.extractTextFromPayload(sse), '正确');
    });

    test('extracts Chat Completions multipart content skipping thinking parts',
        () {
      final content = OpenAiApiProtocol.extractTextFromPayload(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'thinking', 'thinking': 'step 1'},
                <String, dynamic>{'type': 'text', 'text': '最终答案：'},
                <String, dynamic>{'type': 'text', 'text': 'C'},
              ],
            },
          },
        ],
      });

      expect(content, '最终答案：C');
    });

    test('preserves empty SSE FormatException message for fallback logic', () {
      const emptySse = '''
data: {"choices":[{"delta":{"role":"assistant"}}]}
data: [DONE]
''';

      expect(
        () => OpenAiApiProtocol.extractTextFromPayload(emptySse),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Empty SSE chat completion content'),
          ),
        ),
      );
    });
  });

  group('OpenAiApiProtocol HTTP negotiation & self-healing', () {
    test('uses Responses API with PNG MIME & no temperature for modern models',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final payloads = <Map<String, dynamic>>[];

      server.listen((request) async {
        paths.add(request.uri.path);
        final payload = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        payloads.add(payload);

        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{
          'id': 'resp_math_1',
          'status': 'completed',
          'output': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'message',
              'role': 'assistant',
              'content': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'output_text',
                  'text': jsonEncode(<String, dynamic>{
                    'subject': '数学',
                    'finalAnswer': '70^\\circ',
                    'finalAnswerDerivation': '等腰三角形底角相等。',
                    'reconstructedQuestionText': '如图，AB=AC，角 A=40 度，求角 B。',
                    'steps': <String>['底角等于 (180-40)/2 = 70°。'],
                    'aiTags': <String>['几何'],
                    'knowledgePoints': <String>['等腰三角形'],
                    'mistakeReason': '忘记除以 2。',
                    'studyAdvice': '先标记等边对等角。',
                  }),
                },
              ],
            },
          ],
        }));
        await request.response.close();
      });

      final settings = InMemorySettingsRepository();
      await settings.saveAiProviderConfig(AiProviderConfig(
        id: 'local',
        displayName: 'Local',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'gpt-6.2-astra',
        apiKey: 'test-key',
      ));
      final service = AiAnalysisService(settingsRepository: settings);
      final imageFile = File(
        '${Directory.systemTemp.path}/swn-png-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await imageFile.writeAsBytes(
        <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0],
      );

      try {
        final result = await service.analyzeExtractedQuestion(
          correctedText: '如图，在三角形 ABC 中，AB=AC，角 A=40 度，求角 B。',
          subjectName: 'math',
          imagePath: imageFile.path,
        );

        expect(result.finalAnswer, r'70^\circ');
        expect(paths, <String>['/v1/responses']);
        final body = payloads.single;
        expect(body['model'], 'gpt-6.2-astra');
        expect(body['instructions'], isA<String>());
        expect(body.containsKey('temperature'), isFalse);
        expect(body.containsKey('max_tokens'), isFalse);
        expect(body['max_output_tokens'], greaterThanOrEqualTo(3000));
        final input = body['input'] as List<dynamic>;
        final parts = (input.single as Map<String, dynamic>)['content']
            as List<dynamic>;
        final imagePart = parts
            .cast<Map<String, dynamic>>()
            .singleWhere((p) => p['type'] == 'input_image');
        expect(imagePart['image_url'], startsWith('data:image/png;base64,'));
        expect(imagePart['detail'], 'high');
      } finally {
        await imageFile.delete();
        await server.close(force: true);
      }
    });

    test(
        'falls back from /responses to /chat/completions with modern params and caches choice',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final payloads = <Map<String, dynamic>>[];

      server.listen((request) async {
        paths.add(request.uri.path);
        final payload = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        payloads.add(payload);

        if (request.uri.path == '/v1/responses') {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'error': <String, String>{'message': '404 route not found'},
          }));
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, String>{'content': '正确'},
              },
            ],
          }));
        }
        await request.response.close();
      });

      final settings = InMemorySettingsRepository();
      await settings.saveAiProviderConfig(AiProviderConfig(
        id: 'local',
        displayName: 'Legacy Proxy',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'gpt-5.5',
        apiKey: 'test-key',
      ));
      final service = AiAnalysisService(settingsRepository: settings);

      try {
        final first = await service.judgeAnswer(
          question: '1+1=?',
          userAnswer: '2',
          correctAnswer: '2',
        );
        expect(first, isTrue);
        expect(paths, <String>['/v1/responses', '/v1/chat/completions']);

        final chatPayload = payloads.last;
        expect(chatPayload.containsKey('max_tokens'), isFalse);
        expect(chatPayload.containsKey('temperature'), isFalse);
        expect(chatPayload['max_completion_tokens'], greaterThanOrEqualTo(512));

        // Subsequent request should use the cached Chat Completions protocol.
        final second = await service.judgeAnswer(
          question: '2+2=?',
          userAnswer: '4',
          correctAnswer: '4',
        );
        expect(second, isTrue);
        expect(
          paths,
          <String>[
            '/v1/responses',
            '/v1/chat/completions',
            '/v1/chat/completions',
          ],
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('falls back from /chat/completions to /responses for responses-only models',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];

      server.listen((request) async {
        paths.add(request.uri.path);
        await utf8.decoder.bind(request).join();

        if (request.uri.path == '/v1/chat/completions') {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'error': <String, String>{
              'message':
                  'This model is only supported in v1/responses and not in v1/chat/completions.',
            },
          }));
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'id': 'resp_only',
            'output_text': '正确',
          }));
        }
        await request.response.close();
      });

      final settings = InMemorySettingsRepository();
      await settings.saveAiProviderConfig(AiProviderConfig(
        id: 'custom',
        displayName: 'Custom',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'custom-pro-alias',
        apiKey: 'test-key',
      ));
      final service = AiAnalysisService(settingsRepository: settings);

      try {
        final result = await service.judgeAnswer(
          question: '3+3=?',
          userAnswer: '6',
          correctAnswer: '6',
        );
        expect(result, isTrue);
        expect(paths, <String>['/v1/chat/completions', '/v1/responses']);
      } finally {
        await server.close(force: true);
      }
    });

    test(
        'self-heals Chat Completions HTTP 400 max_tokens and temperature errors',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payloads = <Map<String, dynamic>>[];

      server.listen((request) async {
        final payload = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        payloads.add(payload);

        if (payload.containsKey('max_tokens')) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'error': <String, String>{
              'message':
                  "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
              'param': 'max_tokens',
            },
          }));
        } else if (payload.containsKey('temperature')) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'error': <String, String>{
              'message':
                  "Unsupported value: 'temperature' does not support 0.1 with this model. Only the default (1) value is supported.",
              'param': 'temperature',
            },
          }));
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, String>{'content': '错误'},
              },
            ],
          }));
        }
        await request.response.close();
      });

      final settings = InMemorySettingsRepository();
      await settings.saveAiProviderConfig(AiProviderConfig(
        id: 'custom',
        displayName: 'Azure Alias',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'my-reasoning-deployment',
        apiKey: 'test-key',
      ));
      final service = AiAnalysisService(settingsRepository: settings);

      try {
        final result = await service.judgeAnswer(
          question: '3+3=?',
          userAnswer: '5',
          correctAnswer: '6',
        );
        expect(result, isFalse);
        expect(payloads, hasLength(3));
        expect(payloads[0].containsKey('max_tokens'), isTrue);
        expect(payloads[1].containsKey('max_completion_tokens'), isTrue);
        expect(payloads[2].containsKey('max_completion_tokens'), isTrue);
        expect(payloads[2].containsKey('temperature'), isFalse);
      } finally {
        await server.close(force: true);
      }
    });

    test('self-heals Codex /responses requirements (store/stream/max_output_tokens)',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payloads = <Map<String, dynamic>>[];

      server.listen((request) async {
        final payload = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        payloads.add(payload);

        if (payload.containsKey('max_output_tokens')) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'error': <String, String>{
              'message':
                  "Unsupported parameter: 'max_output_tokens' is not supported; 'store' must be set to false; 'stream' must be set to true.",
            },
          }));
        } else {
          request.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          request.response.write('''
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"正确"}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_codex","status":"completed","output":[]}}
''');
        }
        await request.response.close();
      });

      final settings = InMemorySettingsRepository();
      await settings.saveAiProviderConfig(AiProviderConfig(
        id: 'codex',
        displayName: 'Codex Relay',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'gpt-5-codex',
        apiKey: 'test-key',
      ));
      final service = AiAnalysisService(settingsRepository: settings);

      try {
        final result = await service.judgeAnswer(
          question: '2*3=?',
          userAnswer: '6',
          correctAnswer: '6',
        );
        expect(result, isTrue);
        expect(payloads, hasLength(2));
        expect(payloads.last.containsKey('max_output_tokens'), isFalse);
        expect(payloads.last['store'], isFalse);
        expect(payloads.last['stream'], isTrue);
      } finally {
        await server.close(force: true);
      }
    });

    test('does not fall back on 401 authentication errors', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];

      server.listen((request) async {
        paths.add(request.uri.path);
        await utf8.decoder.bind(request).join();
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{
          'error': <String, String>{'message': 'Invalid API key'},
        }));
        await request.response.close();
      });

      final service = AiAnalysisService(
        settingsRepository: InMemorySettingsRepository(),
      );
      final config = AiProviderConfig(
        id: 'local',
        displayName: 'Local',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'gpt-5.5',
        apiKey: 'bad-key',
      );

      try {
        await expectLater(
          service.testConnection(config),
          throwsA(
            isA<AiAnalysisException>().having(
              (e) => e.message,
              'message',
              contains('Invalid API key'),
            ),
          ),
        );
        expect(paths, <String>['/v1/responses']);
      } finally {
        await server.close(force: true);
      }
    });

    test('testConnection rejects HTTP 200 error wrappers and accepts incomplete reasoning probe',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var callCount = 0;

      server.listen((request) async {
        callCount++;
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (callCount == 1) {
          request.response.write(jsonEncode(<String, dynamic>{
            'error': <String, String>{'message': 'Model does not support images'},
          }));
        } else {
          request.response.write(jsonEncode(<String, dynamic>{
            'id': 'resp_probe',
            'status': 'incomplete',
            'incomplete_details': <String, String>{
              'reason': 'max_output_tokens',
            },
            'output': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'reasoning', 'summary': <dynamic>[]},
            ],
          }));
        }
        await request.response.close();
      });

      final service = AiAnalysisService(
        settingsRepository: InMemorySettingsRepository(),
      );
      final config = AiProviderConfig(
        id: 'local',
        displayName: 'Local',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        model: 'gpt-5.5',
        apiKey: 'test-key',
      );

      try {
        await expectLater(
          service.testConnection(config),
          throwsA(
            isA<AiAnalysisException>().having(
              (e) => e.message,
              'message',
              contains('Model does not support images'),
            ),
          ),
        );
        await service.testConnection(config);
      } finally {
        await server.close(force: true);
      }
    });

    test('fetchAvailableModels strips explicit /responses suffix from baseUrl',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];

      server.listen((request) async {
        paths.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{
          'data': <Map<String, String>>[
            <String, String>{'id': 'gpt-6.2-astra'},
            <String, String>{'id': 'gpt-5.5'},
          ],
        }));
        await request.response.close();
      });

      final service = AiAnalysisService(
        settingsRepository: InMemorySettingsRepository(),
      );
      final config = AiProviderConfig(
        id: 'custom',
        displayName: 'Custom',
        baseUrl: 'http://${server.address.address}:${server.port}/v1/responses',
        model: 'gpt-6.2-astra',
        apiKey: 'test-key',
      );

      try {
        final models = await service.fetchAvailableModels(config);
        expect(models, <String>['gpt-5.5', 'gpt-6.2-astra']);
        expect(paths, <String>['/v1/models']);
      } finally {
        await server.close(force: true);
      }
    });

    test('validateProbeResponse catches SSE error events', () {
      const errorSse = '''
event: error
data: {"type":"error","error":{"message":"Unexpected backend failure"}}
''';

      expect(
        () => OpenAiApiProtocol.validateProbeResponse(
          Response<String>(
            requestOptions: RequestOptions(path: '/responses'),
            data: errorSse,
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected backend failure'),
          ),
        ),
      );
    });
  });
}
