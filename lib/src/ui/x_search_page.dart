/// X 全网搜索：用内嵌 WebView 驱动 X 自己的搜索页。
///
/// ## 为什么不用 HTTP 直接打 `SearchTimeline`
/// 我们本来写了 `XClient.fetchSearch`（含解析器与单测），但实测必然失败：
/// X 现在给每个 GraphQL 请求都签一个 `x-client-transaction-id` 头，这个值由
/// 前端 JS 按请求内容实时算出来，**纯 HTTP 复刻一定被拒**（404/403）。
/// 参考实测记录：https://github.com/shuaipotian-joke/huashu-chrome/blob/HEAD/docs/经验/x.com.md
///
/// 所以这里换了思路：把 X 自己的页面装进来，让它发请求。好处是搜索语法、
/// 分页、图片视频、长帖补全全部是 X 原生行为，永远不会因为我们跟不上前端而失效。
/// `fetchSearch` 的代码与单测仍然保留：哪天 X 放开校验，它能直接接上。
///
/// 登录态：WebView 与 App 共用同一份 `auth_token` / `ct0`（从安全存储里读出来
/// 再写进 WebView 的 cookie 容器），所以打开就是已登录状态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../sync/search_parser.dart';

class XSearchPage extends StatefulWidget {
  const XSearchPage({
    super.key,
    required this.rawQuery,
    this.product = SearchProduct.latest,
  });

  /// 完整搜索串（可能包含 `from:` / `since:` 等操作符）。
  final String rawQuery;

  /// 对应 X 网页上的「热门 / 最新 / 媒体」三个标签。
  final SearchProduct product;

  @override
  State<XSearchPage> createState() => _XSearchPageState();
}

class _XSearchPageState extends State<XSearchPage> {
  bool _cookiesReady = false;
  bool _loading = true;
  String? _error;

  String get _url {
    final f = switch (widget.product) {
      SearchProduct.top => 'top',
      SearchProduct.media => 'media',
      _ => 'live',
    };
    return 'https://x.com/search?q=${Uri.encodeQueryComponent(widget.rawQuery)}'
        '&src=typed_query&f=$f';
  }

  @override
  void initState() {
    super.initState();
    _seedCookies();
  }

  /// 把 App 的登录态写进 WebView 的 cookie 容器。
  ///
  /// 不写的话打开就是未登录状态的搜索页（X 会要求登录，或者只给一堆登录墙）。
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
      // cookie 写不进去不致命：X 页面自己会提示登录，用户能看到原因。
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _cookiesReady = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('search.onX'), style: const TextStyle(fontSize: 15)),
            Text(
              widget.rawQuery,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: t('author.openX'),
            onPressed: () => launchUrl(
              Uri.parse(_url),
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
                  initialUrlRequest: URLRequest(url: WebUri(_url)),
                  initialSettings: InAppWebViewSettings(
                    isInspectable: false,
                    thirdPartyCookiesEnabled: true,
                    sharedCookiesEnabled: true,
                    supportMultipleWindows: true,
                    // 用默认 UA（移动端布局），桌面 UA 在手机上排版很糟。
                  ),
                  onLoadStop: (controller, url) {
                    if (mounted) setState(() => _loading = false);
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
