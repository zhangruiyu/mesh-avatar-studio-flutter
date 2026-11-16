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
    final metadata = await controller.getMetadata();
    expect(metadata.motions.map((m) => m.id).toSet(),
        MeshAvatarMotion.values.map((m) => m.name).toSet());
    expect(metadata.parameters.length, 25);
    final events = <String?>[];
    final subscription =
        controller.motionEvents.listen((event) => events.add(event.id));
    addTearDown(subscription.cancel);
    await controller.setAutoIdle(false);
    await controller.setAutoMotion(false);
    for (final motion in MeshAvatarMotion.values) {
      await controller.playMotion(motion);
      await framesAdvance();
      expect((await controller.getState()).motion, motion.name);
    }
    await tester.pump(const Duration(milliseconds: 120));
    expect(events.whereType<String>().toSet(),
        containsAll(MeshAvatarMotion.values.map((m) => m.name)));
    for (final emotion in MeshAvatarEmotion.values) {
      await controller.setEmotion(emotion, playMotion: false);
    }
    await controller.setEmotion(MeshAvatarEmotion.happy, playMotion: true);
    expect((await controller.getState()).emotionExpression, 'happyTalk');
    await controller.setParameters(
        {'angleX': 12, 'angleY': -6, 'gazeX': 0.6, 'gazeY': -0.5},
        weight: 0.75);
    await framesAdvance();
    var state = await controller.getState();
    expect(state.overrides,
        {'angleX': 12.0, 'angleY': -6.0, 'gazeX': 0.6, 'gazeY': -0.5});
    expect(state.weight, 0.75);
    await controller.clearParameters();
    expect((await controller.getState()).overrides, isEmpty);
    await controller.setLipSync(const MeshAvatarLipSyncSettings(
        granularity: 0.3, openness: 0.8, closeSpeed: 0.7));
    state = await controller.getState();
    expect(state.lipSync.openness, 0.8);
    for (final vowel in MeshAvatarVowel.values) {
      await controller.holdMouth(vowel);
      await framesAdvance();
      expect((await controller.getState()).lipSyncActive, true);
    }
    await controller.speakKana('こんにちは😊', speed: 8, loop: true);
    expect((await controller.getState()).lipSyncActive, true);
    await controller.setSpeaking(true);
    expect((await controller.getState()).lipSyncActive, false);
    await controller.holdMouth(MeshAvatarVowel.a);
    expect((await controller.getStats()).speaking, false);
    await controller.stopLipSync();
    expect((await controller.getState()).lipSyncActive, false);
    await controller.setTalkGain(1.4);
    await controller.setSwayGain(0.6);
    state = await controller.getState();
    expect(state.talkGain, 1.4);
    expect(state.swayGain, 0.6);
    expect(state.autoIdle, false);
    expect(state.autoMotion, false);
    await controller.setOverlays(metadata.overlays);
    expect((await controller.getState()).overlays.toSet(),
        metadata.overlays.toSet());
    await controller.setOverlays([]);
    await controller.setClothTuning({'follow': 0.4});
    await controller.setAutoIdle(true);
    await controller.setAutoMotion(true);
    await subscription.cancel();
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
    debugPrint('插件真实原生集成测试通过：21 动作、6 情绪、参数、元音/假名/音量模式切换、物理幅度、动作通知、加载和生命周期。');
  });
}
