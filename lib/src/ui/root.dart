/// 根路由：启动态 → 登录页 / 主界面。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'x_action_host.dart';

class RootPage extends StatelessWidget {
  const RootPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final Widget body;
    if (app.booting) {
      body = Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(app.bootStage, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
    } else if (app.bootError != null) {
      body = _BootFailure(app: app);
    } else {
      body = app.loggedIn ? const HomePage() : const LoginPage();
    }
    // 写操作（喜欢/书签）要靠网页代发，宿主挂在最外层，能覆盖所有页面。
    return XActionHost(key: XActionHost.hostKey, child: body);
  }
}

/// 启动失败的详情页。
///
/// 以前这里只有一行「登录失败: xxx」，在手机上既看不全也复制不了 —— 排查完全靠猜。
/// 现在把「卡在哪一步」和完整异常都摆出来，并能一键复制设备信息。
class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(t('login.failed'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                app.bootError ?? '',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton(
                  onPressed: () => app.boot(),
                  child: Text(t('action.retry')),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: app.diagnostics()),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(t('error.copied'))));
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(t('error.copy')),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(t('error.hint'), style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
