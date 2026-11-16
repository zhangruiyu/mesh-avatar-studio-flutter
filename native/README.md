# 原生运行库

上游提交：`6d2817aa0869365a0a5634241bf50af6bfd78a2a`，MIT。

`upstream` 保留 Rust workspace、三个运行库 crate 和桌面 crate 的源码及 Cargo.lock，便于追溯和重新编译。它不包含上游演示角色；依赖演示模型的上游测试应在完整上游 checkout 中运行。Flutter 接入层位于 `android`、`darwin`、`ohos`，不在 Rust 核心中混入业务逻辑。

使用者无需编译 Rust。维护者可执行 `python3 tool/build_native.py apple` 或 `python3 tool/build_native.py android --ndk /Android/NDK/路径`、`python3 tool/build_native.py ohos --ohos-native /DevEco/SDK/native/路径`。需要 macOS、Xcode、Rust/rustup、对应平台 SDK；脚本会安装目标工具链并更新二进制。构建目标写在脚本里，不依赖维护者个人目录。

发布前执行 `python3 tool/check_binaries.py --write` 更新校验清单，再运行不带 `--write` 的命令核对。改变上游或 Cargo.lock 后，还要重新整理第三方许可证并执行各平台集成测试；仅更新二进制校验不代表通过验收。

Apple / Android 启用 `mesh-avatar-ffi/render`，鸿蒙只构建 CPU 动作核心，由插件内的 C++ OpenGL ES 渲染器绘制。所有调用来自原生桥接，不运行 WebView。

Android 默认构建全部三个 ABI。只补编译 32 位 ARM 时可使用 `python3 tool/build_native.py android --android-abi armeabi-v7a --ndk /Android/NDK/路径`，避免重建已验证的其他架构。
