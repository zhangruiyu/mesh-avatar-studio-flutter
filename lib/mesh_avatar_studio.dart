/// Mesh Avatar Studio 的 Flutter 原生播放器，不依赖 WebView。
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 上游运行库支持的表情。
enum MeshAvatarExpression {
  neutral,
  smile,
  shy,
  surprise,
  halfLidded,
  angry,
  sad,
  wink;
}

/// 上游运行库支持的内置动作。
enum MeshAvatarMotion { nod, no, sway, greet }

/// 原生绘制状态；renderMilliseconds 包含绘制与提交，并非纯 GPU 时间。
@immutable
class MeshAvatarStats {
  /// 从平台通道返回的数据构建状态。
  const MeshAvatarStats(
      {required this.loaded,
      required this.frames,
      required this.renderMilliseconds,
      required this.paused,
      required this.speaking});

  /// 原生模型是否存在。
  final bool loaded;

  /// 当前模型已提交的帧数，重新加载后归零。
  final int frames;

  /// 原生端记录的绘制与提交耗时，单位毫秒。
  final double renderMilliseconds;

  /// 原生帧循环是否暂停。
  final bool paused;

  /// 是否启用口型。
  final bool speaking;
}

/// 管理一个角色的原生纹理和动作。
///
/// 首版同一 Flutter 引擎/主 isolate 只能有一个活动控制器；不支持多引擎。
/// 换角色可在同一个控制器上再次调用 loadFile/loadBytes/loadAsset。
/// 页面销毁时调用 dispose；需要等待释放完毕时先 await close。
class MeshAvatarController extends ChangeNotifier with WidgetsBindingObserver {
  /// 创建控制器；默认跟随手机前后台暂停绘制。
  MeshAvatarController({this.pauseWhenBackground = true}) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const _channel = MethodChannel('mesh_avatar_studio');
  static MeshAvatarController? _active;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;
  bool _pausedByUser = false;
  bool _loading = false;
  int? _textureId;
  Object? _lastError;

  /// 为 true 时，后台自动停帧，回来后仍尊重用户主动暂停。
  final bool pauseWhenBackground;

  /// 是否正在加载模型。
  bool get isLoading => _loading;

  /// 是否已有可显示的原生纹理。
  bool get isLoaded => _textureId != null;

  /// 用户主动设置的暂停状态，不包含系统后台暂停。
  bool get isPaused => _pausedByUser;

  /// 最近一次加载、命令或绘制错误；成功重新加载后清除。
  Object? get lastError => _lastError;

  /// 当前原生纹理标识，通常直接使用 MeshAvatarView 即可。
  int? get textureId => _textureId;

  /// 当前版本的原生绘制尺寸。Widget 可按任意尺寸缩放。
  Size get renderSize => const Size(600, 800);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _checkOpen() {
    if (_disposed) throw StateError('控制器已经销毁');
  }

  // 先排队后访问原生资源。close / load / dispose 交错时也不会并行销毁句柄。
  Future<T> _enqueue<T>(Future<T> Function() work) {
    final operation = _pending.then((_) => work());
    _pending =
        operation.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return operation;
  }

  /// 从应用有权限读取的本地 .mavatar 文件或导出目录加载。
  Future<void> loadFile(String path) {
    _checkOpen();
    if (path.trim().isEmpty) throw ArgumentError.value(path, 'path', '路径不能为空');
    return _load({'path': path});
  }

  /// 从 .mavatar ZIP 字节加载。下载、缓存和鉴权由业务应用自行处理。
  Future<void> loadBytes(Uint8List bytes) {
    _checkOpen();
    if (bytes.isEmpty) throw ArgumentError('模型字节不能为空');
    // 在进入异步队列前复制，避免调用者修改缓冲区造成模型内容变化。
    return _load({'path': '', 'bytes': Uint8List.fromList(bytes)});
  }

  /// 从宿主 App 自己声明的 asset 加载；插件不携带任何角色图片或模型。
  Future<void> loadAsset(String key, {AssetBundle? bundle}) {
    _checkOpen();
    if (key.trim().isEmpty) throw ArgumentError('资源名称不能为空');
    // 资源读取也在同一队列里，防止较慢的旧资源覆盖后来加载的新角色。
    return _enqueue(() async {
      _checkOpen();
      final data = await (bundle ?? rootBundle).load(key);
      _checkOpen();
      await _loadNow({
        'path': '',
        'bytes': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
      });
    });
  }

  Future<void> _load(Map<String, Object> arguments) => _enqueue(() async {
        _checkOpen();
        await _loadNow(arguments);
      });

  Future<void> _loadNow(Map<String, Object> arguments) async {
    if (_active != null && _active != this) {
      throw StateError('首版只支持一个活动角色，请先 await 旧控制器.close()');
    }
    _active = this;
    _loading = true;
    _lastError = null;
    _changed();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'renderError') {
        _lastError = PlatformException(
            code: 'render_error', message: '${call.arguments}');
        _changed();
      }
    });
    try {
      if (_textureId != null) await _releaseTexture();
      final data =
          await _channel.invokeMapMethod<String, Object?>('load', arguments);
      _textureId = (data!['textureId'] as num).toInt();
      _pausedByUser = false;
      if (_disposed) {
        await _closeNow();
        return;
      }
      await _channel.invokeMethod<void>('pause', {'paused': _background});
    } catch (e) {
      _lastError = e;
      // 原生加载失败后仍显式释放，确保下一次加载可恢复。
      await _closeNow();
      rethrow;
    } finally {
      _loading = false;
      _changed();
    }
  }

  Future<void> _releaseTexture() async {
    await _channel.invokeMethod<void>('dispose');
    _textureId = null;
    _changed();
  }

  Future<void> _closeNow() async {
    if (_active != this) return;
    await _releaseTexture();
    _active = null;
    _channel.setMethodCallHandler(null);
  }

  /// 等待原生纹理、模型和帧循环释放；可重复调用，之后允许再次加载。
  Future<void> close() => _enqueue(_closeNow);

  Future<void> _command(String method, Map<String, Object> arguments) {
    _checkOpen();
    return _enqueue(() async {
      _checkOpen();
      if (_active != this || !isLoaded) throw StateError('请先加载角色');
      try {
        await _channel.invokeMethod<void>(method, arguments);
      } catch (e) {
        _lastError = e;
        _changed();
        rethrow;
      }
    });
  }

  /// 切换表情。
  Future<void> setExpression(MeshAvatarExpression expression) =>
      _command('expression', {'name': expression.name});

  /// 播放一次内置动作。
  Future<void> playMotion(MeshAvatarMotion motion) =>
      _command('motion', {'name': motion.name});

  /// 开启真实音量驱动口型；开启后由宿主持续调用 setVoiceLevel。
  Future<void> setSpeaking(bool enabled) =>
      _command('speaking', {'enabled': enabled});

  /// 设置 0 到 1 的归一化音量。插件不会播放声音，也不会申请录音权限。
  Future<void> setVoiceLevel(double level) {
    if (!level.isFinite || level < 0 || level > 1) {
      throw ArgumentError.value(level, 'level', '需要 0 到 1 的有限数');
    }
    return _command('voiceLevel', {'level': level});
  }

  /// 无声音的自动嘴型演示；真实 TTS 同步应使用 setSpeaking 和 setVoiceLevel。
  Future<void> setMouthDemo(bool enabled) =>
      _command('mouthDemo', {'enabled': enabled});

  bool get _background {
    if (!pauseWhenBackground) return false;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) return false;
    return !(defaultTargetPlatform == TargetPlatform.macOS &&
        state == AppLifecycleState.inactive);
  }

  /// 主动暂停或继续动作。恢复前台不会覆盖主动暂停状态。
  Future<void> setPaused(bool paused) {
    _checkOpen();
    return _enqueue(() async {
      _checkOpen();
      if (_active != this || !isLoaded) throw StateError('请先加载角色');
      await _channel
          .invokeMethod<void>('pause', {'paused': paused || _background});
      _pausedByUser = paused;
      _changed();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!pauseWhenBackground || !isLoaded || _disposed) return;
    // 在队列实际执行时读取暂停状态，避免较早的生命周期事件覆盖后来的手动暂停。
    unawaited(_enqueue(() async {
      if (_disposed || _active != this || !isLoaded) return;
      await _channel.invokeMethod<void>(
          'pause', {'paused': _pausedByUser || _background});
    }).catchError((Object e) {
      _lastError = e;
      _changed();
    }));
  }

  /// 查询帧数和原生耗时；不自动轮询，不给业务应用额外增加定时任务。
  Future<MeshAvatarStats> getStats() {
    _checkOpen();
    return _enqueue(() async {
      _checkOpen();
      if (_active != this) {
        return const MeshAvatarStats(
            loaded: false,
            frames: 0,
            renderMilliseconds: 0,
            paused: false,
            speaking: false);
      }
      final data = (await _channel.invokeMapMethod<String, Object?>('stats'))!;
      return MeshAvatarStats(
          loaded: data['loaded'] == true,
          frames: (data['frames'] as num).toInt(),
          renderMilliseconds: (data['renderMs'] as num).toDouble(),
          paused: data['paused'] == true,
          speaking: data['speaking'] == true);
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(close().catchError((Object e) {
      _lastError = e;
    }));
    super.dispose();
  }
}

/// 显示控制器的透明原生纹理；未加载时只保留透明空间。
///
/// Widget 不拥有控制器，不会在自身移除时替调用者销毁共享资源。
class MeshAvatarView extends StatelessWidget {
  /// 创建角色显示组件。
  const MeshAvatarView(
      {super.key,
      required this.controller,
      this.fit = BoxFit.contain,
      this.alignment = Alignment.center,
      this.filterQuality = FilterQuality.low});

  /// 需要由页面持有并在退出时 dispose 的角色控制器。
  final MeshAvatarController controller;

  /// 600 × 800 原生纹理在组件区域内的缩放方式。
  final BoxFit fit;

  /// 缩放后纹理的对齐方式。
  final Alignment alignment;

  /// Flutter 缩放纹理时采用的采样质量。
  final FilterQuality filterQuality;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final id = controller.textureId;
        if (id == null) return const SizedBox.expand();
        return ClipRect(
            child: FittedBox(
                fit: fit,
                alignment: alignment,
                child: SizedBox(
                  width: controller.renderSize.width,
                  height: controller.renderSize.height,
                  child: Texture(textureId: id, filterQuality: filterQuality),
                )));
      });
}
