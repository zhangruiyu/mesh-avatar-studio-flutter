# 发布维护说明

Dart 包名：`mesh_avatar_studio`；仓库：<https://github.com/zhangruiyu/mesh-avatar-studio-flutter>。

当前使用 `0.1.0-dev.4`，明确作为预览版。目录中包含实际需要的原生库，不通过安装脚本临时从个人机器下载。

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

Apple 首版采用 CocoaPods，当前尚未提供 Swift Package Manager 清单。Android 发布 ARMv7、ARM64 和 x64，分别对应 `armeabi-v7a`、`arm64-v8a`、`x86_64`。32 位 ARM 支持不代表所有旧设备的 GPU 都满足 Vulkan 要求。鸿蒙需要支持 ohos 插件的平台分支和个人调试签名。

Android 发布前在 `example` 中构建分架构 APK，并从包根目录核对实际库：

```sh
# 在 example 中执行
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64,android-x64
# 回到插件根目录执行
python3 tool/check_android_apk.py example/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk --abis armeabi-v7a
python3 tool/check_android_apk.py example/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk --abis arm64-v8a
python3 tool/check_android_apk.py example/build/app/outputs/flutter-apk/app-x86_64-release.apk --abis x86_64
```

脚本检查 APK 是否包含正确架构的 Flutter 引擎、Rust 运行库及 JNI 桥接，并检查插件库的 16 KiB 对齐。真机运行测试的覆盖范围仍单独记录在 `VERIFICATION.md`。
