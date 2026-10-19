/// 应用外壳：数据库、设置、登录态、网络出口、媒体缓存 —— 也就是「跑起来要什么」。
///
/// 浏览状态（[BrowseState]）与同步状态（[SyncController]）各自是独立的
/// [Listenable]，UI 只订阅自己关心的那一个：同步进度不会再把上千张卡片
/// 一起重建。这个类只负责它们的装配与生命周期。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'auth/auth_store.dart';
import 'core/l10n.dart';
import 'core/settings.dart';
import 'db/app_database.dart';
import 'media/media_cache.dart';
import 'model/like_item.dart';
import 'net/proxy.dart';
import 'net/translate.dart';
import 'state/browse_state.dart';
import 'state/sync_state.dart';
import 'sync/reconciler.dart';
import 'sync/search_parser.dart';
import 'sync/sync_service.dart';
import 'sync/metrics.dart';
import 'sync/x_client.dart';
import 'version.dart';

class AppController extends ChangeNotifier {
  AppController();

  late AppSettings settings;
  late AppDatabase db;
  late AuthStore authStore;

  /// 浏览状态（在 [boot] 里装配）。
  late final BrowseState browse;

  /// 书签的浏览状态：与 [browse] 同构，但只看 `kind = 'bookmark'`。
  late final BrowseState bookmarks;

  /// 同步状态（在 [boot] 里装配）。
  late final SyncController sync;

  XSession? session;
  XClient? client;

  /// 设置（导航项、显示项）改完之后通知一次，让依赖设置的页面重建。
  void refreshSettings() => notifyListeners();

  /// 推文的互动数据（回复/转发/喜欢/浏览）。来自 `raw_json` 里的快照，
  /// v1.1 端点被 X 下线之后不再现拉。
  late final MetricsStore metrics = MetricsStore();

  /// 翻译（正文/搜索词）。走 App 自己的 HTTP 客户端，所以用户配的代理对它同样生效。
  /// 译文落进 SQLite kv：同一条帖子只翻一次。
  late final TranslationService translate = TranslationService(
    () => _xHttp,
    load: (key) => db.cachedTranslation(key),
    save: (key, value) => db.saveTranslation(key, value),
  );
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

  /// 启动卡在哪一步（报错时一起展示，免得只看到一句「登录失败」）。
  String bootStage = '启动';

  /// 启动链的任何一处都可能因为平台差异失败（Keystore 坏掉、数据库打不开…）。
  /// 以前异常直接变成一句 bootError，用户在手机上只能看到「Sign-in failed」。
  /// 现在记录阶段 + 后续步骤尽量降级，让 App 至少能打开并说清楚原因。
  Future<void> boot() async {
    bootError = null;
    booting = true;
    notifyListeners();
    try {
      bootStage = '读取设置';
      settings = await AppSettings.load();
      bootStage = '定位应用目录';
      final support = await getApplicationSupportDirectory();
      final dbPath = p.join(support.path, 'likes.db');
      bootStage = '打开本地数据库';
      db = AppDatabase.open(dbPath);
      bootStage = '初始化安全存储';
      authStore = AuthStore();
      _mediaRoot = settings.cacheDir != null
          ? Directory(settings.cacheDir!)
          : Directory(p.join(support.path, 'media'));

      browse = BrowseState(
        db: db,
        persistView: (kind, view) => settings.setViewOf(kind, view),
      );
      // 书签是第二个来源：独立的 BrowseState → 排序档/游标/滚动都互不干扰。
      bookmarks = BrowseState(
        db: db,
        persistView: (kind, view) => settings.setViewOf(kind, view),
        kinds: const {'bookmark'},
      );
      sync = SyncController(
        db: db,
        serviceOf: () => syncService,
        accountIdOf: () => accountId,
        autoSyncOf: () => settings.autoSync,
        onDataChanged: () async {
          await browse.refresh();
          await bookmarks.refresh();
        },
      );

      // 先把登录态读出来，再建客户端 —— 反过来的话 session 为 null，
      // 建出来的 client / syncService 都是空的，启动后同步与后台校验全失效。
      // 安全存储失败不再致命：只是这次运行不记忆登录态（AuthStore 内部已降级）。
      bootStage = '恢复登录态';
      final stored = await authStore.load();
      if (stored != null) session = stored;

      bootStage = '建立网络客户端';
      await _rebuildClient();
      _refreshAccountId();

      if (stored != null) {
        // 有缓存先显示，网络校验放到后台，避免启动被墙/代理卡住。
        unawaited(_verifyInBackground());
      }
      bootStage = '读取第一页';
      browse.restoreFrom(settings.viewOf('like'));
      await browse.reload(reset: true);
      bookmarks.restoreFrom(settings.viewOf('bookmark'));
      await bookmarks.reload(reset: true);
    } catch (e, st) {
      bootError = '[步骤: $bootStage] $e';
      debugPrint('boot failed at $bootStage: $e\n$st');
    } finally {
      booting = false;
      bootStage = '完成';
      notifyListeners();
    }
  }

  /// 给「复制错误信息」按钮用：把设备/版本/失败阶段打成一坨，方便回帖。
  String diagnostics() {
    final buf = StringBuffer()
      ..writeln('xlikemanage $kAppVersion')
      ..writeln(
        'platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('locale: ${Platform.localeName}')
      ..writeln('stage: $bootStage');
    if (bootError != null) buf.writeln('error: $bootError');
    final store = authStoreOrNull;
    if (store?.lastError != null) {
      buf.writeln('secureStore: ${store!.lastError}');
    }
    final s = settingsOrNull;
    if (s?.storageError != null) buf.writeln('settings: ${s!.storageError}');
    if (proxyWarning != null) buf.writeln('proxy: $proxyWarning');
    return buf.toString();
  }

  /// boot 之前的 late 字段访问一律走这两个安全访问器。
  AppSettings? get settingsOrNull {
    try {
      return settings;
    } catch (_) {
      return null;
    }
  }

  /// boot 之前读 authStore 会炸（late），这里给个安全访问器。
  AuthStore? get authStoreOrNull {
    try {
      return authStore;
    } catch (_) {
      return null;
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
      bookmarksReconciler?.stop();
      bookmarksReconciler = null;
    }
    _autosyncTimer?.cancel();
    _autosyncTimer = null;
    if (session != null) _scheduleAutoSync();
    notifyListeners();
  }

  /// 巡边器：让「滚到哪核到哪」和「陈段轮转」共用一个预算队列。
  ///
  /// 两个来源各一个实例：它们的区段、游标、预算互不相干，合成一个会把
  /// 「喜欢核对」和「书签核对」挤进同一个 4 次/分的预算里。
  Reconciler? reconciler;
  Reconciler? bookmarksReconciler;

  void _ensureReconciler() {
    final acc = accountId;
    final c = client;
    if (acc == null || c == null) return;
    reconciler ??= Reconciler(db: db, client: c, accountId: acc)..start();
    bookmarksReconciler ??= Reconciler(
      db: db,
      client: c,
      accountId: acc,
      kind: 'bookmark',
    )..start();
  }

  /// UI 滚动停下时调用：把当前可见的一段标脏。
  void markViewportDirty(int fromSeq, int toSeq, {String kind = 'like'}) {
    _ensureReconciler();
    (kind == 'bookmark' ? bookmarksReconciler : reconciler)?.markViewportDirty(
      fromSeq,
      toSeq,
    );
  }

  Timer? _autosyncTimer;

  /// 自动同步：桌面/前台按间隔投一次预算；默认关。
  void _scheduleAutoSync() {
    final cfg = settings.autoSync;
    if (!cfg.enabled) return;
    _autosyncTimer?.cancel();
    _autosyncTimer = Timer.periodic(
      Duration(minutes: cfg.intervalMinutes),
      (_) => unawaited(_autoSyncTick()),
    );
  }

  /// 自动同步一轮：喜欢和书签都要补（书签增量不跑就永远只有回填那一刻的快照）。
  Future<void> _autoSyncTick() async {
    await sync.syncNew();
    await sync.syncNew(kind: 'bookmark');
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

  /// 把当前登录态导出成一段可复制的文本。
  ///
  /// 用途：手机上拿不到 cookie（Chrome 手机版没有 F12），而桌面端很容易 ——
  /// 先在 Windows 端登录，导出这段文本，再粘到手机的登录页里。
  String? exportSession() {
    final s = session;
    if (s == null) return null;
    return 'XLI1:${base64Encode(utf8.encode(jsonEncode(s.toJson())))}';
  }

  /// 导入 [exportSession] 产出的文本；成功返回 null，失败返回提示文案。
  Future<String?> importSession(String raw) async {
    final text = raw.trim();
    if (!text.startsWith('XLI1:')) return 'not an exported session';
    try {
      final decoded = utf8.decode(base64Decode(text.substring(5)));
      final json = jsonDecode(decoded);
      if (json is! Map) return 'corrupted payload';
      final s = XSession.fromJson(Map<String, Object?>.from(json));
      if (s.authToken.isEmpty || s.ct0.isEmpty) return 'payload has no cookies';
      final verified = await verifySession(s);
      await signIn(verified);
      return null;
    } on XRequestException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
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

  /// 取消喜欢：网络 + 本地标记 + 列表立刻不显示。
  ///
  /// 播放页里当前这条**不会**消失（心形变空心），点一下就能点回喜欢 ——
  /// 所以列表这份视图单独过滤，见 [BrowseState.listItems]。
  Future<String?> unlike(String tweetId) async {
    final err = await sync.unlike(tweetId);
    if (err != null) return err;
    browse.markRemoved(tweetId);
    return null;
  }

  /// 重新喜欢（取消之后又点回来）：库里恢复 + 列表重新显示。
  Future<String?> like(String tweetId) async {
    final err = await sync.like(tweetId);
    if (err != null) return err;
    browse.unmarkRemoved(tweetId);
    return null;
  }

  /// 加入书签：网络成功后再落本地，然后刷新列表。
  Future<String?> bookmark(LikeItem item) async {
    final err = await sync.bookmark(item);
    if (err != null) return err;
    await _refreshBookmarkViews();
    return null;
  }

  /// 移除书签：本地标记 removed（可撤回）。
  Future<String?> unbookmark(String tweetId) async {
    final err = await sync.unbookmark(tweetId);
    if (err != null) return err;
    await _refreshBookmarkViews();
    return null;
  }

  /// 只发网络、不动本地：播放页里取消后用，退出播放页时才真正落库。
  Future<String?> unlikeRemote(String tweetId) => sync.unlikeRemote(tweetId);

  Future<String?> unbookmarkRemote(String tweetId) =>
      sync.unbookmarkRemote(tweetId);

  /// WebView 兜底成功之后的本地落地：网络那一步已经在网页里做完了。
  Future<void> bookmarkLocally(LikeItem item) async {
    syncService?.bookmarkLocally(item, accountId: accountId ?? 0);
    await _refreshBookmarkViews();
  }

  Future<void> unbookmarkLocally(String tweetId) async {
    syncService?.unbookmarkLocally(tweetId);
    await _refreshBookmarkViews();
  }

  /// 喜欢 / 取消喜欢的本地落地（网页兜底写成功之后调用）。
  Future<void> likeLocally(String tweetId) async {
    syncService?.likeLocally(tweetId);
    browse.unmarkRemoved(tweetId);
  }

  Future<void> unlikeLocally(String tweetId) async {
    syncService?.unlikeLocally(tweetId);
    browse.markRemoved(tweetId);
  }

  Future<void> _refreshBookmarkViews() async {
    await browse.refresh();
    await bookmarks.refresh();
  }

  /// 远端「我正在关注的人」。失败返回空列表，调用方回退本地记录。
  Future<List<({String id, String screenName, String name})>>
  fetchFollowing() async {
    final c = client;
    if (c == null) return const [];
    try {
      return await c.fetchFollowing();
    } catch (_) {
      return const [];
    }
  }

  /// 向 X 核对「是否已关注」。null = 查不到（未登录/网络/接口变了）。
  Future<bool?> isFollowingRemote(String screenName) async {
    final c = client;
    if (c == null) return null;
    return c.isFollowing(screenName);
  }

  /// 关注/取关作者。成功返回 null。
  ///
  /// 关注是**写操作**，失败原因要原样带给用户（限流 / queryId 失效 / 网络），
  /// 所以这里不做静默降级 —— 由调用方决定是否提示「去 X 里手动点」。
  Future<String?> setFollowing(String userId, bool following) async {
    final c = client;
    if (c == null) return t('error.network');
    try {
      if (following) {
        await c.follow(userId);
      } else {
        await c.unfollow(userId);
      }
      db.setFollowing(userId, following);
      notifyListeners();
      return null;
    } on XRequestException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// 在 X 上搜索内容（全网，不是本地喜欢）。
  Future<SearchResultPage> searchX({
    required String rawQuery,
    SearchProduct product = SearchProduct.latest,
    String? cursor,
  }) async {
    final c = client;
    if (c == null) {
      throw XRequestException(XErrorKind.sessionExpired, t('error.network'));
    }
    return c.fetchSearch(rawQuery: rawQuery, product: product, cursor: cursor);
  }

  /// 保存播放偏好。
  Future<void> setPlayback(PlaybackSettings cfg) async {
    await settings.setPlayback(cfg);
    notifyListeners();
  }

  /// 当前应当使用的界面语言。
  ///
  /// 设置里明确选了中文/英文就用它，否则跟随系统（`Platform.localeName`）——
  /// 这里不用 `Localizations.localeOf`，因为该值要在 MaterialApp 之上决定。
  AppLang get effectiveLang {
    final code = settingsOrNull?.language;
    if (code == 'zh') return AppLang.zh;
    if (code == 'en') return AppLang.en;
    return Platform.localeName.toLowerCase().startsWith('zh')
        ? AppLang.zh
        : AppLang.en;
  }

  /// 切换界面语言（null = 跟随系统）。切换后需要整树重建，见 main.dart。
  Future<void> setLanguage(String? code) async {
    await settings.setLanguage(code);
    notifyListeners();
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
        note:
            'HTTP ${resp.statusCode}'
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
    bookmarksReconciler?.stop();
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

  /// 拿得到就拿，拿不到返回 null。
  ///
  /// 给「没有外壳也要能渲染」的组件用（PostCard 的互动数据行、MediaImage 的
  /// 带 cookie 请求）：它们被单独放进测试或预览时不该因为少一层 InheritedWidget
  /// 就整块崩掉，退化成「没有这项功能」更合适。
  static AppController? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
}
