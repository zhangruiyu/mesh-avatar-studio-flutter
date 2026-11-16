import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_avatar_studio/mesh_avatar_studio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('固定画布和动作的渲染对比采样', (tester) async {
    // Android / Darwin 的 CLOCKS_PER_SEC 都为 1000000，clock 统计整个进程的 CPU 时间。
    // CPU 百分比以一个核心为 100%，多线程合计可以超过 100%；不代表 GPU 时间。
    final cpuClock = DynamicLibrary.process()
        .lookupFunction<IntPtr Function(), int Function()>('clock');
    final controller = MeshAvatarController();
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MeshAvatarView(controller: controller))));
    await controller.loadAsset('assets/miko/miko-qipao.mavatar');
    await controller.setAutoMotion(false);
    await controller.setAutoIdle(true);
    await controller.setMouthDemo(true);
    await tester.pump(const Duration(seconds: 3));
    for (var round = 0; round < 3; round++) {
      await controller.playMotion(MeshAvatarMotion.sway);
      final start = await controller.getStats();
      final cpuStart = cpuClock();
      final clock = Stopwatch()..start();
      var peakRss = ProcessInfo.currentRss;
      while (clock.elapsedMilliseconds < 8000) {
        await tester.pump(const Duration(milliseconds: 200));
        final rss = ProcessInfo.currentRss;
        if (rss > peakRss) peakRss = rss;
      }
      final end = await controller.getStats();
      final cpuMs = (cpuClock() - cpuStart) / 1000;
      final wallMs = clock.elapsedMicroseconds / 1000;
      final frames = end.frames - start.frames;
      // 前后台切换可能让测试框架暂停，不能把那一轮当成性能改善。
      expect(wallMs, lessThan(12000), reason: '采样期间请保持应用在前台');
      expect(frames, greaterThan(0));
      expect(controller.lastError, isNull);
      debugPrint('MESH_BENCH ${jsonEncode({
            'label': const String.fromEnvironment('BENCH_LABEL',
                defaultValue: 'sample'),
            'os': Platform.operatingSystem, 'round': round + 1, 'width': 600,
            'height': 800,
            'wallMs': wallMs, 'frames': frames, 'fps': frames * 1000 / wallMs,
            'cpuPercent': cpuMs / wallMs * 100, 'peakRssMiB': peakRss / 1048576,
            // 旧链路包含同步 GPU 等待；新链路是提交耗时，需结合 CPU 和实际帧率判断。
            'nativeCallMs': (end.renderMilliseconds * end.frames -
                    start.renderMilliseconds * start.frames) /
                frames,
          })}');
    }
  });
}
