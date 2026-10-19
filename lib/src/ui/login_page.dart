/// 登录页：内嵌 WebView 登录（Android/iOS/Windows）+ 手动粘贴 cookie（全平台回退）。
///
/// 内嵌登录只从 cookie jar 里取 `auth_token` / `ct0`，等同于用户自己在浏览器里
/// 登录一次。支持「邮箱密码」和「通过 Google 继续」两条路：Google 会
/// `window.open` 一个弹窗，所以 WebView 必须开多窗口并把弹窗真的渲染出来。
///
/// 捕获**不依赖 URL**：X 的登录流程地址改过好几次（`/i/flow/login` →
/// `/i/jf/onboarding/web?mode=login`），而且 Google 登录是弹窗里 postMessage
/// 回来的，主页面未必会跳转。因此改为轮询 cookie jar —— 只要 `auth_token` +
/// `ct0` 出现就认为登录完成，这条路对两种登录方式都成立。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/browser_ua.dart';
import '../core/l10n.dart';
import '../sync/x_client.dart';
import '../version.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;
  /// Windows 也用 WebView2 内嵌登录：它的 UA 本来就是 Edge，没有 `wv` 标记，
  /// Google 对它的拦截比 Android WebView 宽松得多。
  final bool _webViewAvailable =
      Platform.isAndroid || Platform.isIOS || Platform.isWindows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(t('login.title'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              Text(t('login.hint'), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              // Google/Apple 第三方登录在 WebView 里一定会被拦（Google 的策略），
              // 与其让用户以为是 App 坏了，不如直接讲清楚并给出替代路径。
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(t('login.googleBlocked'),
                            style: theme.textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (_webViewAvailable)
                FilledButton.icon(
                  onPressed: _busy ? null : _openEmbeddedLogin,
                  icon: const Icon(Icons.login),
                  label: Text(t('login.withPassword')),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pasteCookie,
                icon: const Icon(Icons.content_paste),
                label: Text(t('login.paste')),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _importSession,
                icon: const Icon(Icons.move_to_inbox),
                label: Text(t('login.importSession')),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://x.com/i/flow/login'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_browser),
                label: Text(t('login.openInBrowser')),
              ),
              if (_busy) ...[
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                Center(child: Text(t('login.verifying'))),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openEmbeddedLogin() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _EmbeddedLoginPage(
        onSession: (s) => _finish(s),
      ),
    ));
  }

  /// 从剪贴板导入另一台设备导出的登录态（桌面端登录 → 手机直接用）。
  Future<void> _importSession() async {
    final app = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _error = t('login.importEmpty'));
        return;
      }
      final err = await app.importSession(text);
      if (err != null) setState(() => _error = '${t("login.failed")}: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteCookie() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('login.paste')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('login.cookieSteps'),
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 4,
                decoration:
                    const InputDecoration(hintText: 'auth_token=…; ct0=…'),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = data?.text;
                    if (text == null || text.isEmpty) return;
                    controller.text = text;
                  },
                  icon: const Icon(Icons.content_paste_go, size: 18),
                  label: Text(t('login.pasteFromClipboard')),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(t('action.confirm')),
          ),
        ],
      ),
    );
    if (raw == null || raw.trim().isEmpty) return;

    final parsed = parseCookieString(raw);
    if (parsed.authToken == null || parsed.ct0 == null) {
      setState(() => _error = t('login.missingCookies'));
      return;
    }
    await _finish(XSession(
      authToken: parsed.authToken!,
      ct0: parsed.ct0!,
      userId: parsed.userId ?? '',
    ));
  }

  Future<void> _finish(XSession session) async {
    final app = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verified = await app.verifySession(session);
      await app.signIn(verified);
    } on XRequestException catch (e) {
      setState(() => _error = '${t("login.failed")}: ${e.message}');
    } catch (e) {
      setState(() => _error = '${t("login.failed")}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 内嵌登录：用户在自己的 X 页面里登录，我们只从 cookie jar 里取两个 cookie。
class _EmbeddedLoginPage extends StatefulWidget {
  const _EmbeddedLoginPage({required this.onSession});

  final void Function(XSession) onSession;

  @override
  State<_EmbeddedLoginPage> createState() => _EmbeddedLoginPageState();
}

/// UA 的两种来源：抹掉本机 WebView 标记（默认）/ 伪装成桌面 Chrome。
enum _UaMode { cleaned, desktop }

class _EmbeddedLoginPageState extends State<_EmbeddedLoginPage> {
  /// null 表示还在向系统要默认 UA。
  String? _defaultUa;
  _UaMode _uaMode = _UaMode.cleaned;
  InAppWebViewController? _controller;
  bool _capturing = false;
  bool _failed = false;
  bool _done = false;

  /// cookie 轮询：登录完成与否只看「auth_token + ct0 是否出现」，
  /// 不依赖 URL（X 的登录页地址改过多次，Google 登录又是在弹窗里完成的）。
  Timer? _pollTimer;

  /// 诊断用：当前地址与最近一次主框架加载错误。白屏时靠它定位问题。
  String _currentUrl = '';
  String? _lastIssue;

  @override
  void initState() {
    super.initState();
    _resolveDefaultUa();
    // 1.5 秒一次足够快（登录成功到进入主页基本无感），又不至于把 WebView 的
    // cookie 查询压满。首次延迟 2 秒，给页面一点加载时间。
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_done && !_capturing) _tryCapture();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _resolveDefaultUa() async {
    var ua = '';
    try {
      ua = await InAppWebViewController.getDefaultUserAgent();
    } catch (_) {
      ua = '';
    }
    if (!mounted) return;
    setState(() => _defaultUa = ua);
  }

  String? get _userAgent {
    switch (_uaMode) {
      case _UaMode.desktop:
        return kDesktopChromeUserAgent;
      case _UaMode.cleaned:
        final d = _defaultUa ?? '';
        // 拿不到系统 UA 就不要覆盖，交给 WebView 自己决定
        if (d.isEmpty) return null;
        return cleanWebViewUserAgent(d);
    }
  }

  Future<void> _switchUaMode() async {
    setState(() {
      _uaMode = _uaMode == _UaMode.cleaned ? _UaMode.desktop : _UaMode.cleaned;
      _failed = false;
    });
    final c = _controller;
    if (c == null) return;
    try {
      await c.setSettings(
        settings: InAppWebViewSettings(userAgent: _userAgent),
      );
      await c.reload();
    } catch (_) {
      // 切换失败不影响原页面继续用
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ua = _defaultUa;
    final masked = _uaMode == _UaMode.cleaned;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('login.title')),
        actions: [
          if (_failed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  t('login.webviewRejected'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ),
          IconButton(
            tooltip: masked ? t('login.uaMasked') : t('login.uaNative'),
            onPressed: _switchUaMode,
            icon: Icon(masked ? Icons.masks : Icons.desktop_windows),
          ),
        ],
      ),
      body: ua == null
          ? const Center(child: CircularProgressIndicator())
          : InAppWebView(
              initialUrlRequest:
                  URLRequest(url: WebUri('https://x.com/i/flow/login')),
              initialSettings: InAppWebViewSettings(
                isInspectable: false,
                useShouldOverrideUrlLoading: false,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                // X 的「用 Google 登录」会 window.open 一个新窗口。默认
                // 不支持多窗口时，这个弹窗请求会被静默丢掉 —— 表现就是点了
                // 之后没反应、或者整页变白。
                supportMultipleWindows: true,
                userAgent: _userAgent,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onCreateWindow: (controller, action) async {
                if (action.request.url == null) return false;
                _openPopup(action.windowId);
                return true;
              },
              onLoadStart: (controller, url) {
                setState(() => _currentUrl = url?.toString() ?? '');
              },
              onReceivedError: (controller, request, error) {
                if (request.isForMainFrame != true) return;
                setState(() => _lastIssue =
                    '${error.type} ${error.description} (${request.url})');
              },
              onReceivedHttpError: (controller, request, response) {
                if (request.isForMainFrame != true) return;
                setState(() =>
                    _lastIssue = 'HTTP ${response.statusCode} (${request.url})');
              },
              onLoadStop: (controller, url) async {
                setState(() => _currentUrl = url?.toString() ?? '');
                // 主框架只要还在 X 域名下就尝试一次；真正的判定交给 cookie
                // （轮询是主路径，这里只是让成功捕获更快一点）。
                final u = url?.toString() ?? '';
                if (!u.contains('x.com')) return;
                await _tryCapture();
              },
            ),
      bottomNavigationBar: _diagBar(theme),
    );
  }

  /// 底部一条窄诊断栏：白屏时把当前地址复制出来，就能知道卡在哪一步。
  Widget _diagBar(ThemeData theme) {
    final url = _currentUrl;
    return SafeArea(
      top: false,
      child: Container(
        color: theme.colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_lastIssue != null)
                    Text(
                      _lastIssue!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  Text(
                    url.isEmpty ? '—' : url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: t('login.copyDiag'),
              onPressed:
                  url.isEmpty && _lastIssue == null ? null : _copyDiagnostics,
              icon: const Icon(Icons.copy_all, size: 18),
            ),
            IconButton(
              tooltip: t('login.openInBrowser'),
              onPressed:
                  url.isEmpty ? null : () => _openExternally(url),
              icon: const Icon(Icons.open_in_browser, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyDiagnostics() async {
    await Clipboard.setData(ClipboardData(
      text: 'v$kAppVersion | UA=${_uaMode.name} | url=$_currentUrl | '
          'issue=${_lastIssue ?? '-'}',
    ));
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t('error.copied'))));
    }
  }

  Future<void> _openExternally(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openPopup(int windowId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PopupWebViewPage(windowId: windowId),
    ));
  }

  Future<void> _tryCapture() async {
    if (_capturing || _done) return;
    _capturing = true;
    try {
      final cookies =
          await CookieManager.instance().getCookies(url: WebUri('https://x.com'));
      String? authToken;
      String? ct0;
      String? userId;
      for (final c in cookies) {
        switch (c.name) {
          case 'auth_token':
            authToken = c.value;
          case 'ct0':
            ct0 = c.value;
          case 'twid':
            final raw = Uri.decodeComponent(c.value ?? '');
            final m = RegExp(r'u=(\d+)').firstMatch(raw);
            userId = m?.group(1);
        }
      }
      // userId 不是必需的：拿不到 twid 时交给 verify_credentials 补全，
      // 否则用户明明登录成功了却被卡在这里。
      if (authToken == null || ct0 == null) {
        _capturing = false;
        return;
      }
      _done = true;
      final session = XSession(
        authToken: authToken,
        ct0: ct0,
        userId: userId ?? '',
      );
      // 把登录页和可能的 Google 登录弹窗一起关掉，回到外壳再切到已登录态。
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
      widget.onSession(session);
    } catch (_) {
      setState(() => _failed = true);
    } finally {
      _capturing = false;
    }
  }
}

/// X 的第三方登录会 `window.open` 一个新窗口。主 WebView 开了
/// `supportMultipleWindows` 之后必须真的把这个窗口渲染出来，否则请求虽然被
/// 接住却无处显示，用户看到的就是一片空白。
class _PopupWebViewPage extends StatelessWidget {
  const _PopupWebViewPage({required this.windowId});

  final int windowId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('login.popup')),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: InAppWebView(
        windowId: windowId,
        onCloseWindow: (controller) {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        },
      ),
    );
  }
}
