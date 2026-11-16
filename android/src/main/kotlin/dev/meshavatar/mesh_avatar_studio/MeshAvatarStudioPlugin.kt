package dev.meshavatar.mesh_avatar_studio

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

// 独立样品桥接：Flutter 只发控制指令，所有模型计算、GPU 绘制和像素提交都在后台线程。
class MeshAvatarStudioPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object { init { System.loadLibrary("mesh_avatar_bridge") } }
    private val thread = HandlerThread("角色原生绘制").apply { start() }
    private val worker = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private lateinit var channel: MethodChannel
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var handle = 0L
    private var paused = false
    private var speaking = false
    private var expression = "neutral"
    private var lastTick = 0L
    private var detached = false

    private external fun nativeCreate(path: String, bytes: ByteArray?): Long
    private external fun nativeSurface(handle: Long, surface: Surface?)
    private external fun nativeRender(handle: Long, dt: Double): Boolean
    private external fun nativeControl(handle: Long, request: String): String
    private external fun nativeCommand(handle: Long, method: String, value: String)
    private external fun nativeStats(handle: Long): DoubleArray
    private external fun nativeDestroy(handle: Long)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, "mesh_avatar_studio")
        channel.setMethodCallHandler(this)
    }

    private val frame = object : Runnable {
        override fun run() {
            if (handle == 0L) return
            val started = SystemClock.elapsedRealtimeNanos()
            try {
                if (!paused) {
                    val dt = ((started - lastTick) / 1e9).coerceIn(0.0, 0.05)
                    nativeRender(handle, dt)
                }
                lastTick = started
                val spent = (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000
                worker.postDelayed(this, (33L - spent).coerceAtLeast(1L))
            } catch (error: Exception) {
                Log.e("MeshAvatarStudio", "原生绘制失败", error)
                main.post { channel.invokeMethod("renderError", error.message) }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "load") {
            // SurfaceProducer 使用 Flutter 的原生纹理接口，可跟随 Impeller 和安卓后台回收。
            if (producer != null) { result.error("native_avatar", "请先释放旧角色", null); return }
            val surfaceProducer = binding.textureRegistry.createSurfaceProducer()
            surfaceProducer.setSize(600, 800)
            producer = surfaceProducer
            surfaceProducer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    if (producer !== surfaceProducer || detached) return
                    val surface = surfaceProducer.surface
                    worker.post {
                        if (handle != 0L) {
                            try { nativeSurface(handle, surface) }
                            catch (error: Exception) { main.post { channel.invokeMethod("renderError", error.message) } }
                        }
                    }
                }
                override fun onSurfaceCleanup() {
                    if (producer !== surfaceProducer || detached) return
                    // 后台 Surface 可能被系统销毁；不能在恢复时继续使用旧窗口。
                    worker.post {
                        if (handle != 0L) {
                            // GPU 异常后的清理也可能失败，不能让异常逃出工作线程导致进程退出。
                            try { nativeSurface(handle, null) }
                            catch (error: Exception) { main.post { channel.invokeMethod("renderError", error.message) } }
                        }
                    }
                }
            })
            val initialSurface = surfaceProducer.surface
            val path = call.argument<String>("path").orEmpty()
            val bytes = call.argument<ByteArray>("bytes")
            worker.post {
                try {
                    handle = nativeCreate(path, bytes)
                    nativeSurface(handle, initialSurface)
                    paused = false
                    speaking = false
                    expression = "neutral"
                    nativeRender(handle, 0.0)
                    lastTick = SystemClock.elapsedRealtimeNanos()
                    worker.post(frame)
                    main.post { result.success(mapOf("textureId" to surfaceProducer.id(), "width" to 600, "height" to 800)) }
                } catch (error: Exception) {
                    releaseNative()
                    main.post {
                        surfaceProducer.release()
                        producer = null
                        result.error("native_avatar", error.message, null)
                    }
                }
            }
            return
        }
        if (call.method == "dispose") {
            val oldProducer = producer
            producer = null
            worker.post {
                releaseNative()
                main.post { oldProducer?.release(); result.success(null) }
            }
            return
        }
        worker.post {
            try {
                if (call.method == "stats") {
                    val stats = if (handle != 0L) nativeStats(handle) else doubleArrayOf(0.0, 0.0)
                    val values = mapOf("loaded" to (handle != 0L), "frames" to stats[0].toLong(), "renderMs" to stats[1], "paused" to paused, "speaking" to speaking, "expression" to expression)
                    main.post { result.success(values) }
                    return@post
                }
                check(handle != 0L) { "角色尚未加载" }
                if (call.method == "control") {
                    val value = nativeControl(handle, call.argument<String>("request") ?: "")
                    main.post { result.success(value) }
                    return@post
                }
                when (call.method) {
                    "expression" -> {
                        val name = call.argument<String>("name") ?: "neutral"
                        nativeCommand(handle, "expression", name)
                        expression = name
                    }
                    "speaking", "mouthDemo" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        nativeCommand(handle, call.method, enabled.toString())
                        speaking = enabled
                    }
                    "voiceLevel" -> nativeCommand(handle, "voiceLevel", (call.argument<Double>("level") ?: 0.0).toString())
                    "motion" -> nativeCommand(handle, "motion", call.argument<String>("name") ?: "nod")
                    "pause" -> {
                        paused = call.argument<Boolean>("paused") ?: false
                        lastTick = SystemClock.elapsedRealtimeNanos()
                    }
                    else -> { main.post { result.notImplemented() }; return@post }
                }
                main.post { result.success(null) }
            } catch (error: Exception) {
                main.post { result.error("native_avatar", error.message, null) }
            }
        }
    }

    private fun releaseNative() {
        worker.removeCallbacks(frame)
        if (handle != 0L) { nativeDestroy(handle); handle = 0L }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached = true
        channel.setMethodCallHandler(null)
        val oldProducer = producer
        producer = null
        worker.post {
            releaseNative()
            main.post { oldProducer?.release() }
            thread.quitSafely()
        }
    }
}
