# 0.1.0-dev.1 验证记录

验证日期：2026-11-16。所有测试均使用独立插件与公开 `example`，没有接入业务 App。

| 验证项 | 结果 |
| --- | --- |
| Dart 静态分析 | 无问题 |
| Dart 接口与异步生命周期测试 | 8 项通过 |
| iOS ARM64 模拟器，iPhone 17 Pro / iOS 26 | 原生集成测试通过 |
| macOS ARM64 | 原生集成测试通过 |
| 不带任何缓存的 Git 解包副本，macOS | 重新构建、自动注册和原生集成测试通过 |
| HarmonyOS ARM64，HUAWEI Pura X 真机 | 原生集成测试通过 |
| Android ARMv7 / ARM64 / x64 | 三种架构 Release APK 均通过编译与包内架构检查；ARMv7 Debug APK 也通过 |
| Android ARM64 真机 | 小米 23127PN0CC / API 36，官方模型完整集成测试通过 |
| iOS ARM64 真机架构 | Release 无签名编译通过；未做 iPhone 真机运行验收 |
| Android 原生库内存页 | 三个 ABI 的插件库 LOAD 段均为 16 KiB 对齐 |
| 二进制校验 | 7 个库，SHA-256 与清单一致 |

集成测试实际覆盖：插件自动注册、文件加载、8 种表情、动作、真实音量命令、无声口型、暂停、连续 3 次字节重载、无效路径报错后恢复、释放资源。前后台状态采用 Flutter 生命周期测试事件，不等于长时间后台/锁屏压力测试。首轮使用的自制测试模型没有进入仓库或 pub 发布包。后续官方 Miko 已按用户确认，仅作为 example App 的随包资源加入。

常规 Flutter 验证使用 3.47.9 / Dart 3.13.7；鸿蒙使用 `oh-3.47.9-dev` 分支（提交 `dba2b26b6cfca53e0e6dafb938b06f69551697bb`）与 DevEco Studio 26。Intel Mac、x64 iOS 模拟器和 Android x64 的库已包含，但本轮未在这些实际运行环境验收。较低 Flutter 版本和较低系统版本仍需维护者自行验证。

当前 Apple 链路使用 CocoaPods；新 Flutter 会给出尚未支持 Swift Package Manager 的提示。插件没有声明 Windows、Linux 或 Web 支持。

## 官方 Miko 随包示例复验

2026-11-16 将官方原始 `miko-qipao.mavatar` 接入示例。iOS 模拟器与鸿蒙 Pura X 真机均通过 asset 加载、文件加载、全部表情、音量口型、连续字节重载、暂停、失败恢复与释放测试，无需网络或事先向设备导入模型。静态分析无问题。

模型只在 `example/pubspec.yaml` 声明，插件根目录没有 assets 声明。官方模型与条款随示例分发，未改动原始模型内容；用户自制角色未随包。

## Android 32 位 ARM 支持复验

2026-11-16 新增 `armeabi-v7a`，使用 `armv7-linux-androideabi` 和 NDK 28.2 / API 26 编译 Rust 渲染运行库。原有六份原生库的 SHA-256 未变化，只新增 ARM32 库。

- ARM32 Debug APK、ARM32 / ARM64 / x64 Release APK 均编译成功。
- `tool/check_android_apk.py` 对包内实际 ELF 进行核对，三个 Release 包均包含匹配架构的 Flutter 引擎、Rust 库、JNI 桥接及 AOT `libapp.so`；插件库的 LOAD 段按 16 KiB 对齐。
- 小米真机执行官方 Miko 集成测试通过，覆盖 asset/文件加载、8 种表情、动作、音量口型、重载、暂停、失败恢复和释放。
- 静态分析无问题，8 项 Dart 单元测试通过。

**运行覆盖限制：** 当前小米设备 `ro.product.cpu.abilist=arm64-v8a`，`abilist32` 为空，不能运行 32 位 APK。因此 ARM32 已完成编译、链接和安装包架构验证，尚未完成 32 位设备实际渲染验收；ARM64 真机结果不能替代 ARM32 运行结果。32 位 x86 不在本次支持范围内。
