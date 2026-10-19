/// 刷视频页：直接用**内嵌 X 网页**刷。
///
/// 上一版是拿本地喜欢库拼的两个假来源（关注 / 随机），做不到「往下刷出现
/// 陌生的视频」。这里改成把 X 自己的首页装进来 —— 视频、推荐、关注全由 X
/// 负责，我们只负责切「正在关注 / 为你推荐」两个标签。
///
/// 和 X 搜索页（[XSearchPage]）同一个思路：X 的 GraphQL 要 `x-client-transaction-id`
/// 签名，纯 HTTP 拉不到关注时间线与推荐流，所以让它自己的前端去发请求。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';

enum SwipeTab { following, forYou }

class SwipeFeedPage extends StatefulWidget {
  const SwipeFeedPage({super.key});

  @override
  State<SwipeFeedPage> createState() => _SwipeFeedPageState();
}

class _SwipeFeedPageState extends State<SwipeFeedPage> {
  static const _home = 'https://x.com/home';

  SwipeTab _tab = SwipeTab.forYou;
  bool _cookiesReady = false;
  bool _loading = true;
  String? _error;
  InAppWebViewController? _web;

  @override
  void initState() {
    super.initState();
    _seedCookies();
  }

  /// 把 App 的登录态写进 WebView 的 cookie 容器，否则打开就是登录墙。
  Future<void> _seedCookies() async {
    try {
      final session = AppScope.read(context).session;
      if (session != null) {
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
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _cookiesReady = true);
    }
  }

  /// 点 X 自己的标签页（中英文都试）。
  ///
  /// 不拼 URL：X 首页两个标签共用 `/home`，靠前端状态切换，
  /// `?f=following` 这类参数它并不认。
  Future<void> _selectTab(InAppWebViewController controller) async {
    final wanted = _tab == SwipeTab.following
        ? "['Following','正在关注','关注']"
        : "['For you','For You','为你推荐','推荐']";
    await controller.evaluateJavascript(
      source:
          '''
(function(){
  var wanted = $wanted;
  var nodes = Array.prototype.slice.call(
    document.querySelectorAll('[role="tab"], span, div')
  );
  for (var i = 0; i < nodes.length; i++) {
    var t = (nodes[i].textContent || '').trim();
    if (wanted.indexOf(t) !== -1) {
      var target = nodes[i].closest('[role="tab"]') || nodes[i];
      try { target.click(); } catch (e) {}
      return true;
    }
  }
  return false;
})();
''',
    );
  }

  Future<void> _switchTab(SwipeTab next) async {
    if (next == _tab) return;
    setState(() => _tab = next);
    final c = _web;
    if (c == null) return;
    // 已经在 home 上就只点标签，不重新加载（省一次整页刷新）。
    await _selectTab(c);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _tab == SwipeTab.following
              ? t('swipe.following')
              : t('swipe.recommended'),
        ),
        actions: [
          IconButton(
            tooltip: t('swipe.switch'),
            onPressed: () => _switchTab(
              _tab == SwipeTab.following ? SwipeTab.forYou : SwipeTab.following,
            ),
            icon: Icon(
              _tab == SwipeTab.following
                  ? Icons.people_alt
                  : Icons.auto_awesome,
            ),
          ),
          IconButton(
            tooltip: t('author.openX'),
            onPressed: () => launchUrl(
              Uri.parse(_home),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: !_cookiesReady
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_home)),
                  initialSettings: InAppWebViewSettings(
                    isInspectable: false,
                    thirdPartyCookiesEnabled: true,
                    sharedCookiesEnabled: true,
                    supportMultipleWindows: true,
                    // 让视频能自动播：X 网页会按这个设置决定要不要静音起播。
                    mediaPlaybackRequiresUserGesture: false,
                  ),
                  onWebViewCreated: (c) => _web = c,
                  onLoadStop: (controller, url) async {
                    if (mounted) setState(() => _loading = false);
                    // 页面刚起来时标签可能还没渲染，稍等一下再点。
                    await Future<void>.delayed(
                      const Duration(milliseconds: 900),
                    );
                    if (!mounted) return;
                    await _selectTab(controller);
                  },
                  onReceivedHttpError: (controller, request, response) {
                    if (request.isForMainFrame != true) return;
                    final code = response.statusCode ?? 0;
                    if (code >= 400 && mounted) {
                      setState(() => _error = 'HTTP $code');
                    }
                  },
                  onReceivedError: (controller, request, error) {
                    if (request.isForMainFrame != true) return;
                    if (mounted) setState(() => _error = error.description);
                  },
                ),
                if (_loading)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_error != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Material(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                _error = null;
                                _loading = true;
                              }),
                              child: Text(t('action.retry')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
