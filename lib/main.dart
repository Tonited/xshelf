import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app_controller.dart';
import 'src/core/l10n.dart';
import 'src/ui/privacy_shield.dart';
import 'src/ui/root.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端的播放器后端（libmpv）在这里初始化；移动端用平台原生播放器。
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    MediaKit.ensureInitialized();
  }
  runApp(XLikeApp(controller: AppController()));
}

class XLikeApp extends StatefulWidget {
  const XLikeApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<XLikeApp> createState() => _XLikeAppState();
}

class _XLikeAppState extends State<XLikeApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.boot();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 语言变化要让整棵树重建（`t()` 是全局函数，不是 InheritedWidget，
    // 光靠 notifyListeners 只会重绘订阅了 AppScope 的 widget）。
    // 用 ListenableBuilder + 换 key 是最省事且不会漏改的方式；代价是切语言后
    // 回到主界面 —— 这个操作本来就很少做。
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final lang = widget.controller.effectiveLang;
        currentLang = lang;
        return MaterialApp(
          key: ValueKey('app-${lang.name}'),
          title: 'X Like Manage',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: ThemeMode.system,
          localizationsDelegates: const [
            DefaultMaterialLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
            DefaultCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => AppScope(
            controller: widget.controller,
            child: PrivacyShield(child: child!),
          ),
          home: const RootPage(),
        );
      },
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1D9BF0),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    cardTheme: CardThemeData(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(),
    ),
  );
}
