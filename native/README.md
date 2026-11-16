# 原生运行库

上游提交：`6d2817aa0869365a0a5634241bf50af6bfd78a2a`，MIT。

`upstream` 保留 Rust workspace、三个运行库 crate 和桌面 crate 的源码及 Cargo.lock，便于追溯和重新编译。它不包含上游演示角色；依赖演示模型的上游测试应在完整上游 checkout 中运行。Flutter 接入层位于 `android`、`darwin`、`ohos`，不在 Rust 核心中混入业务逻辑。

使用者无需编译 Rust。维护者可执行 `python3 tool/build_native.py apple` 或 `python3 tool/build_native.py android --ndk /Android/NDK/路径`、`python3 tool/build_native.py ohos --ohos-native /DevEco/SDK/native/路径`。需要 macOS、Xcode、Rust/rustup、对应平台 SDK；脚本会安装目标工具链并更新二进制。构建目标写在脚本里，不依赖维护者个人目录。

发布前执行 `python3 tool/check_binaries.py --write` 更新校验清单，再运行不带 `--write` 的命令核对。改变上游或 Cargo.lock 后，还要重新整理第三方许可证并执行各平台集成测试；仅更新二进制校验不代表通过验收。

Apple / Android 启用 `mesh-avatar-ffi/render`，鸿蒙只构建 CPU 动作核心，由插件内的 C++ OpenGL ES 渲染器绘制。所有调用来自原生桥接，不运行 WebView。

Android 默认构建全部三个 ABI。只补编译 32 位 ARM 时可使用 `python3 tool/build_native.py android --android-abi armeabi-v7a --ndk /Android/NDK/路径`，避免重建已验证的其他架构。

## Flutter 运行控制扩展

`0.1.0-dev.2` 在上述固定上游源码基础上增加了本仓库维护的补丁，并非未经修改的上游二进制：

- `mesh-avatar-ffi/src/controls.rs` 提供 `mesh_avatar_control_json` 和 `mesh_avatar_free_string`。输入为 UTF-8 JSON，最多 64 KiB；成功输出由调用方恰好释放一次，失败输出为 NULL。旧 ABI 版本和旧入口不变，新增入口须使用本版本随包库。
- Rust 核心仅补充运行状态和衣物参数的只读快照；FFI 保存有上限的动作事件队列，不添加模型制作能力。
- 参数、口型、衣物等校验在 Rust 统一执行，各平台桥接负责串行调用和字符串内存管理。
- 新控制测试使用官方 example 模型，配饰/衣物夹具只在测试内存中构造，不生成或提交新素材。运行命令：`cargo test -p mesh-avatar-ffi controls::tests --manifest-path native/upstream/Cargo.toml`。
- Cargo.lock 只将已有 serde 加入 FFI 直接依赖，没有新增第三方包或改变版本，原许可清单继续适用。
