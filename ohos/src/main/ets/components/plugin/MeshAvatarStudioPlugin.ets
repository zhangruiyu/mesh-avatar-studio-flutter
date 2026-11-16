import { FlutterPlugin, FlutterPluginBinding, MethodChannel, MethodCall,
  MethodCallHandler, MethodResult, TextureRegistry, SurfaceTextureEntry } from '@ohos/flutter_ohos';
import nativeAvatar from 'libavatar_bridge.so';

export default class MeshAvatarStudioPlugin implements FlutterPlugin, MethodCallHandler {
  // 鸿蒙底层首版是单实例；其他引擎不能释放或操作当前引擎的角色。
  private static owner: MeshAvatarStudioPlugin | null = null;
  private channel: MethodChannel | null = null;
  private registry: TextureRegistry | null = null;
  private texture: SurfaceTextureEntry | null = null;
  private attached: boolean = false;
  // 所有加载和销毁顺序执行，避免后台加载完成后复活已释放的纹理。
  private pending: Promise<void> = Promise.resolve();

  getUniqueClassName(): string { return 'MeshAvatarStudioPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.attached = true;
    this.registry = binding.getTextureRegistry();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'mesh_avatar_studio');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.attached = false;
    this.channel?.setMethodCallHandler(null);
    this.pending = this.pending.then(() => { this.release(); this.registry = null; });
    this.channel = null;
  }
  private release(): void {
    // 必须先停绘制线程，再让 Flutter 注销原生窗口。
    if (MeshAvatarStudioPlugin.owner === this) {
      nativeAvatar.dispose();
      MeshAvatarStudioPlugin.owner = null;
    }
    if (this.texture !== null) {
      this.texture.release();
      this.texture = null;
    }
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.pending = this.pending.then(async () => {
      try {
        if (!this.attached) throw new Error('Flutter 引擎已经关闭');
        if (MeshAvatarStudioPlugin.owner !== null && MeshAvatarStudioPlugin.owner !== this) {
          throw new Error('首版只支持一个 Flutter 引擎中的活动角色');
        }
        switch (call.method) {
          case 'load': {
            this.release();
            const registry = this.registry;
            if (registry === null) throw new Error('纹理注册器尚未初始化');
            const texture = registry.registerTexture(registry.getTextureId());
            this.texture = texture;
            MeshAvatarStudioPlugin.owner = this;
            registry.setTextureBufferSize(texture.getTextureId(), 600, 800);
            const requestedPath = call.argument('path') as string;
            const bytes = call.argument('bytes') as Uint8Array | null;
            const buffer = bytes === null || bytes === undefined ? new ArrayBuffer(0) : new Uint8Array(bytes).buffer;
            try {
              await nativeAvatar.load(texture.getSurfaceId().toString(), requestedPath, buffer);
              if (!this.attached) throw new Error('加载过程中引擎已经关闭');
              result.success(new Map<string, number>([
                ['textureId', texture.getTextureId()], ['width', 600], ['height', 800]
              ]));
            } catch (e) { this.release(); throw e as Error; }
            break;
          }
          case 'dispose': this.release(); result.success(null); break;
          case 'stats': {
            const stats = nativeAvatar.stats();
            if (stats.error.length > 0) this.channel?.invokeMethod('renderError', stats.error);
            const data = new Map<string, boolean | number | string>();
            data.set('loaded', stats.loaded); data.set('frames', stats.frames);
            data.set('renderMs', stats.renderMs); data.set('paused', stats.paused);
            data.set('speaking', stats.speaking); data.set('expression', stats.expression);
            data.set('error', stats.error);
            result.success(data);
            break;
          }
          case 'expression':
          case 'motion':
            nativeAvatar.command(call.method, call.argument('name') as string);
            result.success(null); break;
          case 'voiceLevel':
            nativeAvatar.command(call.method, (call.argument('level') as number).toString());
            result.success(null); break;
          case 'mouthDemo':
          case 'speaking':
            nativeAvatar.command(call.method, (call.argument('enabled') as boolean).toString());
            result.success(null); break;
          case 'pause':
            nativeAvatar.command(call.method, (call.argument('paused') as boolean).toString());
            result.success(null); break;
          default: result.notImplemented(); break;
        }
      } catch (e) { result.error('NATIVE_AVATAR', (e as Error).message, null); }
    });
  }
}
