# 发布维护说明

Dart 包名：`mesh_avatar_studio`；仓库：<https://github.com/zhangruiyu/mesh-avatar-studio-flutter>。

首版使用 `0.1.0-dev.1`，明确作为预览版。目录中包含实际需要的原生库，不通过安装脚本临时从个人机器下载。

发布前在包根目录执行：

```sh
flutter pub get
flutter analyze
flutter test
python3 tool/check_binaries.py
dart pub publish --dry-run
```

确认 `example` 在目标平台构建并执行真实模型集成测试，核对 `README.md` 的平台限制和 `CHANGELOG.md`。修改 Rust 依赖后必须同时更新许可清单。示例仅允许提交已确认随包的官方 Miko 模型及原始条款；其他模型、用户图片、密钥和调试签名不得提交或发布。核对官方模型仍被 `example/pubspec.yaml` 声明，且不会被 `.pubignore` 排除。

预检只检查，不会上传。实际发布由包维护者在确认账号、版本和内容后执行 `dart pub publish`；发布后的版本不能覆盖。

Apple 首版采用 CocoaPods，当前尚未提供 Swift Package Manager 清单。Android 仅发布 ARM64 和 x64，宿主不要加入 32 位 ABI。鸿蒙需要支持 ohos 插件的平台分支和个人调试签名。
