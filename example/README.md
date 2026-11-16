# 插件使用示例

本工程只通过 `mesh_avatar_studio` 的公开 Dart API 使用角色，原生插件由 Flutter 自动注册。示例不携带角色素材。

在有权限读取本地模型的平台，可用 `flutter run --dart-define=AVATAR_PATH=/模型绝对路径` 启动。移动端须先把模型导入应用沙箱，再填写设备中的路径。也可自行使用公开的 `loadBytes` / `loadAsset` 接入应用已有下载或资源管理。

macOS 的 Debug/Profile 示例关闭应用沙箱，方便输入电脑路径；Release 保持沙箱，必须通过授权文件选择或应用容器读取。插件本身不会修改宿主的 entitlement。

鸿蒙须使用支持 ohos 的 Flutter SDK，并在 DevEco Studio 中为自己的设备生成调试签名。`ohos/build-profile.json5` 默认没有任何个人签名。

集成测试覆盖自动注册、8 种表情、文件/字节加载、口型、暂停、错误恢复和资源释放。在本目录执行：

```sh
flutter test integration_test/native_avatar_test.dart -d 设备标识 --dart-define=AVATAR_PATH=设备中的模型路径
```
