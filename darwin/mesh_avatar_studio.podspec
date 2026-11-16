Pod::Spec.new do |s|
  s.name = 'mesh_avatar_studio'
  s.version = '0.1.0'
  s.summary = 'Mesh Avatar Studio 原生 Flutter 播放器。'
  s.description = '使用 Rust 原生运行库、Metal 和 Flutter Texture 显示二维网格角色。'
  s.homepage = 'https://github.com/zhangruiyu/mesh-avatar-studio-flutter'
  s.license = { :file => '../LICENSE' }
  s.author = 'mesh_avatar_studio contributors'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.vendored_frameworks = 'Frameworks/MeshAvatarNative.xcframework'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.swift_version = '5.0'
  s.frameworks = 'Metal', 'QuartzCore', 'CoreGraphics', 'Foundation', 'CoreVideo'
  s.libraries = 'iconv'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
