/// 现场学习 X 当前使用的 GraphQL queryId。
///
/// 背景：`Bookmarks` / `CreateBookmark` / `DeleteBookmark` 的 queryId 会随着 X 的
/// 前端发版轮换，内置值迟早失效（表现就是加书签返回 404）。这些定义在懒加载
/// chunk 里，纯 HTTP 抓不到、页面里 fetch 又会被 CORS 拦。
///
/// 这里换一个可靠得多的路子：**让 WebView 自己去请求，中途把请求 URL 记下来**。
/// X 的每个 GraphQL 调用都是 `/i/api/graphql/{queryId}/{operation}`，
/// 用 `shouldInterceptRequest` 就能把 queryId 从 URL 里读出来 —— 不解析 JS、
/// 不需要 CORS、也不依赖 chunk 命名。
///
/// 为了凑齐写操作，脚本会在一张真实推文上**点一次书签、再点一次撤销**，
/// 这样 `CreateBookmark` 与 `DeleteBookmark` 各出现一次；最后再打开书签页
/// 拿到 `Bookmarks`（回填用）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/l10n.dart';

class QueryIdProbePage extends StatefulWidget {
  const QueryIdProbePage({
    super.key,
    required this.operations,
    this.tweetId,
    this.windowTitle,
  });

  /// 想收集的操作名，例如 `Bookmarks`。
  final List<String> operations;

  /// 用来「点一次书签」的推文 id。为空时只抓书签页（`Bookmarks`）。
  final String? tweetId;

  final String? windowTitle;

  @override
  State<QueryIdProbePage> createState() => _QueryIdProbePageState();
}

class _QueryIdProbePageState extends State<QueryIdProbePage> {
  final Map<String, String> _learned = {};
  bool _loading = true;
  String? _error;
  Map<String, String>? _found;
  bool _done = false;
  int _stage = 0;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(const Duration(seconds: 60), () {
      if (_done || !mounted) return;
      _finish();
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    _timeout?.cancel();
    setState(() {
      _found = {
        for (final op in widget.operations)
          if (_learned.containsKey(op)) op: _learned[op]!,
      };
    });
  }

  /// 在页面里找到书签按钮并点一下。
  String get _clickBookmarkScript => '''
(() => {
  const nodes = Array.prototype.slice.call(
    document.querySelectorAll('button, [role="button"], [data-testid]')
  );
  const want = /bookmark|书签|收藏/i;
  for (const n of nodes) {
    const label = (n.getAttribute('aria-label') || '') + ' ' +
                  (n.getAttribute('data-testid') || '');
    if (want.test(label)) {
      try { n.click(); return 'clicked:' + label.trim(); } catch (e) {}
    }
  }
  return 'no-button';
})();
''';

  Future<void> _onPageLoaded(InAppWebViewController controller) async {
    if (_done) return;
    // 推文页：点一次书签（Create），再点一次撤销（Delete）。
    if (_stage == 0 && (widget.tweetId ?? '').isNotEmpty) {
      _stage = 1;
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (!mounted || _done) return;
      await controller.evaluateJavascript(source: _clickBookmarkScript);
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      if (!mounted || _done) return;
      await controller.evaluateJavascript(source: _clickBookmarkScript);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted || _done) return;
      // 最后去书签页拿 Bookmarks 的 queryId。
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://x.com/i/bookmarks')),
      );
      return;
    }
    // 书签页加载完：给懒加载一点时间，然后收工。
    _stage = 2;
    await Future<void>.delayed(const Duration(seconds: 2));
    _finish();
  }

  @override
  Widget build(BuildContext context) {
    final tweetId = widget.tweetId;
    final startUrl = (tweetId ?? '').isNotEmpty
        ? 'https://x.com/i/status/$tweetId'
        : 'https://x.com/i/bookmarks';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.windowTitle ?? t('queryid.title')),
        actions: [
          IconButton(
            tooltip: t('queryid.retry'),
            onPressed: () {
              _done = false;
              _stage = 0;
              _learned.clear();
              setState(() {
                _loading = true;
                _error = null;
                _found = null;
              });
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(startUrl)),
            initialSettings: InAppWebViewSettings(
              isInspectable: false,
              thirdPartyCookiesEnabled: true,
              sharedCookiesEnabled: true,
            ),
            // X 的每个 GraphQL 调用都是 /graphql/{queryId}/{operation}，
            // 在这里顺手把映射记下来 —— 这就是「学习」到 queryId 的全部秘密。
            shouldInterceptRequest: (controller, request) async {
              final url = request.url.toString();
              final m = RegExp(r'/graphql/([A-Za-z0-9_-]{10,})/([A-Za-z0-9_]+)')
                  .firstMatch(url);
              if (m != null) {
                final op = m.group(2)!;
                if (widget.operations.contains(op)) {
                  _learned[op] = m.group(1)!;
                  final missing = widget.operations.any(
                    (o) => !_learned.containsKey(o),
                  );
                  if (!missing && !_done) _finish();
                }
              }
              // 返回 null = 不拦截，照常加载。
              return null;
            },
            onLoadStop: (controller, url) async {
              if (mounted && _loading) setState(() => _loading = false);
              await _onPageLoaded(controller);
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
                  child: Text(_error!, style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
          if (_found != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _found!.isEmpty
                            ? t('queryid.notFound')
                            : tf('queryid.found', {'n': _found!.length}),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      for (final e in _found!.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: SelectableText(
                            '${e.key} = ${e.value}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(t('action.cancel')),
                          ),
                          if (_found!.isNotEmpty)
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(context).pop(_found),
                              child: Text(t('action.confirm')),
                            ),
                        ],
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
