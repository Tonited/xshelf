/// 全局写操作宿主：一个屏幕外的 WebView，专门替 App 去点 X 网页上的按钮。
///
/// ## 为什么要这么做
/// 喜欢 / 取消喜欢 / 加书签 / 移书签都是 GraphQL **mutation**。X 要求它们带一个
/// `x-client-transaction-id` —— 那是它自家 JS 现算的签名。纯 HTTP 拿不到，缺失时
/// X 不报 401/403，而是返回 **404 且响应体为空**，看起来像「接口失效」。
/// queryId 补不回来（实测它根本没变），唯一可靠的做法是让 X 自己的前端去发。
///
/// ## 为什么要「屏幕外」而不是弹窗
/// 弹窗方案能用，但每次都要挡住界面等 3–6 秒，用户没法继续滑。这里改成：
/// - WebView 放在 `top: -4000`（屏幕外，Flutter 会裁掉，但页面照常加载执行）；
/// - 界面只显示一条**底部小提示**，不拦截任何手势；
/// - 调用方先做**乐观更新**，这里跑完再确认/回滚。
///
/// 用户看到的就是：点一下 → 心形/书签立刻变 → 几秒后提示消失。
///
/// ## 已知限制（实测）
/// 这个 WebView 里 X 的前端**渲染不出来**：页面 HTML 正常返回（`document.title`
/// 已经是推文的标题，说明登录态和 URL 都对），但 `#react-root` 始终是空的 ——
/// DOM 有 ~290KB、可见文字却只有 35 个字符，一个 `data-testid` 都查不到。
/// 排除过的方向：离屏还是可见、尺寸大小、Chrome UA、`javaScriptEnabled` /
/// `domStorageEnabled`、Scaffold 隔离、去掉外层 Stack、把播放器整棵移走、
/// 首页/作者主页/推文详情三种 URL —— 全都不改善。
/// 同一个 X 站点用 [XWebPage]（独立路由里、直接挂在 `Scaffold.body`）渲染完全正常，
/// 所以差异在**宿主方式**而不是站点本身；改成独立路由承载是下一步要试的方案。
/// 在修好之前，写操作会回滚并提示 [play.writeFailed]，而不是假装成功。
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
    // 这一步不能省：屏幕外这页只设 `sharedCookiesEnabled: true` 只是「共用
    // CookieManager」的意思，**冷启动时那个容器里并没有 x.com 的 cookie** ——
    // 少了 auth_token，`/i/status/<id>` 会停在登录墙后面，推文详情永远渲染不出
    // 按钮。其他几个 WebView（x_web_page / x_search_page / swipe_feed_page）
    // 都在打开前自己注入了，这里补齐同一套做法。
    await _seedCookies();
    if (!mounted || _completer == null) {
      _running = false;
      return false;
    }
    setState(() => _job = _Job(tweetId, action, add));
    return _completer!.future.timeout(
      const Duration(seconds: 30),
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
    final c = _completer;
    _completer = null;
    if (mounted) setState(() => _job = null);
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
    final job = _job;
    if (job == null) return;
    // 推文详情是 XHR 渲染的：轮询等按钮出现（最多约 6 秒）。
    for (var i = 0; i < 12; i++) {
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
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted || _job != job) return;
      final after =
          '${await controller.evaluateJavascript(source: _stateScript(job.action))}';
      _finish(after == (job.add ? 'on' : 'off'));
      return;
    }
    _finish(false);
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return Stack(
      children: [
        widget.child,
        // 屏幕外：Flutter 会裁掉它，但 WebView 照常加载、照常执行 JS。
        if (job != null)
          Positioned(
            left: 0,
            top: -4000,
            child: SizedBox(
              width: 480,
              height: 960,
              child: InAppWebView(
                key: ValueKey('${job.tweetId}:${job.action.name}:${job.add}'),
                initialUrlRequest: URLRequest(
                  url: WebUri('https://x.com/i/status/${job.tweetId}'),
                ),
                initialSettings: InAppWebViewSettings(
                  // 和 [XWebPage] 保持一致（见文件头的「已知限制」：
                  // 即便如此这个 WebView 里的 X 前端仍然不渲染）。
                  isInspectable: false,
                  thirdPartyCookiesEnabled: true,
                  sharedCookiesEnabled: true,
                  supportMultipleWindows: true,
                  mediaPlaybackRequiresUserGesture: false,
                ),
                onLoadStop: (controller, url) => _drive(controller),
              ),
            ),
          ),
        // 不拦截任何手势，只是告诉用户「在后台同步」。
        if (job != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: IgnorePointer(
              child: Material(
                color: Theme.of(context).colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.onInverseSurface,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          job.action == XWriteAction.like
                              ? t('play.likeSyncing')
                              : (job.add
                                    ? t('play.bookmarkSyncing')
                                    : t('play.bookmarkSyncingOff')),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onInverseSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
