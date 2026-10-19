/// 通过一个临时 WebView 完成「加入/移除书签」。
///
/// 为什么需要它：X 对**写操作**（mutation）要求 `x-client-transaction-id`
/// 这个头是它自家 JS 签出来的有效签名。缺失或签错时，X 不返回 401/403，
/// 而是直接 **404 且响应体为空** —— 看起来像「queryId 失效」，其实 queryId
/// 是对的（网页用的就是同一个值）。纯 HTTP 补不了这个签名。
///
/// 而 WebView 里跑的是 X 自己的前端，它自带签名逻辑，所以在这里**模拟点一次
/// 书签按钮**就能成功。代价是要等页面加载、大约 3–6 秒，所以它只作为直连失败
/// 后的兜底。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/l10n.dart';

/// 用 WebView 把书签状态改成 [add]。
///
/// 返回 true 表示「点完之后状态确实变成了目标值」。失败或超时返回 false。
Future<bool> writeBookmarkViaWeb(
  BuildContext context, {
  required String tweetId,
  required bool add,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WebBookmarkDialog(tweetId: tweetId, add: add),
  );
  return result ?? false;
}

class _WebBookmarkDialog extends StatefulWidget {
  const _WebBookmarkDialog({required this.tweetId, required this.add});

  final String tweetId;
  final bool add;

  @override
  State<_WebBookmarkDialog> createState() => _WebBookmarkDialogState();
}

class _WebBookmarkDialogState extends State<_WebBookmarkDialog> {
  bool _loading = true;
  Timer? _timeout;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(const Duration(seconds: 25), () {
      if (_settled || !mounted) return;
      _settled = true;
      Navigator.of(context).pop(false);
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  /// 当前书签状态：`on` / `off` / `unknown`。
  static const String _stateScript = '''
(() => {
  const n = document.querySelector(
    '[data-testid="removeBookmark"], [data-testid="bookmark"]'
  );
  if (!n) return 'unknown';
  return n.getAttribute('data-testid') === 'removeBookmark' ? 'on' : 'off';
})();
''';

  /// 点一次书签按钮（选择器与实测一致：aria-label 里带「书签/bookmark」）。
  static const String _clickScript = '''
(() => {
  const nodes = Array.prototype.slice.call(
    document.querySelectorAll('button, [role="button"], [data-testid]')
  );
  const want = /bookmark|书签|收藏/i;
  for (const n of nodes) {
    const label = ((n.getAttribute('aria-label') || '') + ' ' +
                   (n.getAttribute('data-testid') || '')).trim();
    if (want.test(label)) {
      try { n.click(); return 'clicked:' + label; } catch (e) {}
    }
  }
  return 'no-button';
})();
''';

  Future<void> _drive(InAppWebViewController controller) async {
    if (_settled) return;
    // 等页面真正渲染出操作栏（XHR 回来之后才有按钮）。
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || _settled) return;
      final state = await controller.evaluateJavascript(source: _stateScript);
      final s = '$state';
      if (s == 'unknown') continue;
      final already = s == 'on';
      if (already == widget.add) {
        // 已经是目标状态，不需要点。
        _settled = true;
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      final clicked = await controller.evaluateJavascript(source: _clickScript);
      // ignore: avoid_print
      print('[bookmark-web] click=$clicked');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted || _settled) return;
      final after =
          '${await controller.evaluateJavascript(source: _stateScript)}';
      _settled = true;
      if (mounted) {
        Navigator.of(context).pop(after == (widget.add ? 'on' : 'off'));
      }
      return;
    }
    _settled = true;
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 320,
        height: 360,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.add
                          ? t('play.bookmarkSyncing')
                          : t('play.bookmarkSyncingOff'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ClipRect(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(
                    url: WebUri('https://x.com/i/status/${widget.tweetId}'),
                  ),
                  initialSettings: InAppWebViewSettings(
                    isInspectable: false,
                    thirdPartyCookiesEnabled: true,
                    sharedCookiesEnabled: true,
                    transparentBackground: true,
                  ),
                  onLoadStop: (controller, url) async {
                    if (mounted) setState(() => _loading = false);
                    await _drive(controller);
                  },
                ),
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }
}
