import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_avatar_studio/mesh_avatar_studio.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('插件注册、文件和字节加载、动作控制与释放恢复', (tester) async {
    const path = String.fromEnvironment('AVATAR_PATH');
    // 默认验证官方随包模型；仍可通过参数验证宿主自己的文件。
    const assetKey = 'assets/miko/miko-qipao.mavatar';
    final asset = await rootBundle.load(assetKey);
    final assetBytes =
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
    Directory? temp;
    var modelPath = path;
    if (path.isEmpty) {
      temp = await Directory.systemTemp.createTemp('mesh-avatar-test-');
      modelPath = '${temp.path}/miko-qipao.mavatar';
      await File(modelPath).writeAsBytes(assetBytes, flush: true);
    }
    final bytes = File(modelPath).readAsBytesSync();
    final controller = MeshAvatarController();
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      if (temp != null) await temp.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MeshAvatarView(controller: controller))));
    Future<void> framesAdvance() async {
      final before = (await controller.getStats()).frames;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(controller.lastError, isNull);
        if ((await controller.getStats()).frames > before + 2) return;
      }
      fail('原生纹理没有继续提交帧');
    }

    await controller.loadAsset(assetKey);
    await framesAdvance();
    await controller.loadFile(modelPath);
    await framesAdvance();
    expect(find.byType(Texture), findsOneWidget);
    for (final expression in MeshAvatarExpression.values) {
      await controller.setExpression(expression);
      await framesAdvance();
    }
    await controller.playMotion(MeshAvatarMotion.nod);
    await controller.setSpeaking(true);
    await controller.setVoiceLevel(0.8);
    await framesAdvance();
    expect((await controller.getStats()).speaking, true);
    await controller.setSpeaking(false);
    await controller.setMouthDemo(true);
    await framesAdvance();
    await controller.setMouthDemo(false);
    await controller.setPaused(true);
    await tester.pump(const Duration(milliseconds: 150));
    final frozen = (await controller.getStats()).frames;
    await tester.pump(const Duration(milliseconds: 300));
    expect((await controller.getStats()).frames, frozen);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 150));
    expect((await controller.getStats()).paused, true);
    await controller.setPaused(false);
    await framesAdvance();
    for (var i = 0; i < 3; i++) {
      await controller.loadBytes(bytes);
      await framesAdvance();
    }
    await expectLater(controller.loadFile('/missing-avatar.mavatar'),
        throwsA(isA<Exception>()));
    expect(controller.isLoaded, false);
    await controller.loadBytes(bytes);
    await framesAdvance();
    await controller.close();
    expect((await controller.getStats()).loaded, false);
    expect(tester.takeException(), isNull);
    debugPrint('插件真实原生集成测试通过：官方 asset 加载、自动注册、8 种表情、音量口型、3 次字节重载、暂停、失败恢复和释放。');
  });
}
