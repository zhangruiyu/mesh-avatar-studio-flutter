## 0.1.0-dev.1

- 将独立原生样品封装为可自动注册的 Flutter 插件。
- 支持 Android、iOS、macOS 和 HarmonyOS 的原生纹理显示。
- Android 补充 `armeabi-v7a`（32 位 ARM）运行库、按 ABI 重编译选项及 APK 架构检查脚本。
- 提供文件、ZIP 字节、asset 加载，以及表情、动作、真实音量和无声口型演示。
- 加入顺序加载、失败恢复、主动暂停、前后台暂停和释放控制。
- 包含预编译库、原生源码、依赖许可证和默认加载官方 Miko 的示例 App（素材遵守独立角色条款）。
- 首版限制：单活动角色、单 Flutter 引擎、固定 600 × 800 画布；Apple 采用 CocoaPods。
