/// 从 X 自己的前端 JS 里现场抓 GraphQL queryId。
///
/// 为什么需要这个页面：`Bookmarks` / `CreateBookmark` / `DeleteBookmark` 的定义
/// 不在顶层 bundle 里，而在按路由懒加载的 chunk 中，而且 X 会定期轮换。
/// 纯 HTTP 抓 x.com 会被 Cloudflare 403 拦掉，但 **WebView 有真实浏览器指纹和
/// 登录态**，能正常加载那些 chunk —— 于是用 WebView 当「探针」：
///
/// 1. 打开 `/i/bookmarks`（触发书签相关 chunk 加载）；
/// 2. 用 `performance.getEntriesByType('resource')` 列出已加载的 JS；
/// 3. 逐个 fetch 回文本，正则找 `operationName:"X"` 附近的 `queryId:"…"`；
/// 4. 把结果带回给设置页落库。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/l10n.dart';

class QueryIdProbePage extends StatefulWidget {
  const QueryIdProbePage({super.key, required this.operations});

  /// 要抓的操作名，例如 `Bookmarks`。
  final List<String> operations;

  @override
  State<QueryIdProbePage> createState() => _QueryIdProbePageState();
}

class _QueryIdProbePageState extends State<QueryIdProbePage> {
  bool _loading = true;
  String? _error;
  Timer? _timeout;
  bool _done = false;

  /// 抓到的结果：显示出来让用户看清抓到了什么，再决定要不要保存。
  Map<String, String>? _found;

  @override
  void initState() {
    super.initState();
    // 页面加载完再给 20 秒让懒加载 chunk 都跑起来。
    _timeout = Timer(const Duration(seconds: 45), () {
      if (_done || !mounted) return;
      setState(() => _error = t('queryid.timeout'));
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  /// 在页面上下文里执行的抓取脚本。
  ///
  /// 两个方向的正则都试：有的 chunk 是 `queryId` 在前，有的是 `operationName` 在前。
  /// 只取 URL 列表，**不在页面里 fetch**。
  ///
  /// 为什么：chunk 在 `abs.twimg.com`，页面里 `fetch` 它属于跨域，CORS 会直接
  /// 拒绝（这正是第一版抓不到的原因）。`performance` API 不受同源限制，所以
  /// 拿 URL 出来、由 Dart 侧再请求，就绕开了 CORS。
  String _script() {
    return '''
JSON.stringify(
  performance.getEntriesByType('resource')
    .map(e => e.name)
    .filter(n => n.indexOf('.js') !== -1)
    .slice(0, 60)
);
''';
  }

  static final RegExp _opFirst = RegExp(
    r'operationName:"(\w+)"[^}]{0,600}?queryId:"([A-Za-z0-9_-]{10,})"',
  );
  static final RegExp _idFirst = RegExp(
    r'queryId:"([A-Za-z0-9_-]{10,})"[^}]{0,600}?operationName:"(\w+)"',
  );

  /// 依次下载 chunk 并扫描。找到全部目标就提前收手（单个 bundle 可能有几 MB）。
  Future<Map<String, String>> _scan(List<String> urls) async {
    final found = <String, String>{};
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      for (final url in urls) {
        if (widget.operations.every(found.containsKey)) break;
        try {
          final req = await httpClient.getUrl(Uri.parse(url));
          final resp = await req.close().timeout(const Duration(seconds: 15));
          if (resp.statusCode != 200) continue;
          final body = await resp
              .transform(const Utf8Decoder(allowMalformed: true))
              .join()
              .timeout(const Duration(seconds: 20));
          for (final m in _opFirst.allMatches(body)) {
            final op = m.group(1)!;
            if (widget.operations.contains(op)) {
              found.putIfAbsent(op, () => m.group(2)!);
            }
          }
          for (final m in _idFirst.allMatches(body)) {
            final op = m.group(2)!;
            if (widget.operations.contains(op)) {
              found.putIfAbsent(op, () => m.group(1)!);
            }
          }
        } catch (_) {
          // 单个 chunk 失败不影响其它。
        }
      }
    } finally {
      httpClient.close(force: true);
    }
    return found;
  }

  Future<void> _probe(InAppWebViewController controller) async {
    if (_done) return;
    try {
      // 让懒加载先跑一会儿：页面刚 load 完时 chunk 可能还没下载。
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!mounted || _done) return;
      final raw = await controller.evaluateJavascript(source: _script());
      if (!mounted || _done) return;
      final text = raw is String ? raw : '$raw';
      var urls = const <String>[];
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) urls = decoded.whereType<String>().toList();
      } catch (_) {
        // 拿不到 URL 列表：当成没抓到。
      }
      final found = urls.isEmpty ? const <String, String>{} : await _scan(urls);
      _done = true;
      _timeout?.cancel();
      if (!mounted) return;
      setState(() => _found = found);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('queryid.title')),
        actions: [
          IconButton(
            tooltip: t('queryid.retry'),
            onPressed: () {
              _done = false;
              setState(() {
                _loading = true;
                _error = null;
              });
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('https://x.com/i/bookmarks'),
            ),
            initialSettings: InAppWebViewSettings(
              isInspectable: false,
              thirdPartyCookiesEnabled: true,
              sharedCookiesEnabled: true,
            ),
            onLoadStop: (controller, url) async {
              if (mounted) setState(() => _loading = false);
              await _probe(controller);
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
