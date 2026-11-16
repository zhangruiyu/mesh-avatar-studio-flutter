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

// 示例只演示公开接口。角色来自宿主指定路径，不把用户素材放进发布包。
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
  String status = '输入设备上的 .mavatar 路径，或用 AVATAR_PATH 指定。';
  Timer? timer;
  int previousFrames = 0;

  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    if (path.text.isNotEmpty) unawaited(load());
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
        await controller.loadFile(path.text);
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
                  decoration: const InputDecoration(labelText: '本地模型路径'),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: controller.isLoading ? null : load,
                      child: const Text('加载模型'),
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
                const Text('无声音演示 · 不使用 WebView',
                    style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      );
}
