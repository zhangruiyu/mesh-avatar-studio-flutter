import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_avatar_studio/mesh_avatar_studio.dart';

class DelayedBundle extends CachingAssetBundle {
  final result = Completer<ByteData>();
  @override
  Future<ByteData> load(String key) => result.future;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mesh_avatar_studio');
  late List<MethodCall> calls;
  late MeshAvatarController controller;
  Future<Object?> reply(MethodCall call) async {
    calls.add(call);
    if (call.method == 'load') return {'textureId': 42};
    if (call.method == 'stats') {
      return {
        'loaded': true,
        'frames': 12,
        'renderMs': 3.5,
        'paused': false,
        'speaking': false
      };
    }
    return null;
  }

  setUp(() {
    calls = [];
    controller = MeshAvatarController();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, reply);
  });
  tearDown(() async {
    await controller.close();
    controller.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
  test('同一引擎拒绝第二个角色，关闭后允许接管', () async {
    final other = MeshAvatarController();
    try {
      await controller.loadFile('/first.mavatar');
      await expectLater(other.loadFile('/second.mavatar'), throwsStateError);
      expect(calls.where((c) => c.method == 'load').length, 1);
      await controller.close();
      await other.loadFile('/second.mavatar');
      expect(other.isLoaded, isTrue);
    } finally {
      await other.close();
      other.dispose();
    }
  });
  test('正在加载时销毁，加载完成后仍释放纹理且不通知已销毁对象', () async {
    final gate = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'load') await gate.future;
      return reply(call);
    });
    final loading = controller.loadFile('/first.mavatar');
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    gate.complete();
    await loading;
    await controller.close();
    expect(controller.textureId, isNull);
    expect(calls.map((c) => c.method), ['load', 'dispose']);
  });
  test('加载失败会释放占用，后续加载可以恢复', () async {
    var fail = true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'load' && fail) {
        fail = false;
        throw PlatformException(code: 'bad_model');
      }
      return reply(call);
    });
    await expectLater(
        controller.loadFile('/bad.mavatar'), throwsA(isA<PlatformException>()));
    expect(controller.lastError, isA<PlatformException>());
    expect(controller.isLoaded, isFalse);
    await controller.loadFile('/good.mavatar');
    expect(controller.isLoaded, isTrue);
    expect(controller.lastError, isNull);
  });
  test('字节在排队前复制，旧资源不会覆盖新加载', () async {
    final bundle = DelayedBundle();
    final first = controller.loadAsset('first', bundle: bundle);
    final bytes = Uint8List.fromList([7, 8, 9]);
    final second = controller.loadBytes(bytes);
    bytes[0] = 99;
    bundle.result.complete(ByteData.sublistView(Uint8List.fromList([1, 2])));
    await Future.wait([first, second]);
    final loads = calls.where((c) => c.method == 'load').toList();
    expect(loads[0].arguments['bytes'], [1, 2]);
    expect(loads[1].arguments['bytes'], [7, 8, 9]);
    expect(calls.map((c) => c.method),
        ['load', 'pause', 'dispose', 'load', 'pause']);
  });
  test('未加载与非法音量不会访问原生资源', () async {
    await expectLater(controller.setSpeaking(true), throwsStateError);
    for (final value in [-0.1, 1.1, double.nan, double.infinity]) {
      expect(() => controller.setVoiceLevel(value), throwsArgumentError);
    }
    expect(() => controller.loadFile(' '), throwsArgumentError);
    expect(() => controller.loadBytes(Uint8List(0)), throwsArgumentError);
    expect(calls, isEmpty);
  });
  test('真实音量与演示口型使用独立命令', () async {
    await controller.loadFile('/model.mavatar');
    calls.clear();
    await controller.setSpeaking(true);
    await controller.setVoiceLevel(0.6);
    await controller.setMouthDemo(true);
    expect(calls.map((c) => c.method), ['speaking', 'voiceLevel', 'mouthDemo']);
    expect(calls[1].arguments['level'], 0.6);
  });
  test('切回前台保留主动暂停', () async {
    await controller.loadFile('/model.mavatar');
    await controller.setPaused(true);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.arguments['paused'], true);
    expect(controller.isLoaded, isTrue);
    await controller.setPaused(false);
    expect(calls.last.arguments['paused'], false);
  });
  test('生命周期回调不会覆盖尚在队列里的主动暂停', () async {
    await controller.loadFile('/model.mavatar');
    final pausing = controller.setPaused(true);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pausing;
    await controller.getStats();
    final pauses = calls.where((c) => c.method == 'pause').toList();
    expect(pauses.last.arguments['paused'], true);
  });
}
