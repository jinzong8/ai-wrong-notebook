// Calendar-day date helpers that always evaluate dates in the device's local
// timezone rather than 24-hour elapsed durations or UTC offsets.

/// Returns `true` when [a] and [b] fall on the same local calendar day
/// (midnight-to-midnight in the device's timezone).
bool isSameLocalCalendarDay(DateTime a, DateTime b) {
  final localA = a.toLocal();
  final localB = b.toLocal();
  return localA.year == localB.year &&
      localA.month == localB.month &&
      localA.day == localB.day;
}

/// Returns the signed number of local calendar days from [earlier] to [later].
///
/// Uses UTC midnight projection of local `(year, month, day)` tuples so
/// daylight-saving 23h/25h transitions never cause off-by-one day counts.
int localCalendarDaysBetween(DateTime earlier, DateTime later) {
  final localEarlier = earlier.toLocal();
  final localLater = later.toLocal();
  final dayEarlier =
      DateTime.utc(localEarlier.year, localEarlier.month, localEarlier.day);
  final dayLater =
      DateTime.utc(localLater.year, localLater.month, localLater.day);
  return dayLater.difference(dayEarlier).inDays;
}

/// Formats [date] relative to [now] using local calendar days:
/// - same day: `今天 HH:mm` (or `今天` when [includeTimeForRecent] is `false`)
/// - previous calendar day: `昨天 HH:mm` (or `昨天`)
/// - 2..6 calendar days ago: `N天前`
/// - earlier in the same year: `M月D日`
/// - earlier years or future dates: `YYYY年M月D日` (or `M月D日` if same year)
String formatRelativeLocalDate(
  DateTime date, {
  DateTime? now,
  bool includeTimeForRecent = true,
}) {
  final local = date.toLocal();
  final refNow = (now ?? DateTime.now()).toLocal();
  final dayDiff = localCalendarDaysBetween(local, refNow);
  final hhmm =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

  if (dayDiff == 0) {
    return includeTimeForRecent ? '今天 $hhmm' : '今天';
  }
  if (dayDiff == 1) {
    return includeTimeForRecent ? '昨天 $hhmm' : '昨天';
  }
  if (dayDiff > 1 && dayDiff < 7) {
    return '$dayDiff天前';
  }
  if (local.year == refNow.year) {
    return '${local.month}月${local.day}日';
  }
  return '${local.year}年${local.month}月${local.day}日';
}
