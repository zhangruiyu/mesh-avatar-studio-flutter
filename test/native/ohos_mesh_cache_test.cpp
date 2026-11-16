#include <cassert>
#include <cstring>
#include <iostream>
#include <map>
#include <vector>
#include "avatar_mesh_cache.h"

// 用内存模拟 GL 缓冲，检查实际上传后的数据和绑定，不依赖开发机拥有 GLES 驱动。
// 真正的 GLES 链接、提交和画面另由鸿蒙编译与真机测试覆盖。
std::map<GLuint, std::vector<unsigned char>> gpu;
std::map<GLuint, GLuint> attributes;
GLuint nextBuffer = 1, arrayBuffer = 0, indexBuffer = 0;
size_t allocations = 0, updates = 0, uploadedBytes = 0;
extern "C" {
void glGenBuffers(GLsizei count, GLuint* buffers) {
  for (int i = 0; i < count; ++i) { buffers[i] = nextBuffer++; gpu[buffers[i]] = {}; }
}
void glDeleteBuffers(GLsizei count, const GLuint* buffers) {
  for (int i = 0; i < count; ++i) assert(gpu.erase(buffers[i]) == 1);
}
void glBindBuffer(GLenum target, GLuint buffer) {
  assert(gpu.count(buffer));
  (target == GL_ARRAY_BUFFER ? arrayBuffer : indexBuffer) = buffer;
}
void glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum) {
  auto& bytes = gpu.at(target == GL_ARRAY_BUFFER ? arrayBuffer : indexBuffer);
  bytes.resize(size); std::memcpy(bytes.data(), data, size);
  ++allocations; uploadedBytes += size;
}
void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
  auto& bytes = gpu.at(target == GL_ARRAY_BUFFER ? arrayBuffer : indexBuffer);
  assert(offset >= 0 && size >= 0 && static_cast<size_t>(offset + size) <= bytes.size());
  std::memcpy(bytes.data() + offset, data, size);
  ++updates; uploadedBytes += size;
}
void glVertexAttribPointer(GLuint location, GLint, GLenum, GLboolean, GLsizei, const void*) {
  attributes[location] = arrayBuffer;
}
}

void verifyBound(const MaLayer& layer) {
  assert(std::memcmp(gpu.at(attributes.at(0)).data(), layer.positions, layer.vertex_count * 2 * sizeof(float)) == 0);
  assert(std::memcmp(gpu.at(attributes.at(1)).data(), layer.uvs, layer.vertex_count * 2 * sizeof(float)) == 0);
  assert(std::memcmp(gpu.at(indexBuffer).data(), layer.indices, layer.index_count * sizeof(uint32_t)) == 0);
}
int main() {
  AvatarMeshCache cache;
  std::vector<float> positions{0,0, 1,0, 0,1}, uvs{0,0, 1,0, 0,1};
  std::vector<uint32_t> indices{0,1,2};
  MaLayer layer{}; layer.name = "face";
  auto refresh = [&] {
    layer.positions = positions.data(); layer.uvs = uvs.data();
    layer.indices = indices.data(); layer.vertex_count = positions.size() / 2; layer.index_count = indices.size();
  };
  auto draw = [&] {
    refresh(); cache.beginFrame(); cache.bind(layer, 0, 1); verifyBound(layer); cache.endFrame();
  };
  draw(); assert(allocations == 3 && updates == 0 && gpu.size() == 3);
  const auto initialBytes = uploadedBytes;
  for (int i = 0; i < 100; ++i) draw();
  assert(uploadedBytes == initialBytes && allocations == 3 && updates == 0);
  // 相同大小、相同内存地址但内容改变，三个通道都必须被识别。
  positions[0] = 0.25f; draw(); assert(updates == 1);
  uvs[0] = 0.75f; draw(); assert(updates == 2);
  indices[0] = 1; draw(); assert(updates == 3);
  positions.insert(positions.end(), {1,1}); uvs.insert(uvs.end(), {1,1}); indices.insert(indices.end(), {1,2,3});
  draw(); assert(allocations == 6 && updates == 3);
  positions.resize(6); uvs.resize(6); indices.resize(3);
  draw(); assert(allocations == 6 && updates == 6);
  positions.insert(positions.end(), {1,1}); uvs.insert(uvs.end(), {1,1}); indices.insert(indices.end(), {1,2,3});
  draw(); assert(allocations == 6 && updates == 9); // 缩小后重新增长仍复用已有容量。

  MaLayer accessory = layer; accessory.name = "配饰";
  cache.beginFrame(); cache.bind(layer,0,1); cache.bind(accessory,0,1); verifyBound(accessory); cache.endFrame();
  const auto beforeReorder = uploadedBytes;
  cache.beginFrame(); cache.bind(accessory,0,1); verifyBound(accessory); cache.bind(layer,0,1); verifyBound(layer); cache.endFrame();
  assert(uploadedBytes == beforeReorder && gpu.size() == 6);
  cache.beginFrame(); cache.bind(layer,0,1); cache.markPresent("配饰"); cache.endFrame();
  assert(gpu.size() == 6); // 暂时透明，不释放仍在模型帧里的图层。
  cache.beginFrame(); cache.bind(layer,0,1); cache.endFrame();
  assert(gpu.size() == 3); // 真正移除配饰，释放它的三个缓冲。
  for (int i = 0; i < 1000; ++i) { positions[0] = static_cast<float>(i); draw(); }
  assert(gpu.size() == 3 && allocations == 9);
  cache.clear(); cache.clear(); assert(gpu.empty());
  draw(); assert(gpu.size() == 3); // 清空后仍能重建，不使用旧 GL 句柄。
  cache.clear(); assert(gpu.empty());
  std::cout << "鸿蒙网格缓存测试通过：不变数据零上传、同长度变化、扩缩容、图层重排/隐藏/删除、1000 帧更新及重建。\n";
  std::cout << "静态三角形 101 帧：旧链路 303 次上传 / " << initialBytes * 101
            << " 字节；缓存链路 3 次上传 / " << initialBytes << " 字节。此处不代表真机耗时。\n";
}
