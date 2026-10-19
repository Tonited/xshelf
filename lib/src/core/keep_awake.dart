/// 使用中不熄屏（Android 的 `FLAG_KEEP_SCREEN_ON`）。
///
/// 为什么不引第三方 wake lock 包：这个需求只需要一个原生 flag，走
/// MethodChannel 十几行就够，还少一个依赖和一套权限/后台限制问题。
///
/// 语义：**只在 App 前台可见时生效**。切后台或锁屏时这个 flag 对窗口不再有意
/// 义，系统该睡就睡；回到前台再打开。所以它不耗电，也不会阻止用户手动锁屏。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class KeepAwake {
  KeepAwake._();

  static const MethodChannel _channel = MethodChannel('app.xlikemanage/system');

  /// 上一次真正发出去的状态（避免每帧都跨平台调用）。
  static bool? _applied;

  /// [on] 为 null 时不动。
  static Future<void> set(bool? on) async {
    if (on == null) return;
    if (_applied == on) return;
    _applied = on;
    try {
      await _channel.invokeMethod<void>('keepScreenOn', on);
    } catch (e) {
      // 桌面端/旧平台没有这个通道：不影响其它功能。
      debugPrint('[keepAwake] $e');
    }
  }

  /// App 被回收/热重启后，原生窗口标志可能已经回到默认值。
  static void reset() => _applied = null;
}
