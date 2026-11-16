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


## 鸿蒙 0.1.0-dev.4

2026-11-16，VDE-AL00 / OpenHarmony-7.0.0.111 / ARM64 真机，Flutter oh-3.47.9-dev。基线为 `50a405a` 的鸿蒙桥接；同一官方 Miko、600 × 800、相同待机/口型/sway 设置，前后各三轮约 8 秒 Debug 采样。测试仍保持相同帧策略，未使用正式模式结果替代基线。

| 指标 | 优化前 | 最终优化后 |
| --- | ---: | ---: |
| 原生帧率 | 29.71 | 29.73 |
| 进程 CPU（单核为 100%） | 94.10 | 96.32 |
| RSS 采样峰值（MiB） | 408.52 | 435.92 |

本轮没有测到整进程 CPU 下降，内存峰值增加约 27 MiB；按图层保留 GPU 缓冲和上一份 CPU 网格需要空间。收益是减少重复上传和反复分配，不能据此宣称所有设备更省内存或更省电。帧率维持约 30，尚未覆盖长期温控和其他鸿蒙机型。

旧鸿蒙 `renderMs` 是最后一帧耗时，累计差分公式不适用；基线日志中该公式产生过负值，故全部排除旧 `nativeCallMs`，不计算耗时改善比例。新实现累计成功提交的帧耗时除以帧数，平均值包含动作计算、上传、绘制和 EGL 等待，排除限帧休眠、暂停及读取统计的锁等待。复测旧版需加 `--dart-define=BENCH_STATS_CUMULATIVE=false`。

| 阶段 | 轮次 | 帧/秒 | CPU % | RSS MiB | 本轮平均调用 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 优化前 | 1 | 29.44 | 94.10 | 408.52 | 不适用 |
| 优化前 | 2 | 29.80 | 97.44 | 353.68 | 不适用 |
| 优化前 | 3 | 29.71 | 91.33 | 353.21 | 不适用 |
| 优化后 | 1 | 29.73 | 92.92 | 435.92 | 22.60 |
| 优化后 | 2 | 29.73 | 96.32 | 383.98 | 23.76 |
| 优化后 | 3 | 29.81 | 97.24 | 386.05 | 23.78 |

缓存回归使用一个静态三角形连续 101 帧，旧逐帧路径需 303 次上传、6060 字节；新缓存实际记录为 3 次上传、60 字节。此为可复现的调用/字节验证，不是真机速度提升比例。另验证同长度内容变化、容量增长/缩小复用、图层重排、透明保留、退出释放、1000 帧动态更新及清空重建，AddressSanitizer / UndefinedBehaviorSanitizer 均通过。

真机示例交互曾触发 `GL_OUT_OF_MEMORY`。用原提交桥接复测也同样失败；逐阶段检查定位到清屏取得窗口缓冲，而非网格上传。原窗口请求仅等 100ms，复杂 Flutter 页面短暂延迟消费时会失败。放宽到有上限的 1000ms 后，同一示例交互和最终组合回归通过；没有忽略 GL 错误，也没有保留逐调用诊断开销。消费者持续不可用时，关闭最多可能等待该缓冲请求超时。
