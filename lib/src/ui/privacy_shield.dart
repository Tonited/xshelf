/// 应用没在「完全激活」状态时，把内容整个盖住。
///
/// 触发时机就是 [AppLifecycleState] 那几个状态：
/// - 切到后台 / 锁屏（`paused` / `hidden`）；
/// - 下拉通知栏、进「最近任务」（`inactive`）；
/// - 来电、系统弹窗抢焦点（`inactive`）。
///
/// 为什么不用 Android 的 `FLAG_SECURE`：那会连带**禁止用户自己截图**，
/// 也会让系统截图全黑 —— 用户有时候就是要截一张。蒙版只遮界面内容，
/// 截图、投屏都还能用，但「不小心被人看到」的场景都挡住了。
///
/// 蒙版放在 `MaterialApp.builder` 里，所以它在 Navigator **之上**：
/// 弹窗、底部面板、播放页全都会被盖住，不会有漏网的一角。
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/keep_awake.dart';
import '../core/l10n.dart';

class PrivacyShield extends StatefulWidget {
  const PrivacyShield({super.key, required this.child});

  final Widget child;

  @override
  State<PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<PrivacyShield>
    with WidgetsBindingObserver {
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 冷启动第一帧就把「不熄屏」对齐到设置值。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncKeepAwake());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 「使用中不熄屏」：前台按设置值打开，其余状态一律关掉。
  void _syncKeepAwake() {
    if (!mounted) return;
    final app = AppScope.maybeRead(context);
    final on = !_covered && (app?.settings.keepAwake ?? false);
    KeepAwake.set(on);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final covered = state != AppLifecycleState.resumed;
    if (covered == _covered) {
      _syncKeepAwake();
      return;
    }
    setState(() => _covered = covered);
    _syncKeepAwake();
    // 盖住的那一刻立刻要一帧：不然系统截「最近任务」缩略图时可能还是旧画面。
    if (covered) WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    // 设置在任意页面被改动时，这里也会跟着重建（AppScope 是 InheritedNotifier），
    // 顺手把窗口标志对齐。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncKeepAwake());
    return Stack(
      children: [
        widget.child,
        if (_covered) const Positioned.fill(child: _Cover()),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 盖在最上层，必须吃掉所有点击：不能让「回到前台前的一下误触」点进内容。
    return Material(
      color: const Color(0xFF0E1621),
      child: AbsorbPointer(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 和应用图标同一个标：白色 X + 蓝色那一臂。
              SizedBox(
                width: 64,
                height: 64,
                child: CustomPaint(painter: _MarkPainter()),
              ),
              const SizedBox(height: 18),
              Icon(
                Icons.lock_outline,
                size: 18,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 8),
              Text(
                t('privacy.covered'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 画一个和应用图标一致的 X 标（白色两笔 + 左下蓝色一臂）。
class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 108.0;
    Path quad(List<List<double>> pts) {
      final p = Path();
      p.moveTo(pts[0][0] * k, pts[0][1] * k);
      for (final pt in pts.skip(1)) {
        p.lineTo(pt[0] * k, pt[1] * k);
      }
      p.close();
      return p;
    }

    final paint = Paint()..isAntiAlias = true;
    // "\" 与 "/"（白色）
    paint.color = const Color(0xFFF7FAFC);
    canvas.drawPath(
      quad([
        [32.6, 38.7],
        [66.6, 78.7],
        [75.4, 71.3],
        [41.4, 31.3],
      ]),
      paint,
    );
    canvas.drawPath(
      quad([
        [66.6, 31.3],
        [32.6, 71.3],
        [41.4, 78.7],
        [75.4, 38.7],
      ]),
      paint,
    );
    // "/" 的左下臂（蓝色强调）
    paint.color = const Color(0xFF6CC7F5);
    canvas.drawPath(
      quad([
        [44.8, 57.0],
        [32.6, 71.3],
        [41.4, 78.7],
        [59.9, 57.0],
      ]),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
