#include <jni.h>
#include <android/native_window_jni.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include "mesh_avatar_render.h"

// 这个对象只由 Kotlin 的同一个后台线程访问，销毁和绘制不会并发。
struct Avatar {
  MaHandle model = 0;
  MaRenderer renderer = 0;
  ANativeWindow* window = nullptr;
  std::vector<uint8_t> rgba = std::vector<uint8_t>(600 * 800 * 4);
  double elapsed = 0;
  double renderMs = 0;
  uint64_t frames = 0;
  bool speaking = false;
  bool mouthDemo = false;
  ~Avatar() {
    if (window) ANativeWindow_release(window);
    // 渲染器持有模型引用，销毁顺序不能倒过来。
    if (renderer) mesh_avatar_renderer_destroy(renderer);
    if (model) mesh_avatar_destroy(model);
  }
};

static void check(MaStatus status) {
  if (status != MA_OK) throw std::runtime_error(mesh_avatar_last_error());
}
static void report(JNIEnv* env, const std::exception& error) {
  env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), error.what());
}
static Avatar& get(jlong handle) {
  if (!handle) throw std::runtime_error("角色尚未加载");
  return *reinterpret_cast<Avatar*>(handle);
}
static std::string stringValue(JNIEnv* env, jstring value) {
  if (!value) return "";
  const char* text = env->GetStringUTFChars(value, nullptr);
  if (!text) throw std::runtime_error("无法读取原生参数");
  std::string result(text);
  env->ReleaseStringUTFChars(value, text);
  return result;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_meshavatar_mesh_1avatar_1studio_MeshAvatarStudioPlugin_nativeCreate(JNIEnv* env, jobject, jstring path, jbyteArray bytes) {
  try {
    auto avatar = std::make_unique<Avatar>();
    if (bytes) {
      const auto size = env->GetArrayLength(bytes);
      std::vector<uint8_t> data(size);
      env->GetByteArrayRegion(bytes, 0, size, reinterpret_cast<jbyte*>(data.data()));
      if (env->ExceptionCheck()) return 0;
      check(mesh_avatar_open_bytes(data.data(), data.size(), &avatar->model));
    } else {
      const auto file = stringValue(env, path);
      if (file.empty()) throw std::runtime_error("模型路径不能为空");
      check(mesh_avatar_open_path(file.c_str(), &avatar->model));
    }
    MaRenderOptions options{600, 800, 1, MA_FIT_COVER, 0.06, 0.02};
    check(mesh_avatar_renderer_create(avatar->model, &options, &avatar->renderer));
    return reinterpret_cast<jlong>(avatar.release());
  } catch (const std::exception& error) { report(env, error); return 0; }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_meshavatar_mesh_1avatar_1studio_MeshAvatarStudioPlugin_nativeSurface(JNIEnv* env, jobject, jlong handle, jobject surface) {
  try {
    auto& avatar = get(handle);
    if (avatar.window) { ANativeWindow_release(avatar.window); avatar.window = nullptr; }
    if (surface) {
      avatar.window = ANativeWindow_fromSurface(env, surface);
      if (!avatar.window || ANativeWindow_setBuffersGeometry(avatar.window, 600, 800, WINDOW_FORMAT_RGBA_8888) != 0) {
        throw std::runtime_error("无法建立安卓原生纹理窗口");
      }
    }
  } catch (const std::exception& error) { report(env, error); }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_meshavatar_mesh_1avatar_1studio_MeshAvatarStudioPlugin_nativeRender(JNIEnv* env, jobject, jlong handle, jdouble dt) {
  try {
    auto& avatar = get(handle);
    if (!avatar.window) return false;
    const auto started = std::chrono::steady_clock::now();
    avatar.elapsed += dt;
    if (avatar.mouthDemo) {
      const double level = std::max(0.0, std::sin(avatar.elapsed * 9)) * (0.35 + 0.45 * std::abs(std::sin(avatar.elapsed * 3.7)));
      check(mesh_avatar_set_voice_level(avatar.model, level));
    }
    check(mesh_avatar_tick(avatar.model, dt));
    check(mesh_avatar_renderer_render(avatar.renderer, avatar.rgba.data(), avatar.rgba.size(), MA_RGBA_PREMULTIPLIED));
    ANativeWindow_Buffer buffer{};
    const int status = ANativeWindow_lock(avatar.window, &buffer, nullptr);
    if (status != 0) throw std::runtime_error("安卓纹理窗口无法写入，错误码 " + std::to_string(status));
    // 上游输出 RGBA，安卓 Surface 也是 RGBA；逐行处理设备实际 stride，不假设紧密排列。
    if (buffer.width != 600 || buffer.height != 800 || buffer.stride < 600 || buffer.format != WINDOW_FORMAT_RGBA_8888) {
      ANativeWindow_unlockAndPost(avatar.window);
      throw std::runtime_error("安卓纹理尺寸或格式不匹配");
    }
    for (int y = 0; y < 800; ++y) {
      std::memcpy(static_cast<uint8_t*>(buffer.bits) + y * buffer.stride * 4, avatar.rgba.data() + y * 600 * 4, 600 * 4);
    }
    if (ANativeWindow_unlockAndPost(avatar.window) != 0) throw std::runtime_error("提交安卓纹理失败");
    avatar.frames++;
    avatar.renderMs += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    return true;
  } catch (const std::exception& error) { report(env, error); return false; }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_meshavatar_mesh_1avatar_1studio_MeshAvatarStudioPlugin_nativeCommand(JNIEnv* env, jobject, jlong handle, jstring method, jstring value) {
  try {
    auto& avatar = get(handle);
    const auto name = stringValue(env, method);
    const auto argument = stringValue(env, value);
    if (name == "expression") check(mesh_avatar_set_expression(avatar.model, argument.c_str()));
    else if (name == "motion") check(mesh_avatar_play(avatar.model, argument.c_str()));
    else if (name == "voiceLevel") check(mesh_avatar_set_voice_level(avatar.model, std::stod(argument)));
    else if (name == "speaking" || name == "mouthDemo") {
      if (argument == "true") check(mesh_avatar_stop_lip_sync(avatar.model));
      avatar.mouthDemo = name == "mouthDemo" && argument == "true";
      avatar.speaking = argument == "true";
      check(mesh_avatar_set_speaking(avatar.model, avatar.speaking ? 1 : 0));
      if (!avatar.speaking) check(mesh_avatar_set_voice_level(avatar.model, 0));
    } else throw std::runtime_error("不支持的原生操作");
  } catch (const std::exception& error) { report(env, error); }
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_dev_meshavatar_mesh_1avatar_1studio_MeshAvatarStudioPlugin_nativeStats(JNIEnv* env, jobject, jlong handle) {
  try {
    auto& avatar = get(handle);
    double values[] = {static_cast<double>(avatar.frames), avatar.renderMs / std::max<uint64_t>(1, avatar.frames)};
    auto result = env->NewDoubleArray(2);
    env->SetDoubleArrayRegion(result, 0, 2, values);
    return result;
  } catch (const std::exception& error) { report(env, error); return nullptr; }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_meshavatar_mesh_1avatar_1studio_MeshAvatarStudioPlugin_nativeDestroy(JNIEnv*, jobject, jlong handle) {
  delete reinterpret_cast<Avatar*>(handle);
}

// 字符串在此复制回 JVM，不能把 Rust 分配的内存留给 Java 释放。
extern "C" JNIEXPORT jstring JNICALL
Java_dev_meshavatar_mesh_1avatar_1studio_MeshAvatarStudioPlugin_nativeControl(JNIEnv* env, jobject, jlong handle, jstring request) {
  try {
    const auto input = stringValue(env, request);
    char* output = nullptr;
    check(mesh_avatar_control_json(get(handle).model, input.c_str(), &output));
    // JSON 的非 ASCII 文本由 Dart 按 Unicode 转义传入，输出转为 UTF-16，避免 JNI Modified UTF-8 限制。
    jbyteArray bytes = env->NewByteArray(static_cast<jsize>(std::strlen(output)));
    if (!bytes) { mesh_avatar_free_string(output); return nullptr; }
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(std::strlen(output)), reinterpret_cast<const jbyte*>(output));
    mesh_avatar_free_string(output);
    auto cls = env->FindClass("java/lang/String");
    auto constructor = env->GetMethodID(cls, "<init>", "([BLjava/lang/String;)V");
    auto encoding = env->NewStringUTF("UTF-8");
    return static_cast<jstring>(env->NewObject(cls, constructor, bytes, encoding));
  } catch (const std::exception& error) { report(env, error); return nullptr; }
}
