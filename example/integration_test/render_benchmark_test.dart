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
    // Android / Darwin / 鸿蒙的 CLOCKS_PER_SEC 都为 1000000，clock 统计进程 CPU 时间。
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
    // 同一测试可做短回归或长对照；只延长采样，不修改画布、帧率和动作计算。
    const warmupSeconds =
        int.fromEnvironment('BENCH_WARMUP_SECONDS', defaultValue: 3);
    const seconds = int.fromEnvironment('BENCH_SECONDS', defaultValue: 8);
    const rounds = int.fromEnvironment('BENCH_ROUNDS', defaultValue: 3);
    expect(seconds, greaterThan(0));
    expect(rounds, greaterThan(0));
    await tester.pump(const Duration(seconds: warmupSeconds));
    for (var round = 0; round < rounds; round++) {
      await controller.playMotion(MeshAvatarMotion.sway);
      final start = await controller.getStats();
      final cpuStart = cpuClock();
      final clock = Stopwatch()..start();
      var peakRss = ProcessInfo.currentRss;
      while (clock.elapsedMilliseconds < seconds * 1000) {
        await tester.pump(const Duration(milliseconds: 200));
        final rss = ProcessInfo.currentRss;
        if (rss > peakRss) peakRss = rss;
      }
      final end = await controller.getStats();
      final cpuMs = (cpuClock() - cpuStart) / 1000;
      final wallMs = clock.elapsedMicroseconds / 1000;
      final frames = end.frames - start.frames;
      // 前后台切换可能让测试框架暂停，不能把那一轮当成性能改善。
      expect(wallMs, lessThan(seconds * 1000 + 4000), reason: '采样期间请保持应用在前台');
      expect(frames, greaterThan(0));
      expect(controller.lastError, isNull);
      debugPrint('MESH_BENCH ${jsonEncode({
            'label': const String.fromEnvironment('BENCH_LABEL',
                defaultValue: 'sample'),
            'os': Platform.operatingSystem, 'round': round + 1, 'width': 600,
            'height': 800,
            'wallMs': wallMs, 'frames': frames, 'fps': frames * 1000 / wallMs,
            'cpuPercent': cpuMs / wallMs * 100, 'peakRssMiB': peakRss / 1048576,
            'endRssMiB': ProcessInfo.currentRss / 1048576,
            // 旧链路包含同步 GPU 等待；新链路是提交耗时，需结合 CPU 和实际帧率判断。
            // 旧鸿蒙返回单帧耗时，比较旧版时传 false，不能使用累计平均的差分公式。
            'nativeCallMs': const bool.fromEnvironment('BENCH_STATS_CUMULATIVE',
                    defaultValue: true)
                ? (end.renderMilliseconds * end.frames -
                        start.renderMilliseconds * start.frames) /
                    frames
                : null,
          })}');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
