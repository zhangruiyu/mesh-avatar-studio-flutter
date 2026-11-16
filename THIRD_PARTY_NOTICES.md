# 第三方许可说明

本项目独立封装 Mesh Avatar Studio 原生运行库，并非上游官方 Flutter 包。

- 上游：https://github.com/shinshin86/mesh-avatar-studio
- 固定提交：`6d2817aa0869365a0a5634241bf50af6bfd78a2a`
- 作者与许可：Yuki Shindo，MIT，完整文本见 `native/upstream/LICENSE`。
- `native/include` 和 `native/upstream` 保留上游接口与源码；鸿蒙着色器来自同一上游渲染实现。
- `third_party/rust-dependencies.json` 列出 `mesh-avatar-ffi` 的依赖闭包（包含不同平台和构建阶段依赖，部分不进入每个二进制）。各自版权和许可正文保存在 `third_party/licenses`。
- Rust 标准库许可与版权汇总保存在 `third_party/licenses/rust-standard-library`。
- 预编译 Rust 库由 Rust 1.100.0 构建。Flutter、Apple SDK、Android SDK/NDK 和 HarmonyOS SDK 为宿主构建工具或系统依赖，不作为 SDK 全包再分发。

双重或多重许可按原项目提供的可选许可使用；没有将其他项目统一改成 MIT。官方 Miko 模型仅作为 `example` App 的组成部分分发，不适用 MIT；其独立使用条款与版权说明见 `example/assets/miko/MIKO_ASSET_TERMS.md` 和 https://miko.aituberonair.com/#terms 。用户自行制作的角色图片及调试签名不在此发布包中。
