/// 通用 X 网页容器。
///
/// Grok、推文详情（回复列表）、搜索、刷视频都是「把 X 自己的页面装进来」——
/// 登录态从安全存储读出来写进 WebView 的 cookie 容器，打开就是已登录状态。
///
/// 为什么不自己实现回复列表：X 的 `Conversation` GraphQL 要
/// `x-client-transaction-id` 签名（纯 HTTP 必失败，见 docs/GRAPHQL.md §1.1），
/// 而回复的折叠、排序、图片、视频本来就是 X 前端的行为，复刻一遍只会更差。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';

class XWebPage extends StatefulWidget {
  const XWebPage({
    super.key,
    required this.url,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.onPageFinished,
  });

  final String url;
  final String title;

  /// 标题下面的小字（比如搜索词、推文 id）。
  final String? subtitle;

  /// 额外的 AppBar 按钮。
  final List<Widget> actions;

  /// 页面加载完成后回调（刷视频页用它点自己的标签）。
  final Future<void> Function(InAppWebViewController controller)?
  onPageFinished;

  @override
  State<XWebPage> createState() => _XWebPageState();
}

class _XWebPageState extends State<XWebPage> {
  bool _cookiesReady = false;
  bool _loading = true;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_cookiesReady && _error == null) _seedCookies();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, style: const TextStyle(fontSize: 15)),
            if (widget.subtitle != null)
              Text(
                widget.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
        actions: [
          ...widget.actions,
          IconButton(
            tooltip: t('author.openX'),
            onPressed: () => launchUrl(
              Uri.parse(widget.url),
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
                  initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                  initialSettings: InAppWebViewSettings(
                    isInspectable: false,
                    thirdPartyCookiesEnabled: true,
                    sharedCookiesEnabled: true,
                    supportMultipleWindows: true,
                    // 让页面里的视频能自动播。
                    mediaPlaybackRequiresUserGesture: false,
                  ),
                  onLoadStop: (controller, url) async {
                    if (mounted) setState(() => _loading = false);
                    await widget.onPageFinished?.call(controller);
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
