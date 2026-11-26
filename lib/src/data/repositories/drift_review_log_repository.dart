import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_wrong_notebook/src/data/local/app_database.dart' as db;
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/review_log.dart'
    as domain;
import 'package:smart_wrong_notebook/src/domain/repositories/review_log_repository.dart';

class DriftReviewLogRepository implements ReviewLogRepository {
  DriftReviewLogRepository(this._db);

  static const String _legacyPrefsKey = 'review_logs';

  final db.AppDatabase _db;
  Future<void>? _migrationFuture;

  Future<void> _ensureMigratedFromSharedPrefs() {
    return _migrationFuture ??= _migrateFromSharedPrefs();
  }

  Future<void> _migrateFromSharedPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_legacyPrefsKey);
      if (raw == null || raw.isEmpty) return;

      final existing = await _db.select(_db.reviewLogs).get();
      if (existing.isEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final companions = <db.ReviewLogsCompanion>[];
          for (final entry in decoded) {
            if (entry is! Map) continue;
            final logId = entry['id']?.toString() ?? '';
            final questionId = entry['questionRecordId']?.toString() ?? '';
            if (questionId.isEmpty) continue;
            final reviewedAt =
                DateTime.tryParse(entry['reviewedAt']?.toString() ?? '') ??
                    DateTime.now();
            final result = entry['result']?.toString() ?? 'reviewing';
            final masteryName = entry['masteryAfter']?.toString();
            final masteryAfter = MasteryLevel.values.firstWhere(
              (m) => m.name == masteryName,
              orElse: () => result == 'mastered'
                  ? MasteryLevel.mastered
                  : MasteryLevel.reviewing,
            );
            companions.add(db.ReviewLogsCompanion.insert(
              questionId: questionId,
              reviewedAt: reviewedAt,
              wasCorrect: result == 'mastered',
              notes: Value(jsonEncode(<String, dynamic>{
                'logId': logId,
                'result': result,
                'masteryAfter': masteryAfter.name,
              })),
            ));
          }
          if (companions.isNotEmpty) {
            await _db.batch((batch) {
              batch.insertAll(_db.reviewLogs, companions);
            });
          }
        }
      }

      await prefs.remove(_legacyPrefsKey);
    } catch (_) {
      // Pure unit tests without plugin bindings or malformed legacy entries
      // must continue seamlessly.
    }
  }

  @override
  Future<void> insert(domain.ReviewLog log) async {
    await _ensureMigratedFromSharedPrefs();
    await _db.into(_db.reviewLogs).insert(
          db.ReviewLogsCompanion.insert(
            questionId: log.questionRecordId,
            reviewedAt: log.reviewedAt,
            wasCorrect: log.result == 'mastered',
            notes: Value(jsonEncode(<String, dynamic>{
              'logId': log.id,
              'result': log.result,
              'masteryAfter': log.masteryAfter.name,
            })),
          ),
        );
  }

  @override
  Future<List<domain.ReviewLog>> getByQuestionId(String questionId) async {
    await _ensureMigratedFromSharedPrefs();
    final rows = await (_db.select(_db.reviewLogs)
          ..where((t) => t.questionId.equals(questionId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.reviewedAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return rows.map(_toDomain).toList(growable: false);
  }

  @override
  Future<List<domain.ReviewLog>> listAll() async {
    await _ensureMigratedFromSharedPrefs();
    final rows = await (_db.select(_db.reviewLogs)
          ..orderBy([
            (t) => OrderingTerm.desc(t.reviewedAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return rows.map(_toDomain).toList(growable: false);
  }

  @override
  Future<void> clear() async {
    await _ensureMigratedFromSharedPrefs();
    await _db.delete(_db.reviewLogs).go();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyPrefsKey);
    } catch (_) {}
  }

  domain.ReviewLog _toDomain(db.ReviewLog row) {
    var logId = row.id.toString();
    var result = row.wasCorrect ? 'mastered' : 'reviewing';
    var masteryAfter =
        row.wasCorrect ? MasteryLevel.mastered : MasteryLevel.reviewing;

    final rawNotes = row.notes;
    if (rawNotes != null && rawNotes.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawNotes);
        if (decoded is Map) {
          final parsedId = decoded['logId']?.toString();
          if (parsedId != null && parsedId.isNotEmpty) {
            logId = parsedId;
          }
          final parsedResult = decoded['result']?.toString();
          if (parsedResult != null && parsedResult.isNotEmpty) {
            result = parsedResult;
          }
          final parsedMastery = decoded['masteryAfter']?.toString();
          if (parsedMastery != null && parsedMastery.isNotEmpty) {
            masteryAfter = MasteryLevel.values.firstWhere(
              (m) => m.name == parsedMastery,
              orElse: () => masteryAfter,
            );
          }
        }
      } catch (_) {
        // Fall back gracefully if notes is plain text or invalid JSON.
      }
    }

    return domain.ReviewLog(
      id: logId,
      questionRecordId: row.questionId,
      reviewedAt: row.reviewedAt,
      result: result,
      masteryAfter: masteryAfter,
    );
  }
}
