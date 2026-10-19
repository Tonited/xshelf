/// 真机冒烟测试：跑在真设备上（`flutter test integration_test -d <id>`）。
///
/// 存在的意义：手工点坐标验证太容易点偏（心形按钮偏 10px 就落到视频上了），
/// 这里用 widget finder 定位，能可靠地验证「列表 → 播放页 → 返回」这条高频路径，
/// 以及「点心形之后图标**立刻**翻转」（乐观更新，不等网络）。
///
/// ## 设备上需要有登录态
/// `flutter test integration_test` 装的是 **debug** 包，和 release 包的签名不同，
/// 安装后 App 数据会被重置 —— 会停在登录页。没有登录态时这些用例会 `skip`
/// （而不是红），所以先手动登录一次再跑，或者干脆把它们当成 CI 之外的手工清单。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xlikemanage/src/ui/post_card.dart';
import 'package:xlikemanage/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 等首页出现至少一张卡片（启动要迁移数据库 + 拉第一页）。
  Future<void> waitForCards(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byType(PostCard).evaluate().isNotEmpty) return;
    }
  }

  /// 屏幕上现有的文字（诊断用：一眼看出停在启动页、登录页还是空列表）。
  List<String> screenTexts() => find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .take(8)
      .toList();

  testWidgets('列表 → 播放页 → 返回', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await waitForCards(tester);
    if (find.byType(PostCard).evaluate().isEmpty) {
      markTestSkipped('首页没有卡片（多半停在登录页）：${screenTexts()}');
      return;
    }

    await tester.tap(find.byType(PostCard).first);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(
      find.byIcon(Icons.arrow_back_ios_new),
      findsWidgets,
      reason: '点卡片应该进入播放页',
    );

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new).first);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.byType(PostCard), findsWidgets, reason: '返回后列表应该还在');
  });

  testWidgets('点心形：图标立刻翻转（不等网络）', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await waitForCards(tester);
    if (find.byType(PostCard).evaluate().isEmpty) {
      markTestSkipped('首页没有卡片（多半停在登录页）：${screenTexts()}');
      return;
    }

    await tester.tap(find.byType(PostCard).first);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final wasLiked = find.byIcon(Icons.favorite).evaluate().isNotEmpty;
    final start = wasLiked
        ? find.byIcon(Icons.favorite)
        : find.byIcon(Icons.favorite_border);
    if (start.evaluate().isEmpty) {
      markTestSkipped('当前条目没有心形按钮');
      return;
    }

    await tester.tap(start.first);
    // 只等一帧：乐观更新必须**立刻**生效，不能等网络。
    await tester.pump(const Duration(milliseconds: 100));

    final flipped = wasLiked
        ? find.byIcon(Icons.favorite_border).evaluate().isNotEmpty
        : find.byIcon(Icons.favorite).evaluate().isNotEmpty;
    expect(flipped, isTrue, reason: '点击后图标应该立刻翻转（乐观更新）');

    // 点回来，别在账号上留下净变化。
    final back = wasLiked
        ? find.byIcon(Icons.favorite_border)
        : find.byIcon(Icons.favorite);
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back.first);
      await tester.pump(const Duration(seconds: 4));
    }
  });
}
