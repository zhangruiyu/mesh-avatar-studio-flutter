# mesh-avatar-studio

Flutter 原生 2D 网格角色播放器，Dart 包名为 `mesh_avatar_studio`。将 [Mesh Avatar Studio](https://github.com/shinshin86/mesh-avatar-studio) 导出的角色显示为 Flutter `Texture`，支持自动眨眼、呼吸、表情、动作和音量驱动口型。**不使用 WebView，不执行 JavaScript。**

这是基于上游开源运行库开发的独立 Flutter 插件，并非上游官方插件。它读取 Mesh Avatar Studio 的 `.mavatar` ZIP 或导出目录，**不能直接读取 Live2D Cubism 的 `.moc3` / `.model3.json`**。

当前为 `0.1.0-dev.5` 预览版。插件不会自动下载模型、播放声音或申请录音权限。`example` 已内置官方 Miko 示例角色，运行即可体验；普通应用依赖插件不会自动打包该示例资源。

## 安装

通过 pub.dev 安装预览版：

```yaml
dependencies:
  mesh_avatar_studio: ^0.1.0-dev.5
```

本地开发时，也可通过目录依赖接入：

```yaml
dependencies:
  mesh_avatar_studio:
    path: ../mesh-avatar-studio
```

最低要求 Flutter 3.29（Android 原生纹理回收接口所需）；本轮实际验收 SDK 为 Flutter 3.47.9，较低版本未做完整运行验收。正常 Flutter 插件自动注册，不需要把 Swift、Kotlin 或 ArkTS 代码复制到业务项目。Apple 平台当前通过 CocoaPods 接入；依赖 Rust 的预编译库已包含在插件中，使用者不需要安装 Rust。

## 最小用法

```dart
import 'package:flutter/material.dart';
import 'package:mesh_avatar_studio/mesh_avatar_studio.dart';

class AvatarPage extends StatefulWidget {
  const AvatarPage({super.key, required this.modelPath});
  final String modelPath;

  @override
  State<AvatarPage> createState() => _AvatarPageState();
}

class _AvatarPageState extends State<AvatarPage> {
  final controller = MeshAvatarController();
  Object? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      await controller.loadFile(widget.modelPath);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: error == null
            ? MeshAvatarView(controller: controller)
            : Center(child: Text('角色加载失败：$error')),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            await controller.setExpression(MeshAvatarExpression.smile);
            await controller.playMotion(MeshAvatarMotion.nod);
          },
          child: const Icon(Icons.mood),
        ),
      );
}
```

`MeshAvatarView` 需要有界布局空间，例如 `SizedBox`、`Expanded` 或上例中的 `Scaffold.body`。未加载时保持透明，不显示替代图片。

## 模型加载与存储

- `loadFile(path)`：加载应用有权读取的本地 `.mavatar` 文件或导出目录。
- `loadBytes(bytes)`：加载完整 `.mavatar` ZIP 字节，调用时会复制输入。网络下载、鉴权和缓存由宿主应用负责。
- `loadAsset(key)`：加载宿主在 `pubspec.yaml` 中明确声明的模型 asset，也可传入 `bundle`。

插件不决定模型放云端还是随包，也不写入永久缓存。只加载可信模型，避免把未经验证的大体积 ZIP 直接交给运行库。模型对应的图片版权、网络下载权限和业务数据归属由宿主维护。

首版每个主 isolate 只有一个活动控制器，不支持多 Flutter 引擎。多个页面可以共享同一控制器；`MeshAvatarView` 不负责销毁它。切换角色直接再次 `loadFile/loadBytes/loadAsset`，插件会按顺序释放旧角色再加载新角色。第二个控制器需要在 `await oldController.close()` 后再加载。

页面退出调用 `dispose()`。如果必须等原生释放完成，先 `await close()` 再 `dispose()`。`close()` 后可以再次加载，`dispose()` 后不能继续使用。加载失败后可再次调用加载恢复。命令通过 Future 返回异常，原生绘制错误记录在 `lastError`，可用 `addListener` 或 `AnimatedBuilder` 观察。

## 动作、音量和暂停

```dart
await controller.setExpression(MeshAvatarExpression.smile);
await controller.playMotion(MeshAvatarMotion.greet);

// TTS 或音频播放由业务处理，每次传入自己的归一化音量。
await controller.setSpeaking(true);
await controller.setVoiceLevel(0.65); // 0～1 的有限数
await controller.setSpeaking(false);

// 仅用于无声演示，不能当成真实语音同步。
await controller.setMouthDemo(true);
await controller.setMouthDemo(false);

await controller.setPaused(true);
final stats = await controller.getStats();
debugPrint('${stats.frames} 帧，平均 ${stats.renderMilliseconds} ms');
```

支持表情：`neutral`、`smile`、`shy`、`surprise`、`halfLidded`、`angry`、`sad`、`wink`。支持全部 21 个动作：`nod`、`no`、`sway`、`greet`、`tilt`、`think`、`giggle`、`surprise`、`shy`、`wink`、`lookAround`、`glance`、`sigh`、`doze`、`stretch`、`lean`、`hum`、`tap`、`readNote`、`waiting`、`spaceOut`。具体视觉效果取决于角色导出时的图层和绑定。

默认移动端进入后台暂停绘制，回来后继续；用户主动暂停不会被前台恢复覆盖。macOS 窗口失焦仍可绘制。可通过 `MeshAvatarController(pauseWhenBackground: false)` 关闭自动暂停。统计中的耗时包含原生绘制和提交，不是纯 GPU 时间，也不等于 Flutter 页面 FPS。

## 完整运行控制

本插件只做播放器和运行控制，**不提供角色制作、图层编辑、绑定编辑或模型保存功能**。调节仅作用于当前加载实例，重新加载恢复模型默认值。

```dart
final metadata = await controller.getMetadata();
await controller.playMotionById('lookAround');
await controller.setEmotion(MeshAvatarEmotion.happy, playMotion: true);

// 整批替换手动覆盖值；下一次只传 angleX，旧 gazeX 覆盖就会取消。
await controller.setParameters({'angleX': 12, 'gazeX': 0.4}, weight: 0.8);
await controller.clearParameters(); // 恢复自动控制
await controller.setAutoIdle(true);
await controller.setAutoMotion(true);
await controller.setTalkGain(1.2);
await controller.setSwayGain(0.8);

await controller.setLipSync(const MeshAvatarLipSyncSettings(
  granularity: 0.5, openness: 0.7, closeSpeed: 0.6,
));
await controller.holdMouth(MeshAvatarVowel.a);
await controller.speakKana('こんにちは', speed: 7, loop: false);
await controller.stopLipSync();

await controller.setOverlays(metadata.overlays); // 显示全部已配置配饰
await controller.setOverlays([]);
if (metadata.garments.isNotEmpty) {
  await controller.setClothTuning({'follow': 0.8, 'damping': 1.2},
      name: metadata.garments.first);
}
final state = await controller.getState();
debugPrint('当前动作：${state.motion}，手动参数：${state.overrides}');
final subscription = controller.motionEvents.listen((event) {
  debugPrint(event.id == null ? '动作结束' : '动作开始：${event.id}');
}, onError: (Object error) { debugPrint('$error'); });
// 页面结束时取消订阅，再释放控制器。
await subscription.cancel();
```

- 情绪 `neutral / happy / sad / angry / surprised / relaxed` 与 8 种素材表情独立，可搭配使用。`emotionExpression` 返回底层混合表情名，如 `happyTalk`。
- 25 个参数及范围由 `metadata.parameters` 返回，覆盖头部、身体、眼睛、视线、眉毛、口型、脸红、手部、双臂与重心。模型未绑定的参数可能没有可见效果。非法参数整批拒绝，不会部分生效；手动覆盖持续到替换或清空。
- 元音、假名和音量/演示口型互斥切换。假名接口只驱动嘴形，不发声，不合成语音，也不将中文转换为假名；速度为每秒 4..12 拍。口型设置均为 0..1，省略字段保留原值。手动 `mouthOpen/mouthForm` 覆盖仍优先，必要时先 `clearParameters()`。
- `setAutoIdle` 控制自动呼吸、眨眼和视线；`setAutoMotion` 控制自动选动作，不中断已开始动作。说话和摆动幅度必须为非负有限数，默认 1，0 关闭。
- `setOverlays` 替换显示名单，未知名字按上游规则忽略。**官方随包 Miko 没有独立 overlays 和 cloth 部件**，示例显示说明；换成具有这些部件的模型后自动出现控件。
- 衣物调节是局部更新，省略 `name` 调节全部衣物。`responseGain / tierGain / highModeDamping / swing / stiffness / damping / max` 必须为正有限数；`follow` 为 0..1；`cohesion` 为 0..8 整数；`wind` 为非负有限数。未知衣物名、字段或非法值整批拒绝。`state.clothTuning` 可查询实际参数。
- `getState()` 返回最近一帧参数、覆盖值、动作、口型、配饰和设置；设置后需等下一帧才能在 `parameters` 看到变化。原有 `getStats()` 保留。
- `motionEvents` 包含手动和自动动作；有订阅时每 100ms 读取，不订阅不轮询。原生最多保留最近 256 次变化，`getState()` 也会取出并分发事件；未订阅时事件不重播，长时间未读取可能丢弃更旧事件。暂停不产生新帧事件，重载清空旧队列。

## 平台范围

| 平台 | 发布的架构 | 原生实现 | 宿主要求 |
| --- | --- | --- | --- |
| Android | ARMv7（32 位）、ARM64、x86_64 | Rust / wgpu Vulkan + SurfaceProducer | API 26+，兼容 Vulkan 的设备 |
| iOS | ARM64 真机，ARM64 / x86_64 模拟器 | Rust / wgpu Metal + CVPixelBuffer | iOS 13+，CocoaPods |
| macOS | ARM64、x86_64 | Rust / wgpu Metal + CVPixelBuffer | macOS 10.15+，CocoaPods |
| HarmonyOS | ARM64 | Rust 动作核心 + C++ OpenGL ES 3 + 原生纹理 | Flutter 鸿蒙分支与 DevEco SDK，示例 API 17+ |

不支持 Web、Windows、Linux 和 Android 32 位 x86。Android 支持 `android-arm,android-arm64,android-x64`，对应 `armeabi-v7a,arm64-v8a,x86_64`。宿主如果设置了 `ndk.abiFilters`，需包含希望支持的架构。32 位 ARM 的原生库与 APK 已编译验证，当前未具备可运行 32 位应用的设备；具体机型仍须验证 Vulkan 渲染，不能仅凭 ABI 判断兼容。插件使用 Java 17、NDK 28.2 和 CMake 3.22.1。鸿蒙须使用支持 `ohos` 插件的 Flutter 分支；普通 Flutter SDK 可正常用于其他平台。

当前原生画布固定为 **600 × 800，约 30 帧/秒**。`MeshAvatarView.fit` 控制这张纹理在组件中的缩放，默认 `BoxFit.contain`；不能恢复原生画布已裁掉的内容。Android 使用 GPU 交换链直接输出到 Flutter Surface；iOS/macOS 使用 Metal 直接写入 IOSurface 共享的 BGRA 缓冲区，GPU 完成后才交给 Flutter。播放器不再执行整帧像素回读、逐行复制或 CPU 色彩通道转换。Apple 缓冲池最多三张，合成器占用时跳过绘制，避免无限分配；Android/Apple 的网格 UV 和索引仅在内容变化时上传。鸿蒙直接输出原生纹理，在图层间复用三个流式缓冲；已撤回按图层保存整份网格的缓存方案，保留平均耗时统计和有上限的窗口请求超时。仍需结合机型验收，当前不作为多角色或高帧率方案。

`renderMilliseconds` 表示本次加载以来成功提交帧的准备与提交平均耗时，暂停不累计、重新加载清零；鸿蒙包含 EGL 提交等待。这不是纯 GPU 时间，也不是屏幕端到端延迟。优化前后采样与限制见 [性能验证](PERFORMANCE.md)。

## 示例与验证

`example` 是只依赖插件公开接口的完整 Flutter 工程，默认通过 `loadAsset` 加载随包的官方旗袍角色 Miko，无需网络或手动导入。上方显示角色，下方提供完整运行控制面板；滑块松手时应用，手动参数可恢复自动。可输入本地路径切换自定义角色，清空路径后点击“加载角色”回到 Miko。

在 `example` 目录运行：

```sh
flutter run -d 设备标识
flutter test integration_test/native_avatar_test.dart -d 设备标识
# 可选：改用自己的本地模型
flutter run -d macos --dart-define=AVATAR_PATH=/绝对路径/角色.mavatar
```

自定义模型的移动设备路径是设备沙箱路径，不是电脑路径；先通过宿主自己的下载/导入流程写入。鸿蒙示例需要在 DevEco Studio 里为自己的设备生成调试签名，发布包不含证书。

## 原生源码、许可与维护

上游固定版本、构建方式和二进制校验见 [native/README.md](native/README.md) 与 [native/BINARIES.json](native/BINARIES.json)。插件代码和上游运行库为 MIT；**Miko 角色素材不属于 MIT**，需遵守[官方角色条款](https://miko.aituberonair.com/#terms)，原始说明保存在 `example/assets/miko`；依赖的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。预编译库只包含运行时，不包含角色素材。


<a id="native-upstream"></a>

## native 跟随上游主仓库（Codex 维护入口）

**原生算法跟随官方主仓库更新，本插件不维护独立的变形算法优化分支。** Flutter 接口、纹理传递、生命周期和平台兼容由本插件维护。每次用户要求更新 native 时，Codex 应先查询上游最新变更，再同步相关原生代码；仅发布或修改文档时不顺带升级算法。

- 上游主仓库：[shinshin86/mesh-avatar-studio](https://github.com/shinshin86/mesh-avatar-studio)。
- 上游 native 入口：[native 目录](https://github.com/shinshin86/mesh-avatar-studio/tree/main/native)，[native 提交记录](https://github.com/shinshin86/mesh-avatar-studio/commits/main/native)。
- 当前同步基线：[`6d2817aa0869365a0a5634241bf50af6bfd78a2a`](https://github.com/shinshin86/mesh-avatar-studio/tree/6d2817aa0869365a0a5634241bf50af6bfd78a2a/native)。这不是“始终最新”的声明。
- 本地对应关系：上游 `native/` → 本仓库 `native/upstream/`；C 头文件 → `native/include/`。已维护的 Flutter 控制接口、GPU 直接输出补丁和构建说明见 [native/README.md](native/README.md)。

同步步骤：

1. 读取本节、`native/README.md` 和 `native/BINARIES.json`，确认当前基线与现有接入补丁。在独立的上游检出目录获取默认分支，比较旧基线到候选提交的 `native/`、C ABI、依赖与模型格式变更，记录准备跟随的完整提交号。
2. 将相关改动合入 `native/upstream/`，逐项保留或用上游等价实现替换本地控制接口和 GPU 输出补丁。不能直接整目录覆盖，也不能只改基线号。仅同步播放器需要的运行库，不引入制作编辑器、用户角色或调试签名。
3. 源码变化后重建 Android 三 ABI、Apple 的 iOS/模拟器/macOS 切片和鸿蒙 ARM64；核对 `native/include/` 与各平台调用一致。命令见 `tool/build_native.py` 和 `native/README.md`，不要复制其他项目或临时实验的二进制。
4. 执行 Dart 分析、单元测试、Rust 回归和各平台集成/构建检查；使用官方 Miko 验证动作、口型、暂停恢复和释放。涉及渲染/变形时比较画面，涉及性能时固定画布和帧率做真机对照。缺失的设备覆盖如实记录。
5. 同步更新本节、`native/README.md`、`THIRD_PARTY_NOTICES.md`、`native/BINARIES.json` 以及 `tool/check_binaries.py` 中的构建元信息（当前脚本写有固定基线和 Rust 版本）；运行 `python3 tool/check_binaries.py --write` 更新哈希，再去掉 `--write` 核验。依赖变化时重新核对第三方许可。更新 `CHANGELOG.md`，按 [PUBLISHING.md](PUBLISHING.md) 预检，并依照当前用户授权提交、推送或发布。
