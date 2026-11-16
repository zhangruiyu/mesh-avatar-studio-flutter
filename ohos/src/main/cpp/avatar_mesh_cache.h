#ifndef MESH_AVATAR_OHOS_MESH_CACHE_H
#define MESH_AVATAR_OHOS_MESH_CACHE_H

#include <GLES3/gl3.h>
#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "mesh_avatar.h"

// 只在持有当前 EGL 上下文的绘制线程使用；退出前调用 clear 释放 GPU 对象。
// 按名称缓存，不能按绘制序号缓存：表情和配饰会改变图层的数量与顺序。
class AvatarMeshCache {
  struct LayerBuffers {
    GLuint buffers[3] = {};
    size_t capacityBytes[3] = {};
    std::vector<float> positions, uvs;
    std::vector<uint32_t> indices;
    bool present = false;
  };
  std::map<std::string, LayerBuffers> layers;

  template <typename T>
  static void upload(GLenum target, GLuint buffer, const T* data, size_t count,
                     size_t& capacityBytes, std::vector<T>& previous, GLenum usage) {
    glBindBuffer(target, buffer);
    const size_t bytes = count * sizeof(T);
    // 比较内容而非指针或数量。FFI 借用指针下一次 tick 就可能失效。
    if (previous.size() == count && (bytes == 0 || std::memcmp(previous.data(), data, bytes) == 0)) return;
    if (bytes > capacityBytes) {
      glBufferData(target, static_cast<GLsizeiptr>(bytes), data, usage);
      capacityBytes = bytes;
    } else if (bytes > 0) {
      // 容量足够时更新有效区间，缩小的网格仍按当前 index_count 绘制。
      glBufferSubData(target, 0, static_cast<GLsizeiptr>(bytes), data);
    }
    previous.assign(data, data + count);
  }

public:
  AvatarMeshCache() = default;
  AvatarMeshCache(const AvatarMeshCache&) = delete;
  AvatarMeshCache& operator=(const AvatarMeshCache&) = delete;

  void beginFrame() {
    for (auto& item : layers) item.second.present = false;
  }

  void markPresent(const char* name) {
    auto found = layers.find(name);
    // 透明但仍在帧里的图层保留缓存，避免眨眼等透明度切换反复分配。
    if (found != layers.end()) found->second.present = true;
  }

  void bind(const MaLayer& layer, GLint positionLocation, GLint uvLocation) {
    auto& cached = layers[layer.name];
    cached.present = true;
    if (cached.buffers[0] == 0) glGenBuffers(3, cached.buffers);
    upload(GL_ARRAY_BUFFER, cached.buffers[0], layer.positions, layer.vertex_count * 2,
           cached.capacityBytes[0], cached.positions, GL_DYNAMIC_DRAW);
    glVertexAttribPointer(positionLocation, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    // UV 和索引通常长期不变，给驱动静态用途提示；内容变化时仍正常更新。
    upload(GL_ARRAY_BUFFER, cached.buffers[1], layer.uvs, layer.vertex_count * 2,
           cached.capacityBytes[1], cached.uvs, GL_STATIC_DRAW);
    glVertexAttribPointer(uvLocation, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    upload(GL_ELEMENT_ARRAY_BUFFER, cached.buffers[2], layer.indices, layer.index_count,
           cached.capacityBytes[2], cached.indices, GL_STATIC_DRAW);
  }

  void endFrame() {
    for (auto it = layers.begin(); it != layers.end();) {
      if (!it->second.present) {
        // 真正退出当前帧的配饰/图层立即释放，不能按历史名称无限积累缓存。
        glDeleteBuffers(3, it->second.buffers);
        it = layers.erase(it);
      } else {
        ++it;
      }
    }
  }

  void clear() {
    for (auto& item : layers) glDeleteBuffers(3, item.second.buffers);
    layers.clear();
  }
};
#endif
