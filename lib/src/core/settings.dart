/// 轻量设置层（SharedPreferences 存 JSON）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../media/quality.dart';
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

/// 播放器偏好。
///
/// 这些值都在设置页里可改，因为「双击快进多少秒」「长按多快」是强个人习惯：
/// 抖音老用户习惯 10s/2×，看长视频的人可能想要 30s/3×。
class PlaybackSettings {
  const PlaybackSettings({
    this.doubleTapSeconds = 10,
    this.longPressSpeed = 2.0,
    this.qualityTier = QualityTier.auto,
    this.autoUpgrade = true,
    this.loop = true,
    this.autoNext = false,
    this.showSaveToGallery = true,
    this.autoPlayInList = false,
  });

  /// 双击左/右快退/快进的秒数。
  final int doubleTapSeconds;

  /// 长按临时倍速（松手恢复 1×）。
  final double longPressSpeed;

  /// **全局**画质档位：在任意一条视频上选过之后，其它视频也按这一档播放。
  ///
  /// 存的是相对档位（低/中下/中/中上/高），所以档数不同的视频也能映射过去。
  /// [QualityTier.auto] = 按网络情况自动爬。
  final QualityTier qualityTier;

  /// 自动模式下是否真的升清晰。关掉就停在起播档（省流量）。
  final bool autoUpgrade;

  /// 单条视频循环播放（短视频浏览默认开）。
  final bool loop;

  /// 视频播完是否自动滑到下一条。
  ///
  /// 和 [loop] 互斥：循环时视频永远不会「播完」，所以开了循环这个开关不生效。
  final bool autoNext;

  /// 播放页右侧是否显示「保存到相册」。视频本身始终后台缓存，这个只控按钮。
  final bool showSaveToGallery;

  /// 列表里直接播放视频（静音、循环），不用点进全屏。
  ///
  /// 默认关：一屏三四个播放器同时解码，低端机上会明显掉帧；
  /// 而且很多人只是路过列表，不想被视频拽住。
  final bool autoPlayInList;

  PlaybackSettings copyWith({
    int? doubleTapSeconds,
    double? longPressSpeed,
    QualityTier? qualityTier,
    bool? autoUpgrade,
    bool? loop,
    bool? autoNext,
    bool? showSaveToGallery,
    bool? autoPlayInList,
  }) =>
      PlaybackSettings(
        doubleTapSeconds: doubleTapSeconds ?? this.doubleTapSeconds,
        longPressSpeed: longPressSpeed ?? this.longPressSpeed,
        qualityTier: qualityTier ?? this.qualityTier,
        autoUpgrade: autoUpgrade ?? this.autoUpgrade,
        loop: loop ?? this.loop,
        autoNext: autoNext ?? this.autoNext,
        showSaveToGallery: showSaveToGallery ?? this.showSaveToGallery,
        autoPlayInList: autoPlayInList ?? this.autoPlayInList,
      );

  Map<String, Object?> toJson() => {
        'doubleTapSeconds': doubleTapSeconds,
        'longPressSpeed': longPressSpeed,
        'qualityTier': qualityTier.name,
        'autoUpgrade': autoUpgrade,
        'loop': loop,
        'autoNext': autoNext,
        'showSaveToGallery': showSaveToGallery,
        'autoPlayInList': autoPlayInList,
      };

  factory PlaybackSettings.fromJson(Map<String, Object?> j) => PlaybackSettings(
        doubleTapSeconds:
            ((j['doubleTapSeconds'] as num?)?.toInt() ?? 10).clamp(1, 120),
        longPressSpeed:
            ((j['longPressSpeed'] as num?)?.toDouble() ?? 2.0).clamp(0.5, 5.0),
        // 老设置里是 `quality: auto|high|medium|low`，映射到新档位。
        qualityTier: _tierFromJson(j),
        autoUpgrade: j['autoUpgrade'] as bool? ?? true,
        loop: j['loop'] as bool? ?? true,
        autoNext: j['autoNext'] as bool? ?? false,
        showSaveToGallery: j['showSaveToGallery'] as bool? ?? true,
        autoPlayInList: j['autoPlayInList'] as bool? ?? false,
      );

  static QualityTier _tierFromJson(Map<String, Object?> j) {
    final raw = j['qualityTier'] as String?;
    if (raw != null) return QualityTier.fromName(raw);
    // 兼容老版本：auto/high/medium/low
    return switch (j['quality'] as String?) {
      'high' => QualityTier.high,
      'medium' => QualityTier.medium,
      'low' => QualityTier.low,
      _ => QualityTier.auto,
    };
  }
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
  static const _kPlayback = 'playback';
  static const _kLang = 'ui.lang';
  static const _kCacheDir = 'cache.dir';
  static const _kCacheLimitMb = 'cache.limitMb';
  static const _kShowMetrics = 'ui.showMetrics';
  static const _kNavTabs = 'ui.navTabs';
  static const _kTranslateTo = 'ui.translateTo';
  static const _kAutoTranslate = 'ui.autoTranslate';
  static const _kLowData = 'ui.lowData';
  static const _kKeepAwake = 'ui.keepAwake';
  static const _kNavConfigured = 'ui.navConfigured';

  /// 底部导航全部可选项（顺序即默认顺序）。
  static const List<String> allNavTabs = [
    'browse',
    'search',
    'swipe',
    'grok',
    'settings',
  ];

  /// 「设置」不能隐藏，否则用户找不到地方把它放回来。
  static const String pinnedNavTab = 'settings';

  /// 帖子底部是否显示回复/转发/喜欢/热度。
  ///
  /// 默认开：这些数字是「值不值得点进去」的主要判断依据。
  /// 关掉之后卡片更干净，也省掉那批 statuses/lookup 请求。
  bool get showMetrics {
    final raw = _prefs?.getBool(_kShowMetrics) ?? _memory[_kShowMetrics];
    return raw is bool ? raw : true;
  }

  Future<void> setShowMetrics(bool v) async {
    _memory[_kShowMetrics] = v;
    await _prefs?.setBool(_kShowMetrics, v);
  }

  /// 底部导航的完整顺序（含被隐藏的项）。
  ///
  /// 存的是 `{"order":[…], "hidden":[…]}`；老格式是一个纯数组（只有「显示了的、
  /// 按顺序」），读的时候当成 order，没出现在数组里的就算隐藏 —— 这样以前
  /// 被关掉的项不会突然又冒出来。
  List<String> get navOrder {
    final cfg = _navConfigRaw();
    final order = <String>[];
    for (final key in cfg.order) {
      if (allNavTabs.contains(key) && !order.contains(key)) order.add(key);
    }
    for (final key in allNavTabs) {
      if (!order.contains(key)) order.add(key);
    }
    return order;
  }

  /// 被隐藏的项。「设置」永远不在里面。
  ///
  /// **没手动配过**的时候用新默认：底栏只有「喜欢」和「设置」。
  /// 一进设置里拖过/勾过就记成 true，从此完全按用户存的来。
  Set<String> get navHidden {
    final cfg = _navConfigRaw();
    final hidden = {
      for (final key in cfg.hidden)
        if (allNavTabs.contains(key) && key != pinnedNavTab) key,
    };
    if (!_navConfigured) {
      hidden.addAll(const ['search', 'swipe', 'grok']);
      hidden.remove(pinnedNavTab);
    }
    return hidden;
  }

  bool get _navConfigured =>
      (_prefs?.getBool(_kNavConfigured) ?? _memory[_kNavConfigured]) == true;

  /// 实际显示在底栏上的项（按顺序）。至少会有「设置」。
  List<String> get navTabs {
    final hidden = navHidden;
    return [
      for (final key in navOrder)
        if (!hidden.contains(key)) key,
    ];
  }

  Future<void> setNavConfig({
    required List<String> order,
    required Set<String> hidden,
  }) async {
    // 顺序去重 + 补齐；「设置」不允许被隐藏。
    final cleaned = <String>[];
    for (final key in order) {
      if (!allNavTabs.contains(key) || cleaned.contains(key)) continue;
      cleaned.add(key);
    }
    for (final key in allNavTabs) {
      if (!cleaned.contains(key)) cleaned.add(key);
    }
    final hiddenClean = <String>[
      for (final key in hidden)
        if (allNavTabs.contains(key) && key != pinnedNavTab) key,
    ];
    await _setString(
      _kNavTabs,
      jsonEncode({'order': cleaned, 'hidden': hiddenClean}),
    );
    // 用户手动配过了：以后完全按这个来，不再套默认值。
    _memory[_kNavConfigured] = true;
    await _prefs?.setBool(_kNavConfigured, true);
  }

  /// 读原始配置（兼容只有数组的老格式）。
  ({List<String> order, Set<String> hidden}) _navConfigRaw() {
    final raw = _getString(_kNavTabs);
    if (raw == null) {
      return (order: List<String>.from(allNavTabs), hidden: <String>{});
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final order = [
          for (final e in (decoded['order'] as List? ?? const []))
            e.toString(),
        ];
        final hidden = {
          for (final e in (decoded['hidden'] as List? ?? const []))
            e.toString(),
        };
        return (order: order, hidden: hidden);
      }
      if (decoded is List) {
        final enabled = [for (final e in decoded) e.toString()];
        return (
          order: enabled,
          // 老格式里没出现的项 = 当时被关掉的
          hidden: {
            for (final key in allNavTabs)
              if (!enabled.contains(key)) key,
          },
        );
      }
    } catch (_) {
      // 脏数据：按默认。
    }
    return (order: List<String>.from(allNavTabs), hidden: <String>{});
  }

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

  PlaybackSettings get playback {
    final raw = _getString(_kPlayback);
    if (raw == null) return const PlaybackSettings();
    return PlaybackSettings.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map));
  }

  Future<void> setPlayback(PlaybackSettings s) =>
      _setString(_kPlayback, jsonEncode(s.toJson()));

  /// 界面语言：`null` = 跟随系统，否则 `'zh'` / `'en'`。
  String? get language => _getString(_kLang);

  Future<void> setLanguage(String? code) async {
    if (code == null) {
      await _remove(_kLang);
    } else {
      await _setString(_kLang, code);
    }
  }

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

  /// 某个排序 Tab 上次停在哪（像素）。
  ///
  /// 三个 Tab（喜欢顺序 / 按发布日期 / 随机）各自记一份，切回来时回到原处，
  /// 重启 App 也还在。
  double scrollOf(String modeKey) {
    final key = 'ui.scroll.$modeKey';
    final v = _prefs?.getDouble(key) ?? _memory[key];
    return v is num ? v.toDouble() : 0;
  }

  Future<void> setScrollOf(String modeKey, double offset) async {
    final key = 'ui.scroll.$modeKey';
    _memory[key] = offset;
    await _prefs?.setDouble(key, offset);
  }

  /// 翻译目标语言（`zh` / `en` / `ja` …）。默认翻成中文。
  String get translateTo => _getString(_kTranslateTo) ?? 'zh';

  Future<void> setTranslateTo(String code) =>
      _setString(_kTranslateTo, code);

  /// 列表里自动翻译正文（默认关）。
  ///
  /// 关着的时候列表就是原文，一次请求都不发；开了之后只翻列表里显示的那段正文，
  /// 并且 @提及 / #话题 / 链接会被剔掉（见 rich_text.translatableBody）。
  bool get autoTranslate {
    final raw = _prefs?.getBool(_kAutoTranslate) ??
        _memory[_kAutoTranslate];
    return raw is bool ? raw : false;
  }

  Future<void> setAutoTranslate(bool v) async {
    _memory[_kAutoTranslate] = v;
    await _prefs?.setBool(_kAutoTranslate, v);
  }

  /// 低数据模式：不切画质、不升档、不后台缓存视频。
  ///
  /// 播放时「本地有缓存就用缓存里最好的那档，没有就用最低档」——
  /// 地铁/流量紧张时最省的做法，也完全不给播放器第二路网络流。
  bool get lowDataMode {
    final raw = _prefs?.getBool(_kLowData) ?? _memory[_kLowData];
    return raw is bool ? raw : false;
  }

  Future<void> setLowDataMode(bool v) async {
    _memory[_kLowData] = v;
    await _prefs?.setBool(_kLowData, v);
  }

  /// 使用中不熄屏（默认开：看视频时屏幕自己灭掉最烦人）。
  bool get keepAwake {
    final raw = _prefs?.getBool(_kKeepAwake) ?? _memory[_kKeepAwake];
    return raw is bool ? raw : true;
  }

  Future<void> setKeepAwake(bool v) async {
    _memory[_kKeepAwake] = v;
    await _prefs?.setBool(_kKeepAwake, v);
  }
}
