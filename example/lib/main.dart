import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mesh_avatar_studio/mesh_avatar_studio.dart';

void main() => runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const AvatarExample(),
      ),
    );

// 官方 Miko 仅作为示例 App 的本地资源，业务应用依赖插件时不会自动打包它。
class AvatarExample extends StatefulWidget {
  const AvatarExample({super.key});
  @override
  State<AvatarExample> createState() => _AvatarExampleState();
}

class _AvatarExampleState extends State<AvatarExample> {
  final controller = MeshAvatarController();
  final path = TextEditingController(
    text: const String.fromEnvironment('AVATAR_PATH'),
  );
  bool mouthDemo = false;
  String status = '正在加载官方 Miko 示例…';
  Timer? timer;
  int previousFrames = 0;

  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    unawaited(load());
    timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!controller.isLoaded || controller.isLoading) return;
      try {
        final stats = await controller.getStats();
        if (!mounted) return;
        setState(() {
          final fps = (stats.frames - previousFrames).clamp(0, 999);
          status =
              '$fps 帧/秒 · ${stats.renderMilliseconds.toStringAsFixed(1)} ms · 原生纹理';
          previousFrames = stats.frames;
        });
      } catch (e) {
        if (mounted) setState(() => status = '$e');
      }
    });
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  Future<void> load() => run(() async {
        final selectedPath = path.text.trim();
        if (selectedPath.isEmpty) {
          await controller.loadAsset('assets/miko/miko-qipao.mavatar');
        } else {
          await controller.loadFile(selectedPath);
        }
        mouthDemo = false;
        previousFrames = 0;
      });
  @override
  void dispose() {
    timer?.cancel();
    controller.removeListener(refresh);
    controller.dispose();
    path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Mesh Avatar Studio')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MeshAvatarView(controller: controller),
                      if (controller.lastError != null)
                        Center(child: Text('${controller.lastError}')),
                      if (controller.isLoading)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
                TextField(
                  controller: path,
                  decoration: const InputDecoration(
                    labelText: '自定义模型路径（可选）',
                    hintText: '留空使用官方 Miko 示例',
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: controller.isLoading ? null : load,
                      child: const Text('加载角色'),
                    ),
                    for (final item in [
                      (MeshAvatarExpression.neutral, '自然'),
                      (MeshAvatarExpression.smile, '放松'),
                      (MeshAvatarExpression.shy, '害羞'),
                      (MeshAvatarExpression.wink, '眨单眼'),
                    ])
                      TextButton(
                        onPressed: !controller.isLoaded
                            ? null
                            : () =>
                                run(() => controller.setExpression(item.$1)),
                        child: Text(item.$2),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: !controller.isLoaded
                          ? null
                          : () => run(
                                () =>
                                    controller.playMotion(MeshAvatarMotion.nod),
                              ),
                      child: const Text('点头'),
                    ),
                    TextButton(
                      onPressed: !controller.isLoaded
                          ? null
                          : () => run(() async {
                                await controller.setMouthDemo(!mouthDemo);
                                setState(() => mouthDemo = !mouthDemo);
                              }),
                      child: Text(mouthDemo ? '停止口型' : '口型演示'),
                    ),
                    TextButton(
                      onPressed: !controller.isLoaded
                          ? null
                          : () => run(
                                () =>
                                    controller.setPaused(!controller.isPaused),
                              ),
                      child: Text(controller.isPaused ? '继续动作' : '暂停动作'),
                    ),
                  ],
                ),
                Text(status),
                const Text('Miko © Yuki Shindo (AITuber OnAir)',
                    style: TextStyle(fontSize: 11)),
                const Text('无声音演示 · 不使用 WebView',
                    style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      );
}
