/// 应用级状态：数据库、设置、登录态、网络客户端、分页游标。
///
/// 刻意不引第三方状态管理：一个 ChangeNotifier + InheritedNotifier 足够，
/// 依赖少、审起来快。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'auth/auth_store.dart';
import 'core/settings.dart';
import 'db/app_database.dart';
import 'media/media_cache.dart';
import 'model/like_item.dart';
import 'net/proxy.dart';
import 'sync/reconciler.dart';
import 'sync/sync_service.dart';
import 'sync/x_client.dart';

class AppController extends ChangeNotifier {
  AppController();

  late AppSettings settings;
  late AppDatabase db;
  late AuthStore authStore;

  XSession? session;
  XClient? client;
  SyncService? syncService;
  MediaCache? mediaCache;

  /// 上一轮创建的连接池，重建时关掉。
  http.Client? _xHttp;
  http.Client? _mediaHttp;

  /// 媒体缓存的根目录（设置里可改到别的盘）。
  Directory? _mediaRoot;

  bool booting = true;
  String? bootError;
  String? proxyWarning;

  // ---- 浏览状态 ----
  SortMode mode = SortMode.likeOrder;
  LikesFilter filter = const LikesFilter();
  final List<LikeItem> items = [];
  PageKey? nextKey;
  bool loadingPage = false;
  bool hasMore = true;
  int totalCount = 0;
  LikedStats stats = const LikedStats(total: 0, videos: 0, images: 0, deleted: 0);
  String? selectedTweetId;

  // ---- 同步状态 ----
  SyncProgress? syncProgress;
  String? syncError;
  SyncCancel? _cancel;

  bool get loggedIn => session != null;

  Future<void> boot() async {
    try {
      settings = await AppSettings.load();
      final support = await getApplicationSupportDirectory();
      final dbPath = p.join(support.path, 'likes.db');
      db = AppDatabase.open(dbPath);
      authStore = AuthStore();
      _mediaRoot = settings.cacheDir != null
          ? Directory(settings.cacheDir!)
          : Directory(p.join(support.path, 'media'));

      // 先把登录态读出来，再建客户端 —— 反过来的话 session 为 null，
      // 建出来的 client / syncService 都是空的，启动后同步与后台校验全失效。
      final stored = await authStore.load();
      if (stored != null) session = stored;

      await _rebuildClient();
      _refreshAccountId();

      if (stored != null) {
        // 有缓存先显示，网络校验放到后台，避免启动被墙/代理卡住。
        unawaited(_verifyInBackground());
      }
      await _restoreView();
      await reload(reset: true);
    } catch (e) {
      bootError = '$e';
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  Future<void> _verifyInBackground() async {
    final s = session;
    final c = client;
    if (s == null || c == null) return;
    try {
      final verified = await c.verify();
      session = verified;
      await authStore.save(verified);
      _refreshAccountId();
      notifyListeners();
    } catch (_) {
      // 校验失败不踢人：可能是网络/代理问题，让 UI 提示即可。
    }
  }

  Future<void> _rebuildClient() async {
    // 切换代理/重新登录都会走这里；先把上一轮的连接池关掉，避免每次泄漏一个。
    _xHttp?.close();
    _mediaHttp?.close();

    final proxyCfg = settings.proxy;
    final resolution = await buildHttpClient(proxyCfg);
    proxyWarning = resolution.warning;
    final httpClient = IOClient(resolution.client);
    _xHttp = httpClient;
    final s = session;

    // 媒体走独立的 HttpClient 实例（同一个底层连接池被两个 IOClient 共享后，
    // 关闭其中一个会连带影响另一个）。
    final mediaResolution = await buildHttpClient(proxyCfg);
    final mediaHttp = IOClient(mediaResolution.client);
    _mediaHttp = mediaHttp;
    mediaCache = MediaCache(
      db: db,
      httpClient: mediaHttp,
      rootDir: _mediaRoot ?? Directory.systemTemp,
      maxBytes: settings.cacheLimitMb * 1024 * 1024,
    );

    if (s != null) {
      client = XClient(session: s, httpClient: httpClient);
      syncService = SyncService(db: db, client: client!);
    } else {
      client = null;
      syncService = null;
      reconciler?.stop();
      reconciler = null;
    }
    _autosyncTimer?.cancel();
    _autosyncTimer = null;
    if (session != null) _scheduleAutoSync();
    notifyListeners();
  }

  /// 巡边器：让「滚到哪核到哪」和「陈段轮转」共用一个预算队列。
  Reconciler? reconciler;

  void _ensureReconciler() {
    final acc = accountId;
    final c = client;
    if (acc == null || c == null) return;
    reconciler ??= Reconciler(db: db, client: c, accountId: acc)..start();
  }

  /// UI 滚动停下时调用：把当前可见的一段标脏。
  void markViewportDirty(int fromSeq, int toSeq) {
    _ensureReconciler();
    reconciler?.markViewportDirty(fromSeq, toSeq);
  }

  Timer? _autosyncTimer;

  /// 自动同步：桌面/前台按间隔投一次预算；默认关。
  void _scheduleAutoSync() {
    final cfg = settings.autoSync;
    if (!cfg.enabled) return;
    _autosyncTimer?.cancel();
    _autosyncTimer = Timer.periodic(
      Duration(minutes: cfg.intervalMinutes),
      (_) => unawaited(syncNew()),
    );
  }

  Future<void> setAutoSync(AutoSyncSettings cfg) async {
    await settings.setAutoSync(cfg);
    _autosyncTimer?.cancel();
    _autosyncTimer = null;
    _scheduleAutoSync();
    notifyListeners();
  }

  Future<void> applyProxy(ProxyConfig cfg) async {
    await settings.setProxy(cfg);
    await _rebuildClient();
    notifyListeners();
  }

  Future<void> signIn(XSession s) async {
    session = s;
    await authStore.save(s);
    await _rebuildClient();
    _refreshAccountId();
    notifyListeners();
  }

  Future<void> signOut() async {
    session = null;
    await authStore.clear();
    await _rebuildClient();
    _accountId = null;
    items.clear();
    nextKey = null;
    hasMore = false;
    totalCount = 0;
    stats = const LikedStats(total: 0, videos: 0, images: 0, deleted: 0);
    selectedTweetId = null;
    _invalidateTimelineCache();
    notifyListeners();
  }

  /// 用已有 cookie 校验一次（登录页/粘贴入口用）。
  Future<XSession> verifySession(XSession s) async {
    final resolution = await buildHttpClient(settings.proxy);
    final c = XClient(session: s, httpClient: IOClient(resolution.client));
    return c.verify();
  }

  /// 当前账号在 `accounts` 表里的 id。
  ///
  /// 以前这里是 getter 里直接 upsert（写库），而 UI 在 build 里会反复读它 ——
  /// 等于每次重绘都写一次数据库。现在只在登录态变化时算一次并缓存。
  int? _accountId;
  int? get accountId => _accountId;

  void _refreshAccountId() {
    final s = session;
    if (s == null || s.userId.isEmpty) {
      _accountId = null;
      return;
    }
    _accountId = db.upsertAccount(
      xUserId: s.userId,
      screenName: s.screenName,
      displayName: s.displayName,
      avatarUrl: s.avatarUrl,
    );
  }

  /// 回填是否已经翻到底（决定菜单显示「全量回填」还是「继续回填」）。
  bool get backfillDone {
    final acc = _accountId;
    if (acc == null) return false;
    return db.loadSyncState(acc).backfillDone;
  }

  // ------------------------------------------------------------- 浏览与分页

  Future<void> _restoreView() async {
    final v = settings.view;
    mode = v.mode;
    filter = v.filter;
    selectedTweetId = v.selectedTweetId;
  }

  Future<void> saveViewState({double? scrollOffset}) async {
    await settings.setView(ViewSnapshot(
      mode: mode,
      filter: filter,
      anchorSeq: items.isNotEmpty ? items.first.feedRank : null,
      selectedTweetId: selectedTweetId,
      scrollOffset: scrollOffset ?? 0,
    ));
  }

  Future<void> reload({bool reset = false}) async {
    if (reset) {
      items.clear();
      nextKey = null;
      hasMore = true;
      _invalidateTimelineCache();
    }
    totalCount = db.countLikes(includeDeleted: false);
    stats = db.stats();
    await loadMore();
  }

  Future<void> loadMore() async {
    if (loadingPage || !hasMore) return;
    loadingPage = true;
    notifyListeners();
    try {
      final page = db.fetchPage(
        mode: mode,
        filter: filter,
        limit: 60,
        after: nextKey,
      );
      items.addAll(page.items);
      nextKey = page.key;
      hasMore = page.key != null;
      totalCount = db.countLikes(includeDeleted: false);
    } finally {
      loadingPage = false;
      notifyListeners();
    }
  }

  Future<void> setMode(SortMode m) async {
    if (m == mode) return;
    mode = m;
    await reload(reset: true);
    await saveViewState();
  }

  Future<void> setFilter(LikesFilter f) async {
    filter = f;
    await reload(reset: true);
    await saveViewState();
  }

  Future<void> reshuffle() async {
    db.reshuffle();
    if (mode == SortMode.random) {
      await reload(reset: true);
    }
    notifyListeners();
  }

  /// 时间轴跳转：把列表锚定到某个 seq（喜欢顺序）。
  Future<void> jumpToSeq(int seq) async {
    items.clear();
    hasMore = true;
    nextKey = PageKey(seq: seq - 1);
    notifyListeners();
    await loadMore();
    await saveViewState();
  }

  /// 时间轴跳转：跳到某个发布月份（`YYYY-MM`）。
  Future<void> jumpToMonth(String month) async {
    if (mode == SortMode.random) {
      await setMode(SortMode.publishDate);
    }
    final seq = db.newestSeqInMonth(month);
    if (seq == null) return;
    await jumpToSeq(seq);
  }

  /// 时间轴数据（模式 A 的分桶 / 模式 B 的月份）。
  ///
  /// 这两个查询每次都要扫全表（5 万条时约 500 次小查询），而 UI 在每次
  /// notifyListeners 后都会重建时间轴 —— 所以必须缓存，只在数据真的变了时失效。
  List<({int fromSeq, int toSeq, int count, DateTime? approxDate})>? _estimatedCache;
  List<MonthBucket>? _monthsCache;

  void _invalidateTimelineCache() {
    _estimatedCache = null;
    _monthsCache = null;
  }

  List<({int fromSeq, int toSeq, int count, DateTime? approxDate})>
      estimatedTimeline() =>
          _estimatedCache ??= db.estimatedBuckets();

  List<MonthBucket> months() => _monthsCache ??= db.months();

  void select(String? tweetId) {
    selectedTweetId = tweetId;
    notifyListeners();
    unawaited(saveViewState());
  }

  // ------------------------------------------------------------------ 同步

  Future<void> startBackfill({int? maxItems}) async {
    final svc = syncService;
    final acc = accountId;
    if (svc == null || acc == null) return;
    syncError = null;
    _cancel = SyncCancel();
    syncProgress = const SyncProgress(pages: 0, fetched: 0, inserted: 0);
    notifyListeners();
    try {
      await svc.backfill(
        accountId: acc,
        maxItems: maxItems,
        onProgress: (pr) {
          syncProgress = pr;
          notifyListeners();
        },
        cancel: _cancel,
      );
      await reload(reset: true);
    } on XRequestException catch (e) {
      syncError = e.message;
      notifyListeners();
    } catch (e) {
      syncError = '$e';
      notifyListeners();
    } finally {
      _cancel = null;
    }
  }

  Future<void> syncNew() async {
    final svc = syncService;
    final acc = accountId;
    if (svc == null || acc == null) return;
    syncError = null;
    _cancel = SyncCancel();
    syncProgress = const SyncProgress(pages: 0, fetched: 0, inserted: 0);
    notifyListeners();
    try {
      await svc.syncNew(
        accountId: acc,
        maxItems: settings.autoSync.maxItems,
        onProgress: (pr) {
          syncProgress = pr;
          notifyListeners();
        },
        cancel: _cancel,
      );
      await reload(reset: true);
    } on XRequestException catch (e) {
      syncError = e.message;
      notifyListeners();
    } catch (e) {
      syncError = '$e';
      notifyListeners();
    } finally {
      _cancel = null;
    }
  }

  void cancelSync() => _cancel?.cancel();

  void clearSyncError() {
    syncError = null;
    syncProgress = null;
    notifyListeners();
  }

  /// 连通性自检：分别探 x.com（接口）、pbs（图片）、video（视频）。
  Future<List<({String host, bool ok, int ms, String? note})>>
      diagnoseConnectivity() async {
    final resolution = await buildHttpClient(settings.proxy);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    final http = IOClient(client);
    final targets = <String>[
      'https://x.com/',
      'https://pbs.twimg.com/',
      'https://video.twimg.com/',
    ];
    final out = <({String host, bool ok, int ms, String? note})>[];
    for (final url in targets) {
      final sw = Stopwatch()..start();
      try {
        final resp = await http
            .get(Uri.parse(url), headers: const {'user-agent': kWebUserAgent})
            .timeout(const Duration(seconds: 10));
        sw.stop();
        out.add((
          host: Uri.parse(url).host,
          ok: resp.statusCode < 500,
          ms: sw.elapsedMilliseconds,
          note: 'HTTP ${resp.statusCode}'
              '${resolution.usedProxy != null ? " via ${resolution.usedProxy}" : " direct"}',
        ));
      } catch (e) {
        sw.stop();
        out.add((
          host: Uri.parse(url).host,
          ok: false,
          ms: sw.elapsedMilliseconds,
          note: '$e',
        ));
      }
    }
    http.close();
    return out;
  }

  /// 把一条喜欢的所有媒体存到本地（离线可看）。
  /// 返回 null 表示成功，否则返回错误文案。
  Future<String?> saveOffline(LikeItem item) async {
    final cache = mediaCache;
    if (cache == null) return 'media cache not initialised';
    if (item.media.isEmpty) return 'no media';
    for (var i = 0; i < item.media.length; i++) {
      final m = item.media[i];
      final url = m.isPlayable ? (m.bestPlaybackUrl ?? m.url) : m.url;
      final file = await cache.ensureCached(
        tweetId: item.tweetId,
        idx: i,
        url: url,
      );
      if (file == null) return 'download failed: $url';
    }
    notifyListeners();
    return null;
  }

  Future<String?> unlike(String tweetId) async {
    final svc = syncService;
    if (svc == null) return '未登录';
    try {
      await svc.unlike(tweetId);
      items.removeWhere((i) => i.tweetId == tweetId);
      if (selectedTweetId == tweetId) selectedTweetId = null;
      totalCount = db.countLikes(includeDeleted: false);
      _invalidateTimelineCache();
      notifyListeners();
      return null;
    } on XRequestException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }
}

/// 极简依赖注入。
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!.notifier!;
  }
}

/// 便于在没有 context 的地方拿（比如后台任务）。
AppController? appControllerGlobal;

http.Client createPlainClient() => http.Client();
