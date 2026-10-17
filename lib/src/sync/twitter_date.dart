/// 解析 X 的日期字符串，例如 `Wed Oct 10 20:19:24 +0000 2018`。
///
/// `DateTime.parse` 不接受这个格式，所以手写一个。
library;

const _months = {
  'Jan': 1,
  'Feb': 2,
  'Mar': 3,
  'Apr': 4,
  'May': 5,
  'Jun': 6,
  'Jul': 7,
  'Aug': 8,
  'Sep': 9,
  'Oct': 10,
  'Nov': 11,
  'Dec': 12,
};

/// 返回 UTC 时间；解析失败返回 null。
DateTime? parseTwitterDate(String? input) {
  if (input == null || input.isEmpty) return null;
  final parts = input.trim().split(RegExp(r'\s+'));
  if (parts.length < 6) return null;
  final month = _months[parts[1]];
  final day = int.tryParse(parts[2]);
  final hms = parts[3].split(':');
  final year = int.tryParse(parts[5]);
  if (month == null || day == null || hms.length != 3 || year == null) {
    return null;
  }
  final hour = int.tryParse(hms[0]);
  final minute = int.tryParse(hms[1]);
  final second = int.tryParse(hms[2]);
  if (hour == null || minute == null || second == null) return null;

  // 时区偏移：+0000 / -0700 之类
  var offsetMinutes = 0;
  final tz = parts[4];
  if (tz.length == 5 && (tz[0] == '+' || tz[0] == '-')) {
    final oh = int.tryParse(tz.substring(1, 3));
    final om = int.tryParse(tz.substring(3, 5));
    if (oh != null && om != null) {
      offsetMinutes = (oh * 60 + om) * (tz[0] == '-' ? -1 : 1);
    }
  }

  final local = DateTime.utc(year, month, day, hour, minute, second);
  return local.subtract(Duration(minutes: offsetMinutes));
}
