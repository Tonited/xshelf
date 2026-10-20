/// 全局写操作宿主：替 App 去点 X 网页上的按钮。
///
/// ## 为什么要这么做
/// 喜欢 / 取消喜欢 / 加书签 / 移书签都是 GraphQL **mutation**。X 要求它们带一个
/// `x-client-transaction-id` —— 那是它自家 JS 现算的签名。纯 HTTP 拿不到，缺失时
/// X 不报 401/403，而是返回 **404 且响应体为空**，看起来像「接口失效」。
/// queryId 补不回来（实测它根本没变），唯一可靠的做法是让 X 自己的前端去发。
///
/// ## 为什么是「独立路由里的一页」而不是塞在 Stack 里
/// 早先的实现把 WebView 放在 `Stack` 里（再早还试过 `top: -4000` 的屏幕外），
/// **X 的前端在里面渲染不出来**：页面 HTML 正常返回（`document.title` 已经是推文
/// 标题，说明登录态、URL、网络全对），但 `#react-root` 始终是空的 —— DOM 有
/// ~290KB、可见文字却只有 35 个字符，一个 `data-testid` 都查不到。
/// 排除过的方向：离屏还是可见、尺寸大小、Chrome UA、`javaScriptEnabled` /
/// `domStorageEnabled`、Scaffold 隔离、去掉外层 Stack、把播放器整棵移走、
/// 首页/作者主页/推文详情三种 URL —— 全都不改善。
///
/// 而同一个 X 站点用 [XWebPage]（`Navigator.push` 的独立路由、直接挂在
/// `Scaffold.body` 上）渲染完全正常。所以这里照搬那套宿主方式：点写操作时 push
/// 一页全屏 WebView，盖一层遮罩不打扰视线，点完自动 pop。
///
/// ## 交互
/// 调用方先做**乐观更新**（心形/书签立刻变），这里跑完再确认或回滚；
/// 遮罩是半透明的、不带任何手势，用户看到的就是「短暂地转一下圈」。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_controller.dart';
import '../core/l10n.dart';

/// 要通过网页完成的写操作。
enum XWriteAction {
  like,
  bookmark;

  /// X 网页里「已开启」和「未开启」两种状态各自的 `data-testid`。
  String onTestId() => this == XWriteAction.like ? 'unlike' : 'removeBookmark';
  String offTestId() => this == XWriteAction.like ? 'like' : 'bookmark';
}

class _Job {
  const _Job(this.tweetId, this.action, this.add);
  final String tweetId;
  final XWriteAction action;

  /// 目标状态：true = 打开（喜欢/收藏），false = 关闭。
  final bool add;
}

class XActionHost extends StatefulWidget {
  const XActionHost({super.key, required this.child});

  final Widget child;

  static final GlobalKey<XActionHostState> hostKey =
      GlobalKey<XActionHostState>();

  /// 把某个状态写成 [add]。成功返回 true。
  static Future<bool> toggle({
    required String tweetId,
    required XWriteAction action,
    required bool add,
  }) async {
    final s = hostKey.currentState;
    if (s == null) return false;
    return s.toggle(tweetId: tweetId, action: action, add: add);
  }

  @override
  State<XActionHost> createState() => XActionHostState();
}

class XActionHostState extends State<XActionHost> {
  _Job? _job;
  Completer<bool>? _completer;
  bool _running = false;
  bool _driving = false;
  NavigatorState? _nav;

  Future<bool> toggle({
    required String tweetId,
    required XWriteAction action,
    required bool add,
  }) async {
    // 同一时刻只跑一个：两个页面同时点也只会排队（直接拒绝第二个，调用方会回滚）。
    if (_running) return false;
    _running = true;
    _completer = Completer<bool>();
    // 先把登录态写进 WebView 的 cookie 容器，再打开页面。
    //
    // 这一步不能省：只设 `sharedCookiesEnabled: true` 只是「共用 CookieManager」
    // 的意思，**冷启动时那个容器里并没有 x.com 的 cookie** —— 少了 auth_token，
    // 页面会停在登录墙后面。其他几个 WebView（x_web_page / x_search_page /
    // swipe_feed_page）都在打开前自己注入了，这里补齐同一套做法。
    await _seedCookies();
    if (!mounted || _completer == null) {
      _running = false;
      return false;
    }
    final job = _Job(tweetId, action, add);
    _job = job;
    final nav = Navigator.of(context, rootNavigator: true);
    _nav = nav;
    unawaited(
      nav.push(
        PageRouteBuilder<void>(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.black54,
          transitionDuration: const Duration(milliseconds: 120),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (_, _, _) => _WriteRoute(
            job: job,
            onReady: (c) => unawaited(_drive(c)),
          ),
        ),
      ),
    );
    return _completer!.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _finish(false);
        return false;
      },
    );
  }

  /// 把 App 的登录态写进 WebView 的 cookie 容器。
  Future<void> _seedCookies() async {
    try {
      final session = AppScope.read(context).session;
      if (session == null) return;
      final cm = CookieManager.instance();
      for (final entry in [
        ('auth_token', session.authToken),
        ('ct0', session.ct0),
      ]) {
        await cm.setCookie(
          url: WebUri('https://x.com'),
          name: entry.$1,
          value: entry.$2,
          domain: '.x.com',
          path: '/',
          isSecure: true,
          isHttpOnly: true,
        );
      }
    } catch (_) {
      // 注入失败也照旧往下走：容器里若恰好已有 cookie，页面仍然能打开并点得动。
    }
  }

  void _finish(bool ok) {
    if (!_running) return;
    _running = false;
    _job = null;
    final c = _completer;
    _completer = null;
    final nav = _nav;
    _nav = null;
    if (nav != null && nav.mounted && nav.canPop()) nav.pop();
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  @override
  void dispose() {
    final c = _completer;
    _completer = null;
    if (c != null && !c.isCompleted) c.complete(false);
    super.dispose();
  }

  String _stateScript(XWriteAction action) =>
      '''
(() => {
  if (document.querySelector('[data-testid="${action.onTestId()}"]')) return 'on';
  if (document.querySelector('[data-testid="${action.offTestId()}"]')) return 'off';
  return 'unknown';
})();
''';

  /// 点「当前状态」那个按钮 —— 它自己会 toggle。
  String _clickScript(XWriteAction action, String current) {
    final tid = current == 'on' ? action.onTestId() : action.offTestId();
    return '''
(() => {
  const el = document.querySelector('[data-testid="$tid"]');
  if (!el) return 'no-button';
  try { el.click(); return 'clicked'; } catch (e) { return 'error:' + e; }
})();
''';
  }

  Future<void> _drive(InAppWebViewController controller) async {
    // `onLoadStop` 会因为重定向而触发多次（`/i/status/x` → `/<user>/status/x`）：
    // 不做防重入的话两个循环同时跑，第一个点完把按钮变成 `removeBookmark`，
    // 第二个再去点 `bookmark` 就扑空 —— 日志里那对 `clicked` / `no-button` 就是它。
    if (_driving) return;
    _driving = true;
    try {
      final job = _job;
      if (job == null) return;
      // 推文详情是 XHR 渲染的：轮询等按钮出现（最多约 15 秒）。
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted || _job != job) return;
        final state =
            '${await controller.evaluateJavascript(source: _stateScript(job.action))}';
        if (state == 'unknown') continue;
        final isOn = state == 'on';
        if (isOn == job.add) {
          _finish(true); // 已经是目标状态
          return;
        }
        final clicked = await controller.evaluateJavascript(
          source: _clickScript(job.action, state),
        );
        // ignore: avoid_print
        print('[x-write] ${job.action.name} add=${job.add} click=$clicked');
        // 点完要等 X 的界面**自己**翻转：mutation 发出去、响应回来、再重渲染，
        // 固定等 1.2 秒经常不够 —— 实测会误判成失败并把 UI 回滚掉（而 X 那边
        // 其实已经加上了）。这里轮询到状态真的变成目标值为止。
        final want = job.add ? 'on' : 'off';
        for (var j = 0; j < 12; j++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!mounted || _job != job) return;
          final after =
              '${await controller.evaluateJavascript(source: _stateScript(job.action))}';
          if (after == want) {
            _finish(true);
            return;
          }
        }
        _finish(false);
        return;
      }
      _finish(false);
    } finally {
      _driving = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 承载写操作 WebView 的独立页面（和 [XWebPage] 同一种宿主方式）。
class _WriteRoute extends StatelessWidget {
  const _WriteRoute({required this.job, required this.onReady});

  final _Job job;
  final void Function(InAppWebViewController) onReady;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('https://x.com/i/status/${job.tweetId}'),
              ),
              initialSettings: InAppWebViewSettings(
                // 和 [XWebPage] 完全一致 —— 那页在真机上能正常渲染 X。
                // 特别注意**不要**覆盖 userAgent：X 会按 UA 下发不同的前端
                // bundle，冒充 Chrome 反而会拿到一个在 WebView 里跑不起来的
                // 完整版。
                isInspectable: false,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                supportMultipleWindows: true,
                mediaPlaybackRequiresUserGesture: false,
              ),
              onLoadStop: (controller, url) => onReady(controller),
            ),
          ),
          // 半透明遮罩：不挡渲染（WebView 仍在下面可见），也不让用户盯着别人的
          // 时间线看 —— 大多数人只会看到一圈转动的进度。
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.82),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        job.action == XWriteAction.like
                            ? t('play.likeSyncing')
                            : (job.add
                                  ? t('play.bookmarkSyncing')
                                  : t('play.bookmarkSyncingOff')),
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
