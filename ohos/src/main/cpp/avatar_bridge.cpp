#include <napi/native_api.h>
#include <native_window/external_window.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include "mesh_avatar.h"
#include "avatar_shaders.h"

namespace {
constexpr int width = 600, height = 800;
using Clock = std::chrono::steady_clock;
// 这个独立样品只显示一个角色。模型和借用的网格数据都由同一把锁保护。
std::mutex mutex;
std::condition_variable changed;
std::thread renderThread;
MaHandle avatar = 0;
std::atomic<bool> stopped{true};
bool ready = false, paused = false, speaking = false, mouthDemo = false;
uint64_t frames = 0;
double renderMs = 0;
std::string expression = "neutral", error;

void check(MaStatus status) {
  if (status != MA_OK) throw std::runtime_error(mesh_avatar_last_error());
}
GLuint compile(GLenum type, const char* source) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[2048] = {};
    glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
    glDeleteShader(shader);
    throw std::runtime_error(std::string("着色器编译失败：") + log);
  }
  return shader;
}

// EGL 和全部 GL 资源只在绘制线程创建、使用和销毁。
void render(uint64_t surfaceId, const std::string path, const std::vector<uint8_t> bytes) {
  OHNativeWindow* window = nullptr;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLSurface surface = EGL_NO_SURFACE;
  EGLContext context = EGL_NO_CONTEXT;
  GLuint program = 0, vao = 0, buffers[3] = {}, vertex = 0, fragment = 0;
  std::vector<GLuint> textures;
  std::vector<std::string> textureNames;
  try {
    std::unique_lock<std::mutex> lock(mutex);
    if (bytes.empty()) check(mesh_avatar_open_path(path.c_str(), &avatar));
    else check(mesh_avatar_open_bytes(bytes.data(), bytes.size(), &avatar));
    if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window) != 0 || !window)
      throw std::runtime_error("无法取得 Flutter 原生纹理窗口");
    OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY, width, height);
    // 后台没有消费者时，不能无限卡住停止/重新加载操作。
    OH_NativeWindow_NativeWindowHandleOpt(window, SET_TIMEOUT, 100);
    display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr))
      throw std::runtime_error("EGL 初始化失败");
    const EGLint configAttrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig config;
    EGLint count = 0;
    if (!eglChooseConfig(display, configAttrs, &config, 1, &count) || count == 0)
      throw std::runtime_error("没有可用的 OpenGL ES 3 配置");
    EGLint format = 0;
    eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &format);
    OH_NativeWindow_NativeWindowHandleOpt(window, SET_FORMAT, format);
    const EGLint contextAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttrs);
    surface = eglCreateWindowSurface(display, config, reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (context == EGL_NO_CONTEXT || surface == EGL_NO_SURFACE || !eglMakeCurrent(display, surface, surface, context))
      throw std::runtime_error("原生纹理 EGL 上下文创建失败");
    eglSwapInterval(display, 0);
    vertex = compile(GL_VERTEX_SHADER, VS);
    fragment = compile(GL_FRAGMENT_SHADER, FS);
    program = glCreateProgram();
    glAttachShader(program, vertex); glAttachShader(program, fragment); glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) throw std::runtime_error("着色器链接失败");
    glUseProgram(program);
    glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(3, buffers);
    auto uniform = [&](const char* name) { return glGetUniformLocation(program, name); };
    GLint pos = glGetAttribLocation(program, "aPos"), uv = glGetAttribLocation(program, "aUv");
    glEnableVertexAttribArray(pos); glEnableVertexAttribArray(uv);
    GLint rectLoc = uniform("uRect"), faceLoc = uniform("uFace"), alphaLoc = uniform("uAlpha");
    GLint boxLoc = uniform("uEyeBox"), topLoc = uniform("uEyeTop"), botLoc = uniform("uEyeBot");
    GLint eyesLoc = uniform("uEyeState"), mouthLoc = uniform("uMouth"), mouthStateLoc = uniform("uMouthState");
    GLint cheeksLoc = uniform("uCheeks"), cheekLoc = uniform("uCheek");
    MaAvatarInfo info{}; check(mesh_avatar_get_info(avatar, &info));
    float scale = std::max(width / (info.image_width * 1.04f), height / (info.image_height * 1.06f));
    float ox = (width - info.image_width * scale) / 2, oy = (height - info.image_height * scale) / 2;
    glUniform2f(uniform("uScale"), 2 * scale / width, -2 * scale / height);
    glUniform2f(uniform("uOffset"), -1 + 2 * ox / width, 1 - 2 * oy / height);
    glUniform1i(uniform("uTex"), 0);
    size_t textureCount = 0; check(mesh_avatar_texture_count(avatar, &textureCount));
    textures.resize(textureCount); textureNames.resize(textureCount);
    glGenTextures(textureCount, textures.data());
    for (size_t i = 0; i < textureCount; ++i) {
      MaTexture texture{}; check(mesh_avatar_get_texture(avatar, i, &texture));
      textureNames[i] = texture.name;
      // 上游 C ABI 提供直通 RGBA；着色器和 Flutter 纹理使用预乘透明度。
      std::vector<uint8_t> rgba(texture.rgba, texture.rgba + texture.byte_count);
      for (size_t j = 0; j < rgba.size(); j += 4)
        for (int c = 0; c < 3; ++c) rgba[j + c] = (uint32_t(rgba[j + c]) * rgba[j + 3] + 127) / 255;
      glBindTexture(GL_TEXTURE_2D, textures[i]);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, texture.width, texture.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
    }
    glViewport(0, 0, width, height); glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    if (glGetError() != GL_NO_ERROR) throw std::runtime_error("纹理上传失败");
    ready = true; changed.notify_all();
    auto previous = Clock::now();
    double elapsed = 0;
    while (!stopped) {
      if (paused) {
        changed.wait(lock, [] { return stopped || !paused; });
        previous = Clock::now();
        continue;
      }
      auto start = Clock::now();
      double dt = std::chrono::duration<double>(start - previous).count();
      previous = start; elapsed += dt;
      // 与其他平台样品一致：这里只演示无声嘴型，不播放或录制音频。
      if (mouthDemo) check(mesh_avatar_set_voice_level(avatar, 0.22 + 0.5 * std::abs(std::sin(elapsed * 7))));
      check(mesh_avatar_tick(avatar, std::min(dt, 0.05)));
      MaFrame frame{}; check(mesh_avatar_get_frame(avatar, &frame));
      const auto& u = frame.uniforms;
      // GPU 请求缓冲区可能等待 Flutter 消费上一帧。此时必须释放状态锁，
      // 否则主线程读取 stats 会被卡住，反过来让 Flutter 无法继续消费纹理。
      // 网格只在本线程 tick/destroy；参数设置不使借用网格失效。
      lock.unlock();
      glClearColor(0, 0, 0, 0); glClear(GL_COLOR_BUFFER_BIT);
      glUniform4fv(boxLoc, 2, &u.eye_box[0][0]); glUniform1fv(topLoc, 48, &u.eye_top[0][0]);
      glUniform1fv(botLoc, 48, &u.eye_bot[0][0]); glUniform4fv(eyesLoc, 2, u.eyes);
      glUniform4fv(mouthLoc, 1, u.mouth); glUniform4fv(mouthStateLoc, 1, u.mouth_state);
      glUniform4fv(cheeksLoc, 1, u.cheeks); glUniform1f(cheekLoc, u.cheek);
      for (size_t i = 0; i < frame.layer_count; ++i) {
        if (stopped) break;
        const auto& layer = frame.layers[i];
        if (!layer.index_count || layer.alpha <= 0 || layer.texture_id >= textures.size()) continue;
        glBindTexture(GL_TEXTURE_2D, textures[layer.texture_id]);
        int face = layer.face ? 1 : layer.eye_ball >= 0 ? 2 + layer.eye_ball : 0;
        const auto& name = textureNames[layer.texture_id];
        if (name == "sprites/eyes_half_0.png") face = 4;
        if (name == "sprites/eyes_half_1.png") face = 5;
        glUniform1i(faceLoc, face); glUniform1f(alphaLoc, layer.alpha);
        glUniform4f(rectLoc, layer.rect[0], layer.rect[1], layer.rect[2], layer.rect[3]);
        glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        glBufferData(GL_ARRAY_BUFFER, layer.vertex_count * 2 * sizeof(float), layer.positions, GL_STREAM_DRAW);
        glVertexAttribPointer(pos, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
        glBindBuffer(GL_ARRAY_BUFFER, buffers[1]);
        glBufferData(GL_ARRAY_BUFFER, layer.vertex_count * 2 * sizeof(float), layer.uvs, GL_STREAM_DRAW);
        glVertexAttribPointer(uv, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[2]);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, layer.index_count * sizeof(uint32_t), layer.indices, GL_STREAM_DRAW);
        glDrawElements(GL_TRIANGLES, layer.index_count, GL_UNSIGNED_INT, nullptr);
      }
      if (stopped) { lock.lock(); break; }
      const GLenum drawError = glGetError();
      if (drawError != GL_NO_ERROR)
        throw std::runtime_error("OpenGL ES 绘制失败，错误码：" + std::to_string(drawError));
      if (!eglSwapBuffers(display, surface)) throw std::runtime_error("原生纹理提交失败，EGL 错误码：" + std::to_string(eglGetError()));
      lock.lock();
      ++frames;
      renderMs = std::chrono::duration<double, std::milli>(Clock::now() - start).count();
      changed.wait_until(lock, start + std::chrono::microseconds(33333), [] { return stopped || paused; });
    }
  } catch (const std::exception& exception) {
    std::lock_guard<std::mutex> lock(mutex);
    error = exception.what(); stopped = true; ready = true; changed.notify_all();
  }
  // 不调用 eglTerminate：默认显示由 Flutter 共享，不能销毁它的显示连接。
  if (context != EGL_NO_CONTEXT && eglGetCurrentContext() == context) {
    glDeleteTextures(textures.size(), textures.data()); glDeleteBuffers(3, buffers);
    glDeleteVertexArrays(1, &vao);
    if (program) glDeleteProgram(program);
    if (vertex) glDeleteShader(vertex);
    if (fragment) glDeleteShader(fragment);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
  if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
  if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
  if (window) OH_NativeWindow_DestroyNativeWindow(window);
  eglReleaseThread();
  std::lock_guard<std::mutex> lock(mutex);
  if (avatar) { mesh_avatar_destroy(avatar); avatar = 0; }
}

void dispose() {
  { std::lock_guard<std::mutex> lock(mutex); stopped = true; changed.notify_all(); }
  if (renderThread.joinable()) renderThread.join();
}
std::string stringValue(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok)
    throw std::runtime_error("桥接参数必须是字符串");
  std::vector<char> data(length + 1);
  napi_get_value_string_utf8(env, value, data.data(), data.size(), &length);
  return std::string(data.data(), length);
}
napi_value undefined(napi_env env) { napi_value value; napi_get_undefined(env, &value); return value; }
struct LoadJob { napi_async_work work; napi_deferred promise; std::string path, failure; std::vector<uint8_t> bytes; uint64_t surfaceId; };
napi_value load(napi_env env, napi_callback_info info) {
  size_t count = 3; napi_value args[3]; napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  auto* job = new LoadJob{};
  try {
    if (count != 3) throw std::runtime_error("缺少角色或纹理参数");
    job->surfaceId = std::stoull(stringValue(env, args[0])); job->path = stringValue(env, args[1]);
    void* data = nullptr; size_t length = 0;
    if (napi_get_arraybuffer_info(env, args[2], &data, &length) != napi_ok)
      throw std::runtime_error("模型字节参数类型错误");
    if (length) job->bytes.assign(static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + length);
  } catch (const std::exception& exception) {
    delete job; napi_throw_error(env, nullptr, exception.what()); return nullptr;
  }
  napi_value promise, name; napi_create_promise(env, &job->promise, &promise);
  napi_create_string_utf8(env, "加载原生角色", NAPI_AUTO_LENGTH, &name);
  napi_create_async_work(env, nullptr, name, [](napi_env, void* data) {
    auto* job = static_cast<LoadJob*>(data);
    try {
      dispose();
      std::unique_lock<std::mutex> lock(mutex);
      stopped = false; ready = false; paused = false; speaking = false; mouthDemo = false; frames = 0; renderMs = 0;
      error.clear(); expression = "neutral";
      renderThread = std::thread(render, job->surfaceId, job->path, std::move(job->bytes));
      changed.wait(lock, [] { return ready; });
      job->failure = error;
    } catch (const std::exception& exception) { job->failure = exception.what(); }
  }, [](napi_env env, napi_status status, void* data) {
    auto* job = static_cast<LoadJob*>(data);
    if (status != napi_ok && job->failure.empty()) job->failure = "角色加载任务被取消";
    if (job->failure.empty()) napi_resolve_deferred(env, job->promise, undefined(env));
    else {
      napi_value message, failure;
      napi_create_string_utf8(env, job->failure.c_str(), NAPI_AUTO_LENGTH, &message);
      napi_create_error(env, nullptr, message, &failure); napi_reject_deferred(env, job->promise, failure);
    }
    napi_delete_async_work(env, job->work); delete job;
  }, job, &job->work);
  napi_queue_async_work(env, job->work);
  return promise;
}
napi_value release(napi_env env, napi_callback_info) { dispose(); return undefined(env); }
napi_value command(napi_env env, napi_callback_info info) {
  size_t count = 2; napi_value args[2]; napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  try {
    if (count != 2) throw std::runtime_error("缺少操作参数");
    std::string method = stringValue(env, args[0]), value = stringValue(env, args[1]);
    std::lock_guard<std::mutex> lock(mutex);
    if (!avatar || stopped) throw std::runtime_error("角色尚未加载");
    if (method == "expression") { check(mesh_avatar_set_expression(avatar, value.c_str())); expression = value; }
    else if (method == "motion") check(mesh_avatar_play(avatar, value.c_str()));
    else if (method == "pause") { paused = value == "true"; changed.notify_all(); }
    else if (method == "voiceLevel") check(mesh_avatar_set_voice_level(avatar, std::stod(value)));
    else if (method == "speaking" || method == "mouthDemo") {
      if (value == "true") check(mesh_avatar_stop_lip_sync(avatar));
      mouthDemo = method == "mouthDemo" && value == "true";
      speaking = value == "true"; check(mesh_avatar_set_speaking(avatar, speaking));
      if (!speaking) check(mesh_avatar_set_voice_level(avatar, 0));
    } else throw std::runtime_error("未知的原生操作");
  } catch (const std::exception& exception) { napi_throw_error(env, nullptr, exception.what()); return nullptr; }
  return undefined(env);
}
// 与渲染帧共用互斥锁，查询和操作不会访问已释放的角色。
napi_value control(napi_env env, napi_callback_info info) {
  size_t count = 1; napi_value args[1]; napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  try {
    if (count != 1) throw std::runtime_error("缺少控制请求");
    auto request = stringValue(env, args[0]);
    std::lock_guard<std::mutex> lock(mutex);
    if (!avatar || stopped) throw std::runtime_error("角色尚未加载");
    char* output = nullptr;
    check(mesh_avatar_control_json(avatar, request.c_str(), &output));
    napi_value result;
    auto status = napi_create_string_utf8(env, output, NAPI_AUTO_LENGTH, &result);
    mesh_avatar_free_string(output);
    if (status != napi_ok) throw std::runtime_error("无法返回控制结果");
    return result;
  } catch (const std::exception& exception) { napi_throw_error(env, nullptr, exception.what()); return nullptr; }
}
napi_value stats(napi_env env, napi_callback_info) {
  std::lock_guard<std::mutex> lock(mutex);
  napi_value result; napi_create_object(env, &result);
  auto number = [&](const char* key, double n) { napi_value v; napi_create_double(env, n, &v); napi_set_named_property(env, result, key, v); };
  auto boolean = [&](const char* key, bool b) { napi_value v; napi_get_boolean(env, b, &v); napi_set_named_property(env, result, key, v); };
  auto text = [&](const char* key, const std::string& s) { napi_value v; napi_create_string_utf8(env, s.c_str(), NAPI_AUTO_LENGTH, &v); napi_set_named_property(env, result, key, v); };
  number("frames", frames); number("renderMs", renderMs);
  boolean("loaded", avatar != 0 && !stopped); boolean("paused", paused); boolean("speaking", speaking);
  text("expression", expression); text("error", error);
  return result;
}
napi_value init(napi_env env, napi_value exports) {
  napi_property_descriptor props[] = {
    {"control", nullptr, control, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"load", nullptr, load, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"dispose", nullptr, release, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"command", nullptr, command, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stats", nullptr, stats, nullptr, nullptr, nullptr, napi_default, nullptr}};
  napi_define_properties(env, exports, 5, props); return exports;
}
napi_module module = {1, 0, nullptr, init, "avatar_bridge", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void registerAvatarModule() { napi_module_register(&module); }
