import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mesh_avatar_studio/mesh_avatar_studio.dart';

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const AvatarExample(),
    ));

// 只调节运行效果，不编辑或保存模型。官方 Miko 仅在 example 内随包。
class AvatarExample extends StatefulWidget {
  const AvatarExample({super.key});
  @override
  State<AvatarExample> createState() => _AvatarExampleState();
}

class _AvatarExampleState extends State<AvatarExample> {
  final controller = MeshAvatarController();
  final path =
      TextEditingController(text: const String.fromEnvironment('AVATAR_PATH'));
  final kana = TextEditingController(text: 'こんにちは、ありがとう');
  final overrides = <String, double>{};
  final selectedOverlays = <String>{};
  final sliders = <String, double>{};
  MeshAvatarMetadata? metadata;
  bool autoIdle = true, autoMotion = true, emotionMotion = true;
  bool mouthDemo = false, speaking = false, kanaLoop = false;
  double weight = 1;
  String motion = 'nod', motionStatus = '等待动作通知', status = '正在加载官方 Miko…';
  String? error;
  Timer? timer;
  StreamSubscription<MeshAvatarMotionEvent>? motionSubscription;
  int previousFrames = 0;
  bool polling = false;

  static const motionLabels = {
    'nod': '点头',
    'no': '摇头',
    'sway': '轻摆',
    'greet': '打招呼',
    'tilt': '歪头',
    'think': '思考',
    'giggle': '轻笑',
    'surprise': '惊讶',
    'shy': '害羞',
    'wink': '眨单眼',
    'lookAround': '环顾',
    'glance': '侧看',
    'sigh': '叹气',
    'doze': '打瞌睡',
    'stretch': '伸展',
    'lean': '倾身',
    'hum': '哼唱',
    'tap': '轻敲',
    'readNote': '看笔记',
    'waiting': '等待',
    'spaceOut': '发呆',
  };
  static const parameterLabels = {
    'angleX': '头部左右',
    'angleY': '头部上下',
    'angleZ': '头部倾斜',
    'bodyAngleX': '身体左右',
    'bodyAngleZ': '身体倾斜',
    'breath': '呼吸',
    'eyeLOpen': '左眼开合',
    'eyeROpen': '右眼开合',
    'eyeSmile': '双眼笑意',
    'eyeSmileL': '左眼笑意',
    'gazeX': '眼神左右',
    'gazeY': '眼神上下',
    'browY': '眉毛高低',
    'browAngle': '眉毛角度',
    'mouthOpen': '张口大小',
    'mouthForm': '嘴形（i → o）',
    'blush': '脸红',
    'armAngle': '手臂角度',
    'handAngle': '手腕角度',
    'fingerTap': '手指轻敲',
    'weightShift': '重心',
    'armSwingL': '左臂摆动',
    'armSwingR': '右臂摆动',
    'elbowBendL': '左肘弯曲',
    'elbowBendR': '右肘弯曲',
  };
  static const groups = {
    'Head and body': '头部与身体',
    'Eyes and brows': '眼神与眉毛',
    'Mouth and cheeks': '嘴形与脸颊',
    'Hand': '手部',
    'Legs': '重心',
    'Arms': '双臂',
  };

  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    motionSubscription = controller.motionEvents.listen((event) {
      if (mounted) {
        setState(() => motionStatus = event.id == null
            ? '动作结束'
            : '正在：${motionLabels[event.id] ?? event.id}');
      }
    }, onError: (Object e) {
      if (mounted) setState(() => error = '$e');
    });
    unawaited(load());
    timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (polling || !controller.isLoaded || controller.isLoading) return;
      polling = true;
      try {
        final stats = await controller.getStats();
        if (!mounted) return;
        setState(() {
          status =
              '${(stats.frames - previousFrames).clamp(0, 999)} 帧/秒 · ${stats.renderMilliseconds.toStringAsFixed(1)} ms';
          previousFrames = stats.frames;
        });
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      } finally {
        polling = false;
      }
    });
  }

  void refresh() {
    if (mounted) {
      setState(() {
        if (controller.lastError != null) error = '${controller.lastError}';
      });
    }
  }

  Future<void> run(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> load() => run(() async {
        setState(() => metadata = null);
        if (path.text.trim().isEmpty) {
          await controller.loadAsset('assets/miko/miko-qipao.mavatar');
        } else {
          await controller.loadFile(path.text.trim());
        }
        final info = await controller.getMetadata();
        final state = await controller.getState();
        if (!mounted) return;
        setState(() {
          metadata = info;
          overrides.clear();
          sliders.clear();
          selectedOverlays.clear();
          autoIdle = state.autoIdle;
          autoMotion = state.autoMotion;
          sliders.addAll({
            'talkGain': state.talkGain,
            'swayGain': state.swayGain,
            'granularity': state.lipSync.granularity!,
            'openness': state.lipSync.openness!,
            'closeSpeed': state.lipSync.closeSpeed!
          });
          for (final garment in state.clothTuning.entries) {
            for (final field in garment.value.entries) {
              sliders['cloth-${garment.key}-${field.key}'] = field.value;
            }
          }
          mouthDemo = false;
          speaking = false;
          previousFrames = 0;
          weight = 1;
        });
      });
  @override
  void dispose() {
    timer?.cancel();
    unawaited(motionSubscription?.cancel());
    controller.removeListener(refresh);
    controller.dispose();
    path.dispose();
    kana.dispose();
    super.dispose();
  }

  // 拖动时更新显示，松手后提交一次，避免慢设备排队执行过时的滑块值。
  Widget slider(String id, String label, double min, double max,
      double fallback, Future<void> Function(double) apply,
      {int? divisions}) {
    final value = (sliders[id] ?? fallback).clamp(min, max).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$label  ${value.toStringAsFixed(2)}'),
      Slider(
          key: ValueKey('slider-$id'),
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) => setState(() => sliders[id] = v),
          onChangeEnd: (v) => run(() => apply(v))),
    ]);
  }

  Widget section(String title, List<Widget> children,
          {bool expanded = false}) =>
      ExpansionTile(
          key: PageStorageKey('runtime-$title'),
          title: Text(title),
          initiallyExpanded: expanded,
          childrenPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: children);
  Widget buttons<T>(Iterable<T> items, String Function(T) label,
          Future<void> Function(T) apply) =>
      Wrap(spacing: 6, runSpacing: 4, children: [
        for (final item in items)
          OutlinedButton(
              onPressed: () => run(() => apply(item)), child: Text(label(item)))
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('角色运行体验'), actions: [
          IconButton(
              tooltip: '重新加载',
              onPressed: controller.isLoading ? null : load,
              icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: controller.isPaused ? '继续动作' : '暂停动作',
              onPressed: !controller.isLoaded
                  ? null
                  : () => run(() => controller.setPaused(!controller.isPaused)),
              icon: Icon(controller.isPaused ? Icons.play_arrow : Icons.pause)),
        ]),
        body: SafeArea(
            child: Column(children: [
          Expanded(
              flex: 5,
              child: Stack(fit: StackFit.expand, children: [
                MeshAvatarView(controller: controller),
                if (controller.isLoading)
                  const Center(child: CircularProgressIndicator()),
                Positioned(
                    left: 12,
                    bottom: 6,
                    child: Text('$status\n$motionStatus',
                        style: const TextStyle(fontSize: 12))),
              ])),
          if (error != null)
            Padding(
                padding: const EdgeInsets.all(8),
                child: Text(error!,
                    maxLines: 3,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const Divider(height: 1),
          Expanded(
              flex: 5,
              child: ListView(children: [
                if (metadata != null) ...[
                  section(
                      '动作与情绪',
                      [
                        DropdownButtonFormField<String>(
                            initialValue: motion,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '完整动作列表'),
                            items: [
                              for (final m in metadata!.motions)
                                DropdownMenuItem(
                                    value: m.id,
                                    child: Text(
                                        '${motionLabels[m.id] ?? m.label} · ${m.duration.toStringAsFixed(1)} 秒'))
                            ],
                            onChanged: (id) {
                              if (id != null) setState(() => motion = id);
                            }),
                        FilledButton(
                            onPressed: () =>
                                run(() => controller.playMotionById(motion)),
                            child: const Text('播放动作')),
                        SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('情绪同时带动动作'),
                            value: emotionMotion,
                            onChanged: (v) =>
                                setState(() => emotionMotion = v)),
                        buttons(
                            MeshAvatarEmotion.values,
                            (e) => const [
                                  '自然',
                                  '开心',
                                  '难过',
                                  '生气',
                                  '惊讶',
                                  '放松'
                                ][e.index],
                            (e) => controller.setEmotion(e,
                                playMotion: emotionMotion)),
                        const SizedBox(height: 12),
                        const Text('素材表情（与情绪独立）'),
                        buttons(
                            MeshAvatarExpression.values,
                            (e) => const [
                                  '自然',
                                  '微笑',
                                  '害羞',
                                  '惊讶',
                                  '半闭眼',
                                  '生气',
                                  '难过',
                                  '眨单眼'
                                ][e.index],
                            controller.setExpression),
                      ],
                      expanded: true),
                  section('自动待机与动作幅度', [
                    SwitchListTile(
                        title: const Text('自动呼吸 / 眨眼 / 视线'),
                        value: autoIdle,
                        onChanged: (v) => run(() async {
                              await controller.setAutoIdle(v);
                              setState(() => autoIdle = v);
                            })),
                    SwitchListTile(
                        title: const Text('自动挑选动作'),
                        subtitle: const Text('关闭后，当前动作仍会播完'),
                        value: autoMotion,
                        onChanged: (v) => run(() async {
                              await controller.setAutoMotion(v);
                              setState(() => autoMotion = v);
                            })),
                    slider(
                        'talkGain', '说话身体幅度', 0, 3, 1, controller.setTalkGain),
                    slider('swayGain', '头发 / 配饰摆动幅度', 0, 3, 1,
                        controller.setSwayGain),
                  ]),
                  section('口型与无声演示', [
                    const Text('固定元音 / 假名 / 音量驱动互斥；这里不播放声音。'),
                    buttons(
                        MeshAvatarVowel.values,
                        (v) => v == MeshAvatarVowel.n
                            ? '闭口'
                            : v.name.toUpperCase(), (v) async {
                      await controller.holdMouth(v);
                      setState(() {
                        mouthDemo = false;
                        speaking = false;
                      });
                    }),
                    TextButton(
                        onPressed: () => run(() async {
                              await controller.stopLipSync();
                              setState(() {
                                mouthDemo = false;
                                speaking = false;
                              });
                            }),
                        child: const Text('停止全部口型驱动')),
                    SwitchListTile(
                        title: const Text('自动口型演示'),
                        value: mouthDemo,
                        onChanged: (v) => run(() async {
                              await controller.setMouthDemo(v);
                              setState(() {
                                mouthDemo = v;
                                speaking = false;
                              });
                            })),
                    SwitchListTile(
                        title: const Text('用下方音量驱动'),
                        value: speaking,
                        onChanged: (v) => run(() async {
                              await controller.setSpeaking(v);
                              // 重新进入音量模式时应用面板保留的音量，避免滑块与实际输入不一致。
                              if (v) {
                                await controller
                                    .setVoiceLevel(sliders['voice'] ?? 0);
                              }
                              setState(() {
                                speaking = v;
                                mouthDemo = false;
                              });
                            })),
                    slider('voice', '输入音量', 0, 1, 0, controller.setVoiceLevel),
                    TextField(
                        key: const PageStorageKey('kana-input'),
                        controller: kana,
                        decoration:
                            const InputDecoration(labelText: '假名文本（不自动转换中文）')),
                    SwitchListTile(
                        title: const Text('循环假名口型'),
                        value: kanaLoop,
                        onChanged: (v) => setState(() => kanaLoop = v)),
                    slider('speed', '每秒拍数', 4, 12, 7, (v) async {}),
                    FilledButton(
                        onPressed: () => run(() async {
                              await controller.speakKana(kana.text,
                                  speed: sliders['speed'] ?? 7, loop: kanaLoop);
                              setState(() {
                                mouthDemo = false;
                                speaking = false;
                              });
                            }),
                        child: const Text('播放假名口型')),
                    slider(
                        'granularity',
                        '口型灵敏度',
                        0,
                        1,
                        0.5,
                        (v) => controller.setLipSync(
                            MeshAvatarLipSyncSettings(granularity: v))),
                    slider(
                        'openness',
                        '张口幅度',
                        0,
                        1,
                        0.5,
                        (v) => controller.setLipSync(
                            MeshAvatarLipSyncSettings(openness: v))),
                    slider(
                        'closeSpeed',
                        '闭口速度',
                        0,
                        1,
                        0.5,
                        (v) => controller.setLipSync(
                            MeshAvatarLipSyncSettings(closeSpeed: v))),
                  ]),
                  section('头部、眼神与手动参数', [
                    const Text(
                        '松手应用。调过的参数持续覆盖自动动作，恢复自动后交还运行库。模型未绑定的部位可能没有可见变化。'),
                    slider('weight', '手动覆盖权重', 0, 1, 1, (v) async {
                      await controller.setParameters(overrides, weight: v);
                      weight = v;
                    }),
                    TextButton(
                        onPressed: () => run(() async {
                              await controller.clearParameters();
                              setState(() {
                                overrides.clear();
                                for (final p in metadata!.parameters) {
                                  sliders.remove(p.id);
                                }
                              });
                            }),
                        child: const Text('全部恢复自动')),
                    for (final group in groups.entries)
                      section(group.value, [
                        for (final p in metadata!.parameters.where((p) =>
                            p.group == group.key ||
                            (group.key == 'Eyes and brows' &&
                                p.id == 'eyeSmileL')))
                          slider(p.id, parameterLabels[p.id] ?? p.label, p.min,
                              p.max, p.defaultValue, (v) async {
                            final next = {...overrides, p.id: v};
                            await controller.setParameters(next,
                                weight: weight);
                            overrides.addAll(next);
                          }),
                      ]),
                  ]),
                  section('配饰开关', [
                    if (metadata!.overlays.isEmpty)
                      const Text(
                          '当前官方 Miko 模型没有独立配饰图层。换成配置了 overlays 的模型后，这里自动显示开关。'),
                    for (final name in metadata!.overlays)
                      CheckboxListTile(
                          title: Text(name),
                          value: selectedOverlays.contains(name),
                          onChanged: (v) => run(() async {
                                final next = {...selectedOverlays};
                                if (v == true) {
                                  next.add(name);
                                } else {
                                  next.remove(name);
                                }
                                await controller.setOverlays(next.toList());
                                setState(() {
                                  selectedOverlays.clear();
                                  selectedOverlays.addAll(next);
                                });
                              })),
                  ]),
                  section('衣物物理', [
                    if (metadata!.garments.isEmpty)
                      const Text('当前模型没有独立衣物物理部件；不会将旗袍图片假装成可调部件。'),
                    for (final name in metadata!.garments)
                      section(name, [
                        for (final field
                            in <(String, String, double, double, double)>[
                          ('responseGain', '响应幅度', 0.1, 3, 1),
                          ('tierGain', '分层幅度', 0.1, 3, 1),
                          ('highModeDamping', '高阶阻尼', 0.1, 3, 1),
                          ('swing', '摆幅', 0.1, 3, 1),
                          ('stiffness', '刚度', 0.1, 3, 1),
                          ('damping', '阻尼', 0.1, 3, 1),
                          ('follow', '跟随', 0, 1, 0.85),
                          ('cohesion', '连接强度', 0, 8, 3),
                          ('wind', '风力', 0, 1, 0.05),
                          ('max', '最大角度', 1, 45, 20),
                        ])
                          slider(
                              'cloth-$name-${field.$1}',
                              field.$2,
                              field.$3,
                              field.$4,
                              field.$5,
                              (v) => controller
                                  .setClothTuning({field.$1: v}, name: name),
                              divisions: field.$1 == 'cohesion' ? 8 : null),
                      ]),
                  ]),
                ],
                section('切换模型', [
                  TextField(
                      key: const PageStorageKey('path-input'),
                      controller: path,
                      decoration: const InputDecoration(
                          labelText: '本机模型路径（留空使用官方 Miko）')),
                  FilledButton(
                      onPressed: controller.isLoading ? null : load,
                      child: const Text('加载角色')),
                ]),
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                        'Miko © Yuki Shindo (AITuber OnAir)\n原生运行 · 无 WebView · 不提供制作编辑器',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11))),
              ])),
        ])),
      );
}
