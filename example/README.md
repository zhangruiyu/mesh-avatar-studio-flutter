# 插件使用示例

本工程只使用 `mesh_avatar_studio` 的公开 Dart API，原生插件由 Flutter 自动注册。

默认随包加载官方旗袍角色 **Miko**，启动即可体验，不需要网络或手动填写路径：

```sh
flutter run -d 设备标识
flutter test integration_test/native_avatar_test.dart -d 设备标识
```

Miko 为 © Yuki Shindo (AITuber OnAir)，适用[官方角色条款](https://miko.aituberonair.com/#terms)，不属于本插件代码的 MIT 许可。原始条款和来源说明见 `assets/miko`。本项目不是 AITuber OnAir 官方或合作产品。模型仅是示例 App 的组成部分，不能作为独立素材包再分发。

也可输入应用有权读取的自定义 `.mavatar` 路径，或用 `--dart-define=AVATAR_PATH=/模型路径` 启动。清空路径并点击“加载角色”即可回到官方 Miko。普通应用依赖此插件时不会自动打包 example 中的 Miko。

macOS 的 Debug/Profile 示例关闭应用沙箱，方便输入电脑路径；Release 保持沙箱，必须通过授权文件选择或应用容器读取。插件本身不会修改宿主 entitlement。

鸿蒙须使用支持 ohos 的 Flutter SDK，并在 DevEco Studio 中生成自己的调试签名。公开工程不包含任何个人证书。

默认集成测试覆盖随包模型加载、临时文件加载、8 种表情、动作、音量口型、连续重载、暂停、错误恢复和释放；临时文件在测试后删除。


## 运行控制面板

上方持续显示角色，下方展开动作与情绪、自动待机、口型、手动参数、配饰和衣物设置。动作列表包含全部 21 个动作；滑块松手后应用，手动参数通过“全部恢复自动”交还运行库。所有调整只作用于当前实例，不保存模型，不提供制作编辑器。

官方 Miko 没有独立配饰和衣物物理部件，对应区域会显示说明；载入配置了 overlays / cloth 的模型后自动显示实际部件。真实语音由宿主负责，示例不发声、不申请录音权限。

页面交互验收命令：`flutter test integration_test/example_controls_test.dart -d 设备标识`。
