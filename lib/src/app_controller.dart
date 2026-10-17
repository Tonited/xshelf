/// 应用级状态：数据库、设置、登录态、网络客户端、分页游标。
///
/// 刻意不引第三方状态管理：一个 ChangeNotifier + InheritedNotifier 足够，
/// 依赖少、审起来快。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'auth/auth_store.dart';
import 'core/settings.dart';
import 'db/app_database.dart';
import 'model/like_item.dart';
import 'net/proxy.dart';
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

      await _rebuildClient();

      final stored = await authStore.load();
      if (stored != null) {
        session = stored;
        // 有缓存就先显示，网络校验放到后台，避免启动被墙/代理卡住。
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
      notifyListeners();
    } catch (_) {
      // 校验失败不踢人：可能是网络/代理问题，让 UI 提示即可。
    }
  }

  Future<void> _rebuildClient() async {
    final proxyCfg = settings.proxy;
    final resolution = await buildHttpClient(proxyCfg);
    proxyWarning = resolution.warning;
    final httpClient = IOClient(resolution.client);
    final s = session;
    if (s != null) {
      client = XClient(session: s, httpClient: httpClient);
      syncService = SyncService(db: db, client: client!);
    } else {
      client = null;
      syncService = null;
    }
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
    notifyListeners();
  }

  Future<void> signOut() async {
    session = null;
    await authStore.clear();
    await _rebuildClient();
    items.clear();
    nextKey = null;
    notifyListeners();
  }

  /// 用已有 cookie 校验一次（登录页/粘贴入口用）。
  Future<XSession> verifySession(XSession s) async {
    final resolution = await buildHttpClient(settings.proxy);
    final c = XClient(session: s, httpClient: IOClient(resolution.client));
    return c.verify();
  }

  int? get accountId {
    final s = session;
    if (s == null) return null;
    return db.upsertAccount(
      xUserId: s.userId,
      screenName: s.screenName,
      displayName: s.displayName,
      avatarUrl: s.avatarUrl,
    );
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

  Future<String?> unlike(String tweetId) async {
    final svc = syncService;
    if (svc == null) return '未登录';
    try {
      await svc.unlike(tweetId);
      items.removeWhere((i) => i.tweetId == tweetId);
      if (selectedTweetId == tweetId) selectedTweetId = null;
      totalCount = db.countLikes(includeDeleted: false);
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
