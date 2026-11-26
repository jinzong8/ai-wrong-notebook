import 'package:flutter_test/flutter_test.dart';
import 'package:smart_wrong_notebook/src/shared/utils/local_date_utils.dart';

void main() {
  group('local_date_utils', () {
    test('treats midnight boundary as distinct calendar days, not 24h windows',
        () {
      final yesterdayLate = DateTime(2026, 11, 25, 23, 55);
      final todayEarly = DateTime(2026, 11, 26, 0, 5);

      expect(isSameLocalCalendarDay(yesterdayLate, todayEarly), isFalse);
      expect(localCalendarDaysBetween(yesterdayLate, todayEarly), 1);
      expect(
        formatRelativeLocalDate(yesterdayLate, now: todayEarly),
        '昨天 23:55',
      );
    });

    test('formats yesterday evening viewed next afternoon as 昨天 with time',
        () {
      final yesterdayEvening = DateTime(2026, 11, 25, 21, 30);
      final todayAfternoon = DateTime(2026, 11, 26, 15, 0);

      expect(
        formatRelativeLocalDate(yesterdayEvening, now: todayAfternoon),
        '昨天 21:30',
      );
    });

    test('formats two calendar days ago within 48h as 2天前 instead of 昨天', () {
      final twoDaysAgoLate = DateTime(2026, 11, 24, 23, 30);
      final todayEarly = DateTime(2026, 11, 26, 0, 10);

      expect(localCalendarDaysBetween(twoDaysAgoLate, todayEarly), 2);
      expect(
        formatRelativeLocalDate(twoDaysAgoLate, now: todayEarly),
        '2天前',
      );
    });

    test('formats same-day timestamps with HH:mm so 00:xx is clearly visible',
        () {
      final todayAfterMidnight = DateTime(2026, 11, 26, 0, 15);
      final todayEvening = DateTime(2026, 11, 26, 21, 12);

      expect(isSameLocalCalendarDay(todayAfterMidnight, todayEvening), isTrue);
      expect(
        formatRelativeLocalDate(todayAfterMidnight, now: todayEvening),
        '今天 00:15',
      );
    });

    test('normalizes UTC DateTime to local calendar day before comparing', () {
      final localTime = DateTime(2026, 11, 26, 0, 20);
      final utcEquivalent = localTime.toUtc();
      final localLaterSameDay = DateTime(2026, 11, 26, 20, 0);

      expect(isSameLocalCalendarDay(utcEquivalent, localLaterSameDay), isTrue);
      expect(
        formatRelativeLocalDate(utcEquivalent, now: localLaterSameDay),
        '今天 00:20',
      );
    });

    test('formats older dates within same year and prior years clearly', () {
      final now = DateTime(2026, 11, 26, 12, 0);
      expect(
        formatRelativeLocalDate(DateTime(2026, 11, 10, 9, 0), now: now),
        '11月10日',
      );
      expect(
        formatRelativeLocalDate(DateTime(2025, 12, 31, 23, 0), now: now),
        '2025年12月31日',
      );
    });
  });
}
