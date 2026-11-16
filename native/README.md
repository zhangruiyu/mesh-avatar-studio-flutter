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

## Flutter GPU 直接输出扩展

`0.1.0-dev.3` 新增 `mesh-avatar-ffi/src/render/direct.rs`，只在 Android/Apple 且启用 `render` 时编译。Android 使用 Surface 交换链，Apple 接收同一 Metal 设备创建的 BGRA 纹理；异步完成序号用于保证 Swift 发布前 GPU 已写完。旧 `mesh_avatar_renderer_*` 同步回读入口保留，供已有 C 调用者和对照测试使用。

Apple 桥接持有 CVPixelBuffer 和 CVMetalTexture 到提交完成，池最多三张、待完成任务最多两帧。关闭时先等待并销毁 GPU 渲染器，再释放缓冲和模型。Android 先解除/销毁交换链，之后才释放 ANativeWindow。正常逐帧路径没有同步读回 CPU。

Cargo.lock 只把已经存在的 `metal 0.32`、`foreign-types 0.5` 列为 Apple 直接依赖，没有增加第三方版本，现有许可文件继续适用。`mesh-avatar-wgpu` 缓存 UV/索引的实际内容，不能只凭长度判断不变。

在有 Metal 的 macOS 上执行 `cargo test -p mesh-avatar-ffi --features render direct::tests --manifest-path native/upstream/Cargo.toml`，会用官方 example 模型比较共享纹理与旧输出的每个像素，并验证透明背景、完成序号与释放后的无效句柄。
