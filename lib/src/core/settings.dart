/// 轻量设置层（SharedPreferences 存 JSON）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../net/proxy.dart';

class AutoSyncSettings {
  const AutoSyncSettings({
    this.enabled = false,
    this.intervalMinutes = 30,
    this.rangeDays,
    this.maxItems = 500,
  });

  final bool enabled;
  final int intervalMinutes;

  /// null = 不限时间范围
  final int? rangeDays;

  /// 单次同步最多处理多少条（软上限）
  final int maxItems;

  AutoSyncSettings copyWith({
    bool? enabled,
    int? intervalMinutes,
    int? rangeDays,
    int? maxItems,
    bool clearRange = false,
  }) =>
      AutoSyncSettings(
        enabled: enabled ?? this.enabled,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        rangeDays: clearRange ? null : (rangeDays ?? this.rangeDays),
        maxItems: maxItems ?? this.maxItems,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'intervalMinutes': intervalMinutes,
        if (rangeDays != null) 'rangeDays': rangeDays,
        'maxItems': maxItems,
      };

  factory AutoSyncSettings.fromJson(Map<String, Object?> j) => AutoSyncSettings(
        enabled: j['enabled'] as bool? ?? false,
        intervalMinutes: (j['intervalMinutes'] as num?)?.toInt() ?? 30,
        rangeDays: (j['rangeDays'] as num?)?.toInt(),
        maxItems: (j['maxItems'] as num?)?.toInt() ?? 500,
      );
}

/// 上次浏览位置的快照：视图模式 + 筛选 + 锚点 + 当前条。
class ViewSnapshot {
  const ViewSnapshot({
    this.mode = SortMode.likeOrder,
    this.filter = const LikesFilter(),
    this.anchorSeq,
    this.selectedTweetId,
    this.scrollOffset = 0,
  });

  final SortMode mode;
  final LikesFilter filter;
  final int? anchorSeq;
  final String? selectedTweetId;
  final double scrollOffset;

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'filter': filter.toJson(),
        if (anchorSeq != null) 'anchorSeq': anchorSeq,
        if (selectedTweetId != null) 'selected': selectedTweetId,
        'scrollOffset': scrollOffset,
      };

  factory ViewSnapshot.fromJson(Map<String, Object?> j) => ViewSnapshot(
        mode: SortMode.fromName(j['mode'] as String?),
        filter: LikesFilter.fromJson(
            Map<String, Object?>.from(j['filter'] as Map? ?? const {})),
        anchorSeq: (j['anchorSeq'] as num?)?.toInt(),
        selectedTweetId: j['selected'] as String?,
        scrollOffset: (j['scrollOffset'] as num?)?.toDouble() ?? 0,
      );
}

class AppSettings {
  AppSettings(this._prefs) : _memory = <String, Object?>{};

  AppSettings._memory(this._memory)
      : _prefs = null;

  final SharedPreferences? _prefs;

  /// SharedPreferences 不可用时的内存兜底（设置不落盘，但 App 能正常跑）。
  final Map<String, Object?> _memory;

  /// 设置层可用了没：null 表示正常，否则是降级原因。
  String? storageError;

  /// 平台差异（某些 ROM 的 DataStore/JNI 初始化会炸）不该让整个 App 打不开。
  static Future<AppSettings> load() async {
    try {
      return AppSettings(await SharedPreferences.getInstance());
    } catch (e) {
      final fallback = AppSettings._memory(<String, Object?>{});
      fallback.storageError = '$e';
      return fallback;
    }
  }

  bool get degraded => _prefs == null;

  static const _kProxy = 'proxy';
  static const _kAutoSync = 'autosync';
  static const _kView = 'view';
  static const _kCacheDir = 'cache.dir';
  static const _kCacheLimitMb = 'cache.limitMb';

  String? _getString(String key) =>
      _prefs?.getString(key) ?? _memory[key] as String?;

  int? _getInt(String key) => _prefs?.getInt(key) ?? _memory[key] as int?;

  Future<void> _setString(String key, String value) async {
    _memory[key] = value;
    await _prefs?.setString(key, value);
  }

  Future<void> _setInt(String key, int value) async {
    _memory[key] = value;
    await _prefs?.setInt(key, value);
  }

  Future<void> _remove(String key) async {
    _memory.remove(key);
    await _prefs?.remove(key);
  }

  ProxyConfig get proxy {
    final raw = _getString(_kProxy);
    if (raw == null) return const ProxyConfig();
    return ProxyConfig.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map));
  }

  Future<void> setProxy(ProxyConfig cfg) =>
      _setString(_kProxy, jsonEncode(cfg.toJson()));

  AutoSyncSettings get autoSync {
    final raw = _getString(_kAutoSync);
    if (raw == null) return const AutoSyncSettings();
    return AutoSyncSettings.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map));
  }

  Future<void> setAutoSync(AutoSyncSettings s) =>
      _setString(_kAutoSync, jsonEncode(s.toJson()));

  ViewSnapshot get view {
    final raw = _getString(_kView);
    if (raw == null) return const ViewSnapshot();
    return ViewSnapshot.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map));
  }

  Future<void> setView(ViewSnapshot s) =>
      _setString(_kView, jsonEncode(s.toJson()));

  String? get cacheDir => _getString(_kCacheDir);

  Future<void> setCacheDir(String? dir) async {
    if (dir == null) {
      await _remove(_kCacheDir);
    } else {
      await _setString(_kCacheDir, dir);
    }
  }

  int get cacheLimitMb => _getInt(_kCacheLimitMb) ?? 5120;

  Future<void> setCacheLimitMb(int mb) => _setInt(_kCacheLimitMb, mb);
}
