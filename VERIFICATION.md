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
| Android ARM64 / x64 | Debug APK 编译通过；本轮未连接 Android 真机 |
| iOS ARM64 真机架构 | Release 无签名编译通过；未做 iPhone 真机运行验收 |
| Android 原生库内存页 | 两个 ABI 的 LOAD 段均为 16 KiB 对齐 |
| 二进制校验 | 6 个库，SHA-256 与清单一致 |

集成测试实际覆盖：插件自动注册、文件加载、8 种表情、动作、真实音量命令、无声口型、暂停、连续 3 次字节重载、无效路径报错后恢复、释放资源。前后台状态采用 Flutter 生命周期测试事件，不等于长时间后台/锁屏压力测试。首轮使用的自制测试模型没有进入仓库或 pub 发布包。后续官方 Miko 已按用户确认，仅作为 example App 的随包资源加入。

常规 Flutter 验证使用 3.47.9 / Dart 3.13.7；鸿蒙使用 `oh-3.47.9-dev` 分支（提交 `dba2b26b6cfca53e0e6dafb938b06f69551697bb`）与 DevEco Studio 26。Intel Mac、x64 iOS 模拟器和 Android x64 的库已包含，但本轮未在这些实际运行环境验收。较低 Flutter 版本和较低系统版本仍需维护者自行验证。

当前 Apple 链路使用 CocoaPods；新 Flutter 会给出尚未支持 Swift Package Manager 的提示。插件没有声明 Windows、Linux 或 Web 支持。

## 官方 Miko 随包示例复验

2026-11-16 将官方原始 `miko-qipao.mavatar` 接入示例。iOS 模拟器与鸿蒙 Pura X 真机均通过 asset 加载、文件加载、全部表情、音量口型、连续字节重载、暂停、失败恢复与释放测试，无需网络或事先向设备导入模型。静态分析无问题。

模型只在 `example/pubspec.yaml` 声明，插件根目录没有 assets 声明。官方模型与条款随示例分发，未改动原始模型内容；用户自制角色未随包。
