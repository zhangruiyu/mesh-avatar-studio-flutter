import Foundation
import MeshAvatarNative
import CoreVideo
import QuartzCore
import Metal
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

// Rust 负责动作和 Metal 绘制，Flutter 插件只接收原生纹理。
// Metal 直接绘制到 IOSurface；只将已经完成的共享缓冲区交给 Flutter。
public final class MeshAvatarStudioPlugin: NSObject, FlutterPlugin, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "dev.meshavatar.studio", qos: .userInitiated)
  private let pixelLock = NSLock()
  private var pixelBuffer: CVPixelBuffer?
  private var pool: CVPixelBufferPool?
  private var textureCache: CVMetalTextureCache?
  // GPU 完成前保留两层引用，防止池提前复用仍在写入的 IOSurface。
  private struct PendingFrame {
    let serial: UInt64
    let buffer: CVPixelBuffer
    let texture: CVMetalTexture
    let submitMs: Double
  }
  private var pendingFrames: [PendingFrame] = []
  private var timer: DispatchSourceTimer?
  private var avatar: UInt64 = 0
  private var renderer: UInt64 = 0
  private var textureId: Int64 = -1
  // 只在主线程访问，阻止加载结果在引擎关闭后重新注册纹理。
  private var detached = false
  private let width = 600
  private let height = 800
  private var paused = false
  private var speaking = false
  private var mouthDemo = false
  private var elapsed = 0.0
  private var lastTick = 0.0
  private var frames = 0
  private var renderTotal = 0.0
  private var expression = "neutral"

  public static func register(with registrar: FlutterPluginRegistrar) {
#if os(macOS)
    let channel = FlutterMethodChannel(name: "mesh_avatar_studio", binaryMessenger: registrar.messenger)
    let instance = MeshAvatarStudioPlugin(registry: registrar.textures, channel: channel)
#else
    let channel = FlutterMethodChannel(name: "mesh_avatar_studio", binaryMessenger: registrar.messenger())
    let instance = MeshAvatarStudioPlugin(registry: registrar.textures(), channel: channel)
#endif
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  init(registry: FlutterTextureRegistry, channel: FlutterMethodChannel) {
    self.registry = registry
    self.channel = channel
    super.init()
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    // Flutter 在光栅线程取图。提交后不再修改这张缓冲区，避免读写竞争。
    pixelLock.lock()
    defer { pixelLock.unlock() }
    return pixelBuffer.map { Unmanaged.passRetained($0) }
  }

  private func check(_ status: Int32) throws {
    if status != MA_OK {
      let message = mesh_avatar_last_error().map { String(cString: $0) } ?? "原生库返回错误 \(status)"
      throw NSError(domain: "MeshAvatar", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    // 所有资源操作串行执行，切换表情、销毁和下一帧不会同时进入原生句柄。
    queue.async {
      do {
        switch call.method {
        case "load":
          guard self.avatar == 0 else { throw NSError(domain: "MeshAvatar", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先释放旧角色"]) }
          if let bytes = arguments["bytes"] as? FlutterStandardTypedData {
            try self.check(bytes.data.withUnsafeBytes {
              mesh_avatar_open_bytes($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &self.avatar)
            })
          } else {
            let path = arguments["path"] as? String ?? ""
            guard !path.isEmpty else { throw NSError(domain: "MeshAvatar", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型路径不能为空"]) }
            try self.check(path.withCString { mesh_avatar_open_path($0, &self.avatar) })
          }
          var options = MaRenderOptions(width: UInt32(self.width), height: UInt32(self.height), samples: 1, fit: UInt32(MA_FIT_COVER), pad_top: 0.06, pad_side: 0.02)
          do {
            try self.check(mesh_avatar_gpu_create(self.avatar, &options, nil, &self.renderer))
            var devicePointer: UnsafeMutableRawPointer?
            try self.check(mesh_avatar_gpu_metal_device(self.renderer, &devicePointer))
            guard let devicePointer = devicePointer,
                  let device = Unmanaged<AnyObject>.fromOpaque(devicePointer).takeUnretainedValue() as? MTLDevice,
                  CVMetalTextureCacheCreate(nil, nil, device, nil, &self.textureCache) == kCVReturnSuccess else {
              throw NSError(domain: "MeshAvatar", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法建立共享 Metal 纹理缓存"])
            }
            let attributes: [String: Any] = [
              kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
              kCVPixelBufferWidthKey as String: self.width,
              kCVPixelBufferHeightKey as String: self.height,
              kCVPixelBufferMetalCompatibilityKey as String: true,
              kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &self.pool) == kCVReturnSuccess else {
              throw NSError(domain: "MeshAvatar", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法建立纹理缓冲池"])
            }
            self.frames = 0
            self.renderTotal = 0
            self.elapsed = 0
            self.paused = false
            self.speaking = false
            self.mouthDemo = false
            self.expression = "neutral"
            _ = try self.drawFrame(dt: 0)
          } catch {
            self.releaseNative()
            throw error
          }
          DispatchQueue.main.async {
            guard !self.detached else {
              result(FlutterError(code: "engine_closed", message: "Flutter 引擎已经关闭", details: nil))
              return
            }
            self.textureId = self.registry.register(self)
            self.registry.textureFrameAvailable(self.textureId)
            result(["textureId": self.textureId, "width": self.width, "height": self.height])
            self.queue.async { self.startTimer() }
          }
          return
        case "dispose":
          self.timer?.cancel()
          self.timer = nil
          self.releaseNative()
          DispatchQueue.main.async {
            if self.textureId >= 0 { self.registry.unregisterTexture(self.textureId) }
            self.textureId = -1
            result(nil)
          }
          return
        case "stats":
          let stats: [String: Any] = ["frames": self.frames, "renderMs": self.renderTotal / Double(max(1, self.frames)), "paused": self.paused, "speaking": self.speaking, "expression": self.expression, "loaded": self.avatar != 0]
          DispatchQueue.main.async { result(stats) }
          return
        default:
          guard self.avatar != 0 else { throw NSError(domain: "MeshAvatar", code: 3, userInfo: [NSLocalizedDescriptionKey: "角色尚未加载"]) }
          switch call.method {
          case "control":
            let request = arguments["request"] as? String ?? ""
            var output: UnsafeMutablePointer<CChar>?
            try self.check(request.withCString { mesh_avatar_control_json(self.avatar, $0, &output) })
            defer { mesh_avatar_free_string(output) }
            let value = String(cString: output!)
            DispatchQueue.main.async { result(value) }
            return
          case "expression":
            let name = arguments["name"] as? String ?? "neutral"
            try self.check(name.withCString { mesh_avatar_set_expression(self.avatar, $0) })
            self.expression = name
          case "speaking", "mouthDemo":
            if arguments["enabled"] as? Bool == true { try self.check(mesh_avatar_stop_lip_sync(self.avatar)) }
            self.mouthDemo = call.method == "mouthDemo" && (arguments["enabled"] as? Bool ?? false)
            self.speaking = arguments["enabled"] as? Bool ?? false
            try self.check(mesh_avatar_set_speaking(self.avatar, self.speaking ? 1 : 0))
            if !self.speaking { try self.check(mesh_avatar_set_voice_level(self.avatar, 0)) }
          case "voiceLevel":
            try self.check(mesh_avatar_set_voice_level(self.avatar, arguments["level"] as? Double ?? 0))
          case "pause":
            self.paused = arguments["paused"] as? Bool ?? false
            self.lastTick = CACurrentMediaTime()
          case "motion":
            let name = arguments["name"] as? String ?? "nod"
            try self.check(name.withCString { mesh_avatar_play(self.avatar, $0) })
          default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
            return
          }
        }
        DispatchQueue.main.async { result(nil) }
      } catch {
        let message = error.localizedDescription
        DispatchQueue.main.async { result(FlutterError(code: "native_avatar", message: message, details: nil)) }
      }
    }
  }

  private func startTimer() {
    guard avatar != 0 else { return }
    lastTick = CACurrentMediaTime()
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
    source.setEventHandler { [weak self] in
      guard let self = self, !self.paused, self.avatar != 0 else { return }
      autoreleasepool {
        do {
          let now = CACurrentMediaTime()
          let dt = min(0.05, now - self.lastTick)
          self.lastTick = now
          if try self.drawFrame(dt: dt) {
            DispatchQueue.main.async {
              if self.textureId >= 0 { self.registry.textureFrameAvailable(self.textureId) }
            }
          }
        } catch {
          self.timer?.cancel()
          self.timer = nil
          let message = error.localizedDescription
          DispatchQueue.main.async { self.channel.invokeMethod("renderError", arguments: message) }
        }
      }
    }
    timer = source
    source.resume()
  }

  private func drawFrame(dt: Double) throws -> Bool {
    let started = CACurrentMediaTime()
    var completed: UInt64 = 0
    try check(mesh_avatar_gpu_poll(renderer, &completed))
    var published = false
    while let frame = pendingFrames.first, frame.serial <= completed {
      pixelLock.lock()
      pixelBuffer = frame.buffer
      pixelLock.unlock()
      frames += 1
      renderTotal += frame.submitMs
      pendingFrames.removeFirst()
      published = true
    }
    elapsed += dt
    // 即使合成器暂时占用全部缓冲，动作时间仍继续推进；只跳过绘制。
    if mouthDemo {
      let level = max(0, sin(elapsed * 9)) * (0.35 + 0.45 * abs(sin(elapsed * 3.7)))
      try check(mesh_avatar_set_voice_level(avatar, level))
    }
    try check(mesh_avatar_tick(avatar, dt))
    guard pendingFrames.count < 2, let pool = pool, let cache = textureCache else { return published }
    // 三张全尺寸缓冲为上限。Flutter 仍持有的缓冲不会被池重用，也不无限扩容。
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
    var next: CVPixelBuffer?
    var status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &next)
    if status == kCVReturnWouldExceedAllocationThreshold {
      CVMetalTextureCacheFlush(cache, 0)
      status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &next)
    }
    if status == kCVReturnWouldExceedAllocationThreshold { return published }
    guard status == kCVReturnSuccess, let next = next else {
      throw NSError(domain: "MeshAvatar", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法分配共享角色纹理"])
    }
    var sharedTexture: CVMetalTexture?
    // 明确 renderTarget 用途，映射同一张 IOSurface；没有像素格式转换或 CPU 拷贝。
    let attributes = [kCVMetalTextureUsage as String: MTLTextureUsage.renderTarget.rawValue] as CFDictionary
    guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, next, attributes,
            .bgra8Unorm, width, height, 0, &sharedTexture) == kCVReturnSuccess,
          let sharedTexture = sharedTexture, let texture = CVMetalTextureGetTexture(sharedTexture) else {
      throw NSError(domain: "MeshAvatar", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法映射共享 Metal 纹理"])
    }
    var serial: UInt64 = 0
    try check(mesh_avatar_gpu_draw_metal(renderer, Unmanaged.passUnretained(texture as AnyObject).toOpaque(), &serial))
    pendingFrames.append(PendingFrame(serial: serial, buffer: next, texture: sharedTexture,
                                     submitMs: (CACurrentMediaTime() - started) * 1000))
    return published
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    detached = true
    // 引擎退出时也释放资源，不依赖业务页面一定执行 dispose。
    queue.async {
      self.timer?.cancel(); self.timer = nil
      self.releaseNative()
      DispatchQueue.main.async {
        if self.textureId >= 0 { self.registry.unregisterTexture(self.textureId) }
        self.textureId = -1
      }
    }
  }

  private func releaseNative() {
    // 渲染器引用角色，因此必须先释放渲染器，最后才释放角色句柄。
    if renderer != 0 { _ = mesh_avatar_gpu_destroy(renderer); renderer = 0 }
    if avatar != 0 { _ = mesh_avatar_destroy(avatar); avatar = 0 }
    pixelLock.lock()
    pixelBuffer = nil
    pixelLock.unlock()
    pendingFrames.removeAll()
    textureCache = nil
    pool = nil
  }
}
