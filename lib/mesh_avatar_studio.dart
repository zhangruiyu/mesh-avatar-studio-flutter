/// Mesh Avatar Studio 的 Flutter 原生播放器，不依赖 WebView。
library;

import 'dart:async';
import 'dart:convert';
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
enum MeshAvatarMotion {
  nod,
  no,
  sway,
  greet,
  tilt,
  think,
  giggle,
  surprise,
  shy,
  wink,
  lookAround,
  glance,
  sigh,
  doze,
  stretch,
  lean,
  hum,
  tap,
  readNote,
  waiting,
  spaceOut
}

/// 情绪驱动与素材表情独立，可同时使用。
enum MeshAvatarEmotion { neutral, happy, sad, angry, surprised, relaxed }

/// 固定元音；n 表示闭口。
enum MeshAvatarVowel { a, i, u, e, o, n }

/// 当前运行库可播放的动作信息，时长单位为秒。
@immutable
class MeshAvatarMotionInfo {
  const MeshAvatarMotionInfo(
      {required this.id,
      required this.label,
      required this.duration,
      required this.idle});
  final String id;
  final String label;
  final double duration;
  final bool idle;
}

/// 原生参数的取值范围，使用 id 传给 setParameters。
@immutable
class MeshAvatarParameter {
  const MeshAvatarParameter(
      {required this.id,
      required this.label,
      required this.min,
      required this.max,
      required this.defaultValue,
      required this.group});
  final String id;
  final String label;
  final double min;
  final double max;
  final double defaultValue;
  final String group;
}

/// 运行库能力及当前模型实际拥有的配饰、衣物。
@immutable
class MeshAvatarMetadata {
  MeshAvatarMetadata._(Map<String, dynamic> data)
      : motions = List.unmodifiable((data['motions'] as List).map((m) =>
            MeshAvatarMotionInfo(
                id: m['id'],
                label: m['label'],
                duration: (m['duration'] as num).toDouble(),
                idle: m['idle']))),
        parameters = List.unmodifiable((data['parameters'] as List).map((p) =>
            MeshAvatarParameter(
                id: p['id'],
                label: p['label'],
                min: (p['min'] as num).toDouble(),
                max: (p['max'] as num).toDouble(),
                defaultValue: (p['def'] as num).toDouble(),
                group: p['group']))),
        overlays = List<String>.unmodifiable(data['overlays'] as List),
        garments = List<String>.unmodifiable(data['garments'] as List);
  final List<MeshAvatarMotionInfo> motions;
  final List<MeshAvatarParameter> parameters;
  final List<String> overlays;
  final List<String> garments;
}

/// 口型灵敏度、张口幅度及闭口速度，均为 0..1；省略字段保持原值。
@immutable
class MeshAvatarLipSyncSettings {
  const MeshAvatarLipSyncSettings(
      {this.granularity, this.openness, this.closeSpeed});
  final double? granularity;
  final double? openness;
  final double? closeSpeed;
  Map<String, double> _values() => {
        if (granularity != null) 'granularity': granularity!,
        if (openness != null) 'openness': openness!,
        if (closeSpeed != null) 'closeSpeed': closeSpeed!,
      };
}

/// 当前原生运行状态；parameters 是最近一帧结果，overrides 是手动覆盖值。
@immutable
class MeshAvatarState {
  MeshAvatarState._(Map<String, dynamic> data)
      : parameters = Map.unmodifiable((data['parameters'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num?)?.toDouble()))),
        overrides = Map.unmodifiable((data['overrides'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toDouble()))),
        clothTuning = Map.unmodifiable((data['clothTuning'] as Map).map(
            (k, v) => MapEntry(
                k as String,
                Map<String, double>.unmodifiable((v as Map).map(
                    (k, v) => MapEntry(k as String, (v as num).toDouble())))))),
        weight = (data['weight'] as num).toDouble(),
        motion = data['motion'] as String?,
        expression = data['expression'] as String,
        emotionExpression = data['emotion'] as String,
        expressionActive = data['expressionActive'] as bool,
        autoIdle = data['autoIdle'] as bool,
        autoMotion = data['autoMotion'] as bool,
        talkGain = (data['talkGain'] as num).toDouble(),
        swayGain = (data['swayGain'] as num).toDouble(),
        speaking = data['speaking'] as bool,
        lipSync = MeshAvatarLipSyncSettings(
            granularity: (data['lipSync']['granularity'] as num).toDouble(),
            openness: (data['lipSync']['openness'] as num).toDouble(),
            closeSpeed: (data['lipSync']['closeSpeed'] as num).toDouble()),
        lipSyncActive = data['mouth']['active'] as bool,
        mouthOpen = (data['mouth']['open'] as num).toDouble(),
        mouthForm = (data['mouth']['form'] as num).toDouble(),
        overlays = List<String>.unmodifiable(data['overlays'] as List);
  final Map<String, double?> parameters;
  final Map<String, double> overrides;

  /// 每件衣物当前使用的物理参数。
  final Map<String, Map<String, double>> clothTuning;
  final double weight;
  final String? motion;
  final String expression;

  /// 底层情绪混合名，如 happyTalk；它不是素材表情名。
  final String emotionExpression;
  final bool expressionActive;
  final bool autoIdle;
  final bool autoMotion;
  final double talkGain;
  final double swayGain;
  final bool speaking;
  final MeshAvatarLipSyncSettings lipSync;
  final bool lipSyncActive;
  final double mouthOpen;
  final double mouthForm;
  final List<String> overlays;
}

/// 原生动作变化通知；id 为 null 表示动作结束，包含自动动作。
@immutable
class MeshAvatarMotionEvent {
  const MeshAvatarMotionEvent(this.id);
  final String? id;
}

/// 原生绘制状态；renderMilliseconds 为 CPU 准备和提交耗时，并非纯 GPU 时间。
/// GPU 直接输出后不再包含同步像素回读等待，不能单靠它推算 GPU 性能。
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
  Timer? _motionTimer;
  bool _pollingMotion = false;
  late final StreamController<MeshAvatarMotionEvent> _motionEvents =
      StreamController<MeshAvatarMotionEvent>.broadcast(
    onListen: () {
      _motionTimer =
          Timer.periodic(const Duration(milliseconds: 100), (_) async {
        // 上一次查询未完成时不继续排队，避免慢设备无限积压。
        if (_pollingMotion || _disposed || !isLoaded || isLoading) return;
        _pollingMotion = true;
        try {
          await getState();
        } catch (e, stack) {
          if (!_disposed) _motionEvents.addError(e, stack);
        } finally {
          _pollingMotion = false;
        }
      });
    },
    onCancel: () {
      _motionTimer?.cancel();
      _motionTimer = null;
    },
  );

  /// 有订阅者时每 100ms 读取原生事件；最近最多保留 256 次变化。
  /// 暂停时不产生新帧事件，重新加载会开始新的事件队列。
  Stream<MeshAvatarMotionEvent> get motionEvents => _motionEvents.stream;
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

  /// 从宿主 App 自己声明的 asset 加载；插件不自动指定角色，官方 Miko 资源仅由 example 声明。
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

  // 仅内部传输使用 JSON；先序列化冻结请求，避免调用者在排队期间修改 Map/List。
  Future<dynamic> _control(Map<String, Object?> request,
      {bool stopVoice = false}) {
    _checkOpen();
    // JNI 的输入字符串采用 ASCII JSON，完整保留代理对与所有 Unicode 文本。
    final encoded = jsonEncode(request).replaceAllMapped(
        RegExp(r'[^\x00-\x7F]'),
        (m) => m[0]!
            .codeUnits
            .map((u) => '\\u${u.toRadixString(16).padLeft(4, '0')}')
            .join());
    if (encoded.length > 65536) throw ArgumentError('控制请求不能超过 64 KiB');
    return _enqueue(() async {
      _checkOpen();
      if (_active != this || !isLoaded) throw StateError('请先加载角色');
      try {
        if (stopVoice) {
          await _channel.invokeMethod<void>('mouthDemo', {'enabled': false});
        }
        final result = await _channel
            .invokeMethod<String>('control', {'request': encoded});
        final data = jsonDecode(result!);
        if (request['method'] == 'state' && !_disposed) {
          for (final id in data['motionEvents'] as List) {
            _motionEvents.add(MeshAvatarMotionEvent(id as String?));
          }
        }
        return data;
      } catch (e) {
        _lastError = e;
        _changed();
        rethrow;
      }
    });
  }

  /// 查询动作、参数范围以及此模型实际配置的配饰和衣物。
  Future<MeshAvatarMetadata> getMetadata() async => MeshAvatarMetadata._(
      await _control({'method': 'metadata'}) as Map<String, dynamic>);

  /// 查询原生状态，同时把积压的动作变化发送到 motionEvents。
  Future<MeshAvatarState> getState() async => MeshAvatarState._(
      await _control({'method': 'state'}) as Map<String, dynamic>);

  /// 按原生动作 ID 播放，未知 ID 会返回平台错误。
  Future<void> playMotionById(String id) =>
      _control({'method': 'motion', 'name': id});

  /// 切换情绪，可选择不触发该情绪的默认动作。
  Future<void> setEmotion(MeshAvatarEmotion emotion,
          {bool playMotion = true}) =>
      _control({
        'method': 'emotion',
        'name': emotion.name,
        'playMotion': playMotion
      });

  /// 替换整批手动参数，不是增量合并。范围从 getMetadata 查询；weight 为 0..1。
  /// 头部 angleX/Y/Z、眼神 gazeX/Y 和口型 mouthOpen/mouthForm 均走此接口。
  Future<void> setParameters(Map<String, double> values, {double weight = 1}) {
    _range(weight, 'weight', 0, 1);
    for (final value in values.values) {
      if (!value.isFinite) throw ArgumentError('参数必须为有限数');
    }
    return _control(
        {'method': 'parameters', 'values': values, 'weight': weight});
  }

  /// 取消全部手动参数，交还给自动动作、呼吸和眨眼。
  Future<void> clearParameters() => setParameters({});

  /// 显示列表中的配饰；空列表隐藏全部，模型没有的名字按上游规则忽略。
  Future<void> setOverlays(List<String> names) =>
      _control({'method': 'overlays', 'names': names});

  /// 修改口型运行参数，未传的字段保持原值。
  Future<void> setLipSync(MeshAvatarLipSyncSettings settings) {
    final values = settings._values();
    for (final e in values.entries) {
      _range(e.value, e.key, 0, 1);
    }
    return _control({'method': 'lipSync', 'settings': values});
  }

  /// 无声音的假名口型序列。此接口不合成语音，也不把中文转为假名。
  /// speed 为每秒 4..12 拍，省略使用上游默认；自动退出音量/演示驱动。
  Future<void> speakKana(String text, {double? speed, bool loop = false}) {
    if (speed != null) _range(speed, 'speed', 4, 12);
    return _control(
        {'method': 'speakKana', 'text': text, 'speed': speed, 'loop': loop},
        stopVoice: true);
  }

  /// 固定元音口型，自动退出音量/演示驱动。
  Future<void> holdMouth(MeshAvatarVowel vowel) =>
      _control({'method': 'holdMouth', 'vowel': vowel.name}, stopVoice: true);

  /// 停止假名或固定元音；同时退出演示和音量驱动。
  Future<void> stopLipSync() =>
      _control({'method': 'stopLipSync'}, stopVoice: true);

  /// 自动呼吸、眨眼和视线等待机运动。
  Future<void> setAutoIdle(bool enabled) =>
      _control({'method': 'autoIdle', 'enabled': enabled});

  /// 是否自动挑选内置动作，不中断当前已播放的动作。
  Future<void> setAutoMotion(bool enabled) =>
      _control({'method': 'autoMotion', 'enabled': enabled});

  /// 说话带动身体的幅度，0 为关闭，默认 1；必须为非负有限数。
  Future<void> setTalkGain(double gain) {
    _range(gain, 'gain', 0, double.maxFinite);
    return _control({'method': 'talkGain', 'gain': gain});
  }

  /// 头发、配饰和衣物的物理摆动幅度，0 为关闭，默认 1。
  Future<void> setSwayGain(double gain) {
    _range(gain, 'gain', 0, double.maxFinite);
    return _control({'method': 'swayGain', 'gain': gain});
  }

  /// 局部更新衣物物理参数；name 省略表示全部衣物，不修改模型文件。
  /// 支持 responseGain、tierGain、highModeDamping、swing、stiffness、damping、
  /// follow、cohesion、wind、max。原生校验字段和范围，非法整批不生效。
  Future<void> setClothTuning(Map<String, double> values, {String? name}) {
    for (final value in values.values) {
      if (!value.isFinite) throw ArgumentError('衣物参数必须为有限数');
    }
    return _control({'method': 'cloth', 'name': name, 'values': values});
  }

  static void _range(double value, String name, double min, double max) {
    if (!value.isFinite || value < min || value > max) {
      throw ArgumentError.value(value, name, '需要 $min 到 $max 的有限数');
    }
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
    _motionTimer?.cancel();
    unawaited(_motionEvents.close());
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
