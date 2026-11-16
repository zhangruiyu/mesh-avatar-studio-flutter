import Foundation
import MeshAvatarNative
import CoreVideo
import QuartzCore
import Accelerate
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

// Rust 负责动作和 Metal 绘制，Flutter 插件只接收原生纹理。
// 上游目前提供同步像素回读，所以暂用后台队列回读；这不是零拷贝正式方案。
public final class MeshAvatarStudioPlugin: NSObject, FlutterPlugin, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "dev.meshavatar.studio", qos: .userInitiated)
  private let pixelLock = NSLock()
  private var pixelBuffer: CVPixelBuffer?
  private var pool: CVPixelBufferPool?
  private var timer: DispatchSourceTimer?
  private var avatar: UInt64 = 0
  private var renderer: UInt64 = 0
  private var textureId: Int64 = -1
  // 只在主线程访问，阻止加载结果在引擎关闭后重新注册纹理。
  private var detached = false
  private let width = 600
  private let height = 800
  private var rgba = [UInt8](repeating: 0, count: 600 * 800 * 4)
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
            try self.check(mesh_avatar_renderer_create(self.avatar, &options, &self.renderer))
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
            try self.drawFrame(dt: 0)
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
          case "expression":
            let name = arguments["name"] as? String ?? "neutral"
            try self.check(name.withCString { mesh_avatar_set_expression(self.avatar, $0) })
            self.expression = name
          case "speaking", "mouthDemo":
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
          try self.drawFrame(dt: dt)
          DispatchQueue.main.async {
            if self.textureId >= 0 { self.registry.textureFrameAvailable(self.textureId) }
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

  private func drawFrame(dt: Double) throws {
    let started = CACurrentMediaTime()
    elapsed += dt
    // 本按钮只是无声口型演示；正式接语音时应传真实音量，不能把它当语音同步。
    if mouthDemo {
      let level = max(0, sin(elapsed * 9)) * (0.35 + 0.45 * abs(sin(elapsed * 3.7)))
      try check(mesh_avatar_set_voice_level(avatar, level))
    }
    try check(mesh_avatar_tick(avatar, dt))
    let status = rgba.withUnsafeMutableBufferPointer {
      mesh_avatar_renderer_render(renderer, $0.baseAddress, $0.count, UInt32(MA_RGBA_PREMULTIPLIED))
    }
    try check(status)
    guard let pool = pool else { return }
    var next: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &next) == kCVReturnSuccess, let next = next else {
      throw NSError(domain: "MeshAvatar", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法分配角色纹理"])
    }
    CVPixelBufferLockBaseAddress(next, [])
    // 原生库输出 RGBA，而 Flutter Apple 纹理要求 BGRA；保留预乘透明度。
    rgba.withUnsafeMutableBytes { raw in
      var source = vImage_Buffer(data: raw.baseAddress!, height: UInt(height), width: UInt(width), rowBytes: width * 4)
      var target = vImage_Buffer(data: CVPixelBufferGetBaseAddress(next)!, height: UInt(height), width: UInt(width), rowBytes: CVPixelBufferGetBytesPerRow(next))
      let order: [UInt8] = [2, 1, 0, 3]
      _ = vImagePermuteChannels_ARGB8888(&source, &target, order, vImage_Flags(kvImageNoFlags))
    }
    CVPixelBufferUnlockBaseAddress(next, [])
    pixelLock.lock()
    pixelBuffer = next
    pixelLock.unlock()
    frames += 1
    renderTotal += (CACurrentMediaTime() - started) * 1000
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
    if renderer != 0 { _ = mesh_avatar_renderer_destroy(renderer); renderer = 0 }
    if avatar != 0 { _ = mesh_avatar_destroy(avatar); avatar = 0 }
    pixelLock.lock()
    pixelBuffer = nil
    pixelLock.unlock()
    pool = nil
  }
}
