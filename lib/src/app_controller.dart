/// 应用外壳：数据库、设置、登录态、网络出口、媒体缓存 —— 也就是「跑起来要什么」。
///
/// 浏览状态（[BrowseState]）与同步状态（[SyncController]）各自是独立的
/// [Listenable]，UI 只订阅自己关心的那一个：同步进度不会再把上千张卡片
/// 一起重建。这个类只负责它们的装配与生命周期。
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
import 'state/browse_state.dart';
import 'state/sync_state.dart';
import 'sync/reconciler.dart';
import 'sync/sync_service.dart';
import 'sync/x_client.dart';

class AppController extends ChangeNotifier {
  AppController();

  late AppSettings settings;
  late AppDatabase db;
  late AuthStore authStore;

  /// 浏览状态（在 [boot] 里装配）。
  late final BrowseState browse;

  /// 同步状态（在 [boot] 里装配）。
  late final SyncController sync;

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

      browse = BrowseState(db: db, persistView: settings.setView);
      sync = SyncController(
        db: db,
        serviceOf: () => syncService,
        accountIdOf: () => accountId,
        autoSyncOf: () => settings.autoSync,
        onDataChanged: () => browse.refresh(),
      );

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
      browse.restoreFrom(settings.view);
      await browse.reload(reset: true);
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
      client = XClient(
        session: s,
        httpClient: httpClient,
        // 上次发现过的 queryId 直接用，省掉「抓首页 + 十几个 JS」的冷启动开销。
        presetQueryIds: {
          for (final op in kQueryIdOperations) op: ?db.cachedQueryId(op),
        },
        onQueryId: db.saveQueryId,
        onQueryIdInvalid: db.clearQueryId,
      );
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
      (_) => unawaited(sync.syncNew()),
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
    sync.reset();
    browse.resetAll();
    notifyListeners();
  }

  /// 用已有 cookie 校验一次（登录页/粘贴入口用）。
  Future<XSession> verifySession(XSession s) async {
    final resolution = await buildHttpClient(settings.proxy);
    final http = IOClient(resolution.client);
    try {
      return await XClient(session: s, httpClient: http).verify();
    } finally {
      http.close();
    }
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

  // ------------------------------------------------------------------ 动作

  /// 取消喜欢：网络 + 本地删除，然后从列表里摘掉（不重查整页）。
  Future<String?> unlike(String tweetId) async {
    final err = await sync.unlike(tweetId);
    if (err == null) browse.dropLocal(tweetId);
    return err;
  }

  /// 连通性自检：分别探 x.com（接口）、pbs（图片）、video（视频）。
  ///
  /// 三个目标并发探（串行时最坏要 30 秒以上）；并且**必须**用解析出来的那个
  /// client —— 以前这里 new 了一个裸 HttpClient，自检走的是直连，
  /// 配了代理的用户会看到「全红」但其实能正常用。
  Future<List<({String host, bool ok, int ms, String? note})>>
      diagnoseConnectivity() async {
    final resolution = await buildHttpClient(settings.proxy);
    final http = IOClient(resolution.client);
    const targets = [
      'https://x.com/',
      'https://pbs.twimg.com/',
      'https://video.twimg.com/',
    ];
    try {
      return await Future.wait([
        for (final url in targets) _probe(http, url, resolution.usedProxy),
      ]);
    } finally {
      http.close();
    }
  }

  Future<({String host, bool ok, int ms, String? note})> _probe(
    http.Client http,
    String url,
    String? usedProxy,
  ) async {
    final host = Uri.parse(url).host;
    final sw = Stopwatch()..start();
    try {
      final resp = await http
          .get(Uri.parse(url), headers: const {'user-agent': kWebUserAgent})
          .timeout(const Duration(seconds: 10));
      return (
        host: host,
        ok: resp.statusCode < 500,
        ms: sw.elapsedMilliseconds,
        note: 'HTTP ${resp.statusCode}'
            '${usedProxy != null ? " via $usedProxy" : " direct"}',
      );
    } catch (e) {
      return (host: host, ok: false, ms: sw.elapsedMilliseconds, note: '$e');
    }
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

  @override
  void dispose() {
    _autosyncTimer?.cancel();
    reconciler?.stop();
    _xHttp?.close();
    _mediaHttp?.close();
    // boot 失败时 db 可能还没建出来。
    try {
      db.dispose();
    } catch (_) {}
    super.dispose();
  }
}

/// 极简依赖注入。
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 订阅外壳状态（登录/启动/代理），外壳变化时重建。
  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!.notifier!;
  }

  /// 只读一次、不建立依赖：给「只拿服务、不关心外壳重建」的页面用。
  /// 这些页面自己用 `ListenableBuilder` 订阅 [BrowseState] / [SyncController]。
  static AppController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!.notifier!;
  }
}
