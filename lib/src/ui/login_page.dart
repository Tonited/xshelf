/// 登录页：内嵌 WebView 登录（Android/iOS）+ 手动粘贴 cookie（全平台回退）。
///
/// 桌面端不提供内嵌登录：X 对嵌入式浏览器登录的限制更多，而且 Windows 侧的
/// WebView2 登录态抓取尚未验证；桌面用户改用「浏览器登录 + 粘贴 cookie」。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../sync/x_client.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;
  final bool _webViewAvailable = Platform.isAndroid || Platform.isIOS;

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
              const SizedBox(height: 24),
              if (_webViewAvailable)
                FilledButton.icon(
                  onPressed: _busy ? null : _openEmbeddedLogin,
                  icon: const Icon(Icons.login),
                  label: Text(t('login.title')),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pasteCookie,
                icon: const Icon(Icons.content_paste),
                label: Text(t('login.paste')),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://x.com/i/flow/login'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_browser),
                label: Text(t('login.pasteHelp')),
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

  Future<void> _pasteCookie() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('login.paste')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('login.pasteField'),
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 4,
              decoration: const InputDecoration(hintText: 'auth_token=…; ct0=…'),
            ),
          ],
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

class _EmbeddedLoginPageState extends State<_EmbeddedLoginPage> {
  bool _capturing = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('login.title')),
        actions: [
          if (_failed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  t('login.webviewRejected'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest:
            URLRequest(url: WebUri('https://x.com/i/flow/login')),
        initialSettings: InAppWebViewSettings(
          isInspectable: false,
          useShouldOverrideUrlLoading: false,
          thirdPartyCookiesEnabled: true,
          sharedCookiesEnabled: true,
          userAgent:
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
        ),
        onLoadStop: (controller, url) async {
          final u = url?.toString() ?? '';
          if (!u.contains('x.com')) return;
          // 登录成功后 X 会跳到 /home 或 /i/flow/... 完成页
          if (!u.contains('/home') && !u.contains('/i/flow/')) return;
          await _tryCapture();
        },
      ),
    );
  }

  Future<void> _tryCapture() async {
    if (_capturing) return;
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
      final session = XSession(
        authToken: authToken,
        ct0: ct0,
        userId: userId ?? '',
      );
      if (mounted) Navigator.of(context).pop();
      widget.onSession(session);
    } catch (_) {
      setState(() => _failed = true);
    } finally {
      _capturing = false;
    }
  }
}
