# 0.1.0-dev.2 验证记录

验证日期：2026-11-16。仅验证独立插件与公开 example，没有接入或修改业务 App。

| 验证项 | 本版本结果 |
| --- | --- |
| Flutter 静态检查 | 无问题 |
| Dart 接口、队列与生命周期 | 10 项通过 |
| Rust FFI | 新增 4 项控制测试通过；隔离副本补齐官方样例后，连同旧 ABI 共 12 项通过 |
| iOS ARM64 模拟器，iPhone 17 Pro / iOS 26 | 完整原生 API 与示例页面点击测试通过 |
| macOS ARM64 | 完整原生 API 集成测试通过 |
| Android ARM64 / API 35 临时模拟器 | 完整原生 API 与示例页面点击测试通过 |
| Android ARMv7 / ARM64 / x64 | 三种 Release APK 编译通过，实际 ELF 架构、四个必需库和插件 16 KiB 对齐检查通过 |
| iOS ARM64 真机架构 | Release 无签名编译通过；无 iPhone 真机运行结果 |
| HarmonyOS ARM64 | 鸿蒙分支编译签名 HAP 通过；本轮设备未连接，未完成新版真机运行复验 |
| Android ARM64 真机 | 手机连接正常，但安装被设备返回 INSTALL_FAILED_USER_RESTRICTED 拒绝，本轮没有新版运行结果 |
| 预编译库 | 7 份文件、共 9 个平台/架构目标，SHA-256 与清单一致 |

原生集成覆盖官方 asset/文件/字节加载、全部 21 个动作及事件、6 种情绪、8 种表情、参数覆盖及清空、元音/假名/音量互斥切换、口型设置、待机开关、物理幅度、暂停、3 次连续重载、失败恢复和释放。生命周期采用 Flutter 测试事件，不等于长期锁屏压力测试。

新增 Rust 回归验证非法参数整批不生效、所有动作开始/结束事件、256 条事件队列上限、口型设置与 UTF-8 文本、配饰实际增减绘制层、衣物运行参数与失败原子性。官方 Miko 没有独立 overlays 和 cloth，因此配饰与衣物使用仅存在于测试内存的合成夹具验证；未修改或增加随包素材。旧 ABI 测试所需 samples 仅在临时副本中解压官方模型，不进入发布包。

常规 SDK 为 Flutter 3.47.9 / Dart 3.13.7；鸿蒙使用 oh-3.47.9-dev 分支和 DevEco SDK。当前小米设备仅支持 arm64-v8a，不能运行 ARM32 APK；ARM32、Android x64、Intel Mac 和 x64 iOS 模拟器本轮仅验证编译/产物，不能用 ARM64 运行结果代替。较低 SDK 和系统版本未覆盖。

Apple 仍使用 CocoaPods，Flutter 会提示尚未支持 Swift Package Manager。该项未在本次运行控制范围内改动。制作编辑器、WebView、多引擎和多角色均未加入。
