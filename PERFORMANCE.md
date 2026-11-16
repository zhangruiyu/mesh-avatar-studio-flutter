# GPU 直接输出验证

日期：2026-11-16。基线为 `c7667ad` / `0.1.0-dev.2`，优化为 `0.1.0-dev.3`。仅独立插件和官方 Miko 示例，未修改业务 App。

## 改动

- Android：wgpu 直接绘制到 Flutter Surface 的交换链，取消 `render_rgba → JNI 像素数组 → ANativeWindow_lock → memcpy`。
- iOS/macOS：Metal 直接绘制 IOSurface-backed BGRA CVPixelBuffer。Rust 返回异步提交序号，Swift 只发布已经完成的缓冲；取消像素回读、Swift RGBA 数组和 vImage 通道转换。
- Apple 缓冲池最多三张，最多两帧待完成。Flutter 持有时不能覆写或复用；暂时没有空闲缓冲就跳过绘制。完成帧在下一次调度时发布，所以提交耗时不是显示延迟。
- UV 和索引按实际内容缓存，只有变化时上传；动态顶点和面部参数继续逐帧更新。旧 C 回读 API 保持兼容，仅播放器退出该路径。

## 同条件短采样

同一官方模型、600 × 800、约 30 帧/秒，关闭自动动作、开启待机和口型演示，每轮播放 sway；预热后采三轮，每轮约 8 秒。均为 Flutter 3.47.9 的 **Debug 集成测试**；CPU 来自整个进程的 `clock()`，RSS 来自 `ProcessInfo.currentRss`。CPU、帧率、调用耗时列使用有效轮次的中位数，RSS 使用采样最大值。

| 环境 | 指标 | 优化前 | 优化后 |
| --- | --- | ---: | ---: |
| Android 真机 | 原生帧率（帧/秒） | 29.46 | 29.36 |
| Android 真机 | 进程 CPU（单核为 100%） | 61.55 | 48.12 |
| Android 真机 | 原生调用平均耗时（ms） | 18.09 | 10.69 |
| Android 真机 | 采样 RSS 峰值（MiB） | 451.74 | 452.60 |
| macOS ARM64 | 原生帧率（帧/秒） | 30.32 | 30.32 |
| macOS ARM64 | 进程 CPU（单核为 100%） | 20.79 | 20.73 |
| macOS ARM64 | 原生调用平均耗时（ms） | 5.60 | 3.71 |
| macOS ARM64 | 采样 RSS 峰值（MiB） | 434.56 | 447.98 |

Android 为小米 23127PN0CC / API 36 / ARM64；macOS 为本机 ARM64。macOS 前后第一轮均受到测试窗口未前置影响，已排除；优化前该轮甚至暂停了数分钟，不能拿它当有效性能数据。其余各保留两轮。Android 三轮全部保留，但 CPU 波动明显（优化前约 22%–70%，优化后约 13%–51%）。原始有效性标记见下方。

本次 Android CPU 中位数约下降 22%，帧率保持约 30；macOS 整进程 CPU 基本相同，不能声称明显下降。RSS 也没有下降，尤其 macOS 有增长；共享缓冲池的上限不等于进程总内存上限。

`nativeCallMs` 优化前包含同步 GPU 回读等待，优化后是 CPU 准备与提交。其下降不能直接解释为 GPU 变快、耗电降低或端到端延迟下降。本轮未测功耗、长期温控、多角色或低端设备，不能把 Debug 短采样外推成全部机型的 Release 收益。

## 正确性与真机验收

- 新增 Metal 对照测试：三帧共享 BGRA 输出与旧 RGBA 输出逐像素比较，通道还原后每通道误差不超过 1；透明背景、有效角色像素、递增完成序号与销毁后无效句柄均通过。
- Rust 新旧 FFI 及渲染共 16 项通过；Dart 10 项通过；Flutter 分析无问题。
- Android ARM64 真机、iOS ARM64 模拟器的完整原生 API 与示例点击通过；macOS 完整原生 API 通过。
- Android 正式样例三次真实 Home/返回恢复后仍显示 30 帧/秒，透明背景与角色画面正常。不是长期锁屏压力测试。
- Android 三 ABI Release APK、16 KiB 对齐和 iOS ARM64 无签名 Release 编译通过。无 iPhone 真机和 ARM32 真机结果；本轮未追加鸿蒙真机验证，鸿蒙原本的 GLES 直接输出路径未修改。

## 复现

在 example 中执行，采样时保持应用前台，并避免同时操作样例：

```sh
flutter test integration_test/render_benchmark_test.dart -d <设备ID> --dart-define=BENCH_LABEL=after
```

比较旧版时使用同一个测试文件、官方模型、SDK、设备和构建模式。测试新增了采样超时检查，防止后台暂停的数据混入结果；输出为 `MESH_BENCH` JSON。

<details>
<summary>本次原始采样（valid=false 为明确排除的前后台干扰轮次）</summary>

```json
[
  {
    "label": "before",
    "os": "android",
    "round": 1,
    "width": 600,
    "height": 800,
    "wallMs": 8110.54,
    "frames": 242,
    "fps": 29.83771734064563,
    "cpuPercent": 22.100945189839397,
    "peakRssMiB": 451.41796875,
    "nativeCallMs": 7.445484243801656,
    "valid": true
  },
  {
    "label": "before",
    "os": "android",
    "round": 2,
    "width": 600,
    "height": 800,
    "wallMs": 8153.798,
    "frames": 240,
    "fps": 29.434136092162206,
    "cpuPercent": 61.546950267838376,
    "peakRssMiB": 451.73828125,
    "nativeCallMs": 18.09393312499999,
    "valid": true
  },
  {
    "label": "before",
    "os": "android",
    "round": 3,
    "width": 600,
    "height": 800,
    "wallMs": 8111.497,
    "frames": 239,
    "fps": 29.464351648037347,
    "cpuPercent": 70.20988850763305,
    "peakRssMiB": 445.21484375,
    "nativeCallMs": 20.835835083682003,
    "valid": true
  },
  {
    "label": "after",
    "os": "android",
    "round": 1,
    "width": 600,
    "height": 800,
    "wallMs": 8212.636,
    "frames": 245,
    "fps": 29.83207827547696,
    "cpuPercent": 12.548711522098385,
    "peakRssMiB": 452.29296875,
    "nativeCallMs": 2.6308194897959183,
    "valid": true
  },
  {
    "label": "after",
    "os": "android",
    "round": 2,
    "width": 600,
    "height": 800,
    "wallMs": 8005.189,
    "frames": 235,
    "fps": 29.355958991099396,
    "cpuPercent": 48.11690267400308,
    "peakRssMiB": 452.6015625,
    "nativeCallMs": 10.68827571914894,
    "valid": true
  },
  {
    "label": "after",
    "os": "android",
    "round": 3,
    "width": 600,
    "height": 800,
    "wallMs": 8005.109,
    "frames": 235,
    "fps": 29.356252363334463,
    "cpuPercent": 51.375840104113514,
    "peakRssMiB": 446.76953125,
    "nativeCallMs": 11.572749570212784,
    "valid": true
  },
  {
    "label": "before",
    "os": "macos",
    "round": 1,
    "width": 600,
    "height": 800,
    "wallMs": 516003.708,
    "frames": 92,
    "fps": 0.17829329241951883,
    "cpuPercent": 0.3237106582962772,
    "peakRssMiB": 459.46875,
    "nativeCallMs": 5.920796648534514,
    "valid": false
  },
  {
    "label": "before",
    "os": "macos",
    "round": 2,
    "width": 600,
    "height": 800,
    "wallMs": 8012.378,
    "frames": 243,
    "fps": 30.328074886132434,
    "cpuPercent": 21.178469113663883,
    "peakRssMiB": 431.625,
    "nativeCallMs": 5.630163408822987,
    "valid": true
  },
  {
    "label": "before",
    "os": "macos",
    "round": 3,
    "width": 600,
    "height": 800,
    "wallMs": 8015.323,
    "frames": 243,
    "fps": 30.316931706931832,
    "cpuPercent": 20.39827964512472,
    "peakRssMiB": 434.5625,
    "nativeCallMs": 5.568585219403653,
    "valid": true
  },
  {
    "label": "after",
    "os": "macos",
    "round": 1,
    "width": 600,
    "height": 800,
    "wallMs": 8202.422,
    "frames": 73,
    "fps": 8.899810324316402,
    "cpuPercent": 5.013555752191243,
    "peakRssMiB": 447.3125,
    "nativeCallMs": 2.1901192924578687,
    "valid": false
  },
  {
    "label": "after",
    "os": "macos",
    "round": 2,
    "width": 600,
    "height": 800,
    "wallMs": 8012.102,
    "frames": 243,
    "fps": 30.32911962428836,
    "cpuPercent": 19.78382202323435,
    "peakRssMiB": 438.921875,
    "nativeCallMs": 3.73307047323919,
    "valid": true
  },
  {
    "label": "after",
    "os": "macos",
    "round": 3,
    "width": 600,
    "height": 800,
    "wallMs": 8015.003,
    "frames": 243,
    "fps": 30.318142114232522,
    "cpuPercent": 21.67283031584642,
    "peakRssMiB": 447.984375,
    "nativeCallMs": 3.6876752400092774,
    "valid": true
  }
]
```

</details>
