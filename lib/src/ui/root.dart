/// 根路由：启动态 → 登录页 / 主界面。
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import 'home_page.dart';
import 'login_page.dart';

class RootPage extends StatelessWidget {
  const RootPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.booting) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (app.bootError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text('${t("login.failed")}: ${app.bootError}',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => app.boot(),
                  child: Text(t('action.retry')),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return app.loggedIn ? const HomePage() : const LoginPage();
  }
}
