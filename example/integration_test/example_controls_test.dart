import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_avatar_studio/mesh_avatar_studio.dart';
import 'package:mesh_avatar_studio_example/main.dart' as demo;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('示例面板能展开并实际控制原生角色', (tester) async {
    demo.main();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('播放动作').evaluate().isNotEmpty) break;
    }
    // 列表项按需构建；等控件真正进入可点击区域后操作，避免只命中缓存区。
    Future<void> reveal(String label) async {
      for (var i = 0; i < 30; i++) {
        if (find.text(label).hitTestable().evaluate().isNotEmpty) return;
        await tester.drag(find.byType(ListView).first, const Offset(0, -180));
        await tester.pump(const Duration(milliseconds: 250));
      }
      fail('控件未进入可点击区域：$label');
    }

    final view = tester.widget<MeshAvatarView>(find.byType(MeshAvatarView));
    final controller = view.controller;
    expect(controller.isLoaded, true);
    expect(find.text('播放动作').hitTestable(), findsOneWidget);
    await controller.setAutoMotion(false);
    await tester.tap(find.text('播放动作'));
    await tester.pump(const Duration(milliseconds: 150));
    expect((await controller.getState()).motion, 'nod');
    await reveal('开心');
    await tester.tap(find.text('开心'));
    await tester.pump(const Duration(milliseconds: 150));
    expect((await controller.getState()).emotionExpression, 'happyTalk');
    await reveal('口型与无声演示');
    await tester.tap(find.text('口型与无声演示'));
    await tester.pump(const Duration(milliseconds: 300));
    await reveal('A');
    await tester.tap(find.text('A'));
    await tester.pump(const Duration(milliseconds: 150));
    expect((await controller.getState()).lipSyncActive, true);
    await reveal('配饰开关');
    await tester.tap(find.text('配饰开关'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('当前官方 Miko 模型没有独立配饰图层'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await controller.close();
  });
}
