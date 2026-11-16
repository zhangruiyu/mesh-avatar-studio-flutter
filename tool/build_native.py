"""重新编译随包原生运行库；不编译示例，也不读取任何角色文件。"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("platform", choices=["apple", "android", "ohos"])
parser.add_argument("--ndk", type=Path, help="Android NDK 根目录")
parser.add_argument("--ohos-native", type=Path, help="DevEco SDK 的 native 目录")
parser.add_argument("--target-dir", type=Path, default=root / "build/native-target")
args = parser.parse_args()
target_dir = args.target_dir.resolve()
source = root / "native/upstream"

def run(command, env=None):
    subprocess.run([str(x) for x in command], cwd=source, env=env, check=True)

def build(target, render, env):
    run(["rustup", "target", "add", target], env)
    command = ["cargo", "build", "--locked", "--release", "-p", "mesh-avatar-ffi",
               "--target", target, "--target-dir", target_dir]
    if render:
        command += ["--features", "render"]
    run(command, env)
    return target_dir / target / "release"

def install(source_file, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_file, destination)

if args.platform == "apple":
    targets = ["aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios",
               "aarch64-apple-darwin", "x86_64-apple-darwin"]
    libraries = {t: build(t, True, os.environ.copy()) / "libmesh_avatar_ffi.a" for t in targets}
    # 各 slice 必须使用同一个库名，否则 CocoaPods 拒绝整个 XCFramework。
    with tempfile.TemporaryDirectory(prefix="mesh-avatar-apple-") as folder:
        temp = Path(folder)
        sim = temp / "sim/libmesh_avatar_ffi.a"
        mac = temp / "mac/libmesh_avatar_ffi.a"
        sim.parent.mkdir(); mac.parent.mkdir()
        run(["lipo", "-create", libraries[targets[1]], libraries[targets[2]], "-output", sim])
        run(["lipo", "-create", libraries[targets[3]], libraries[targets[4]], "-output", mac])
        output = temp / "MeshAvatarNative.xcframework"
        command = ["xcodebuild", "-create-xcframework"]
        for library in [libraries[targets[0]], sim, mac]:
            command += ["-library", library, "-headers", root / "native/include"]
        run(command + ["-output", output])
        destination = root / "darwin/Frameworks/MeshAvatarNative.xcframework"
        # 先完成临时产物，再替换发布目录，避免失败时留下半个框架。
        if destination.exists(): shutil.rmtree(destination)
        shutil.copytree(output, destination)
elif args.platform == "android":
    if args.ndk is None: parser.error("android 需要 --ndk")
    compiler_dir = args.ndk.resolve() / "toolchains/llvm/prebuilt/darwin-x86_64/bin"
    for target, clang, abi in [
        ("aarch64-linux-android", "aarch64-linux-android26-clang", "arm64-v8a"),
        ("x86_64-linux-android", "x86_64-linux-android26-clang", "x86_64")]:
        env = os.environ.copy()
        key = target.upper().replace("-", "_")
        env["CARGO_TARGET_" + key + "_LINKER"] = str(compiler_dir / clang)
        env["CC_" + target.replace("-", "_")] = str(compiler_dir / clang)
        env["AR_" + target.replace("-", "_")] = str(compiler_dir / "llvm-ar")
        # 原生库和 JNI 桥接都支持 Android 的 16 KiB 内存页。
        env["CARGO_TARGET_" + key + "_RUSTFLAGS"] = "-C link-arg=-Wl,-z,max-page-size=16384"
        library = build(target, True, env) / "libmesh_avatar_ffi.so"
        install(library, root / "android/src/main/jniLibs" / abi / library.name)
else:
    if args.ohos_native is None: parser.error("ohos 需要 --ohos-native")
    compiler_dir = args.ohos_native.resolve() / "llvm/bin"
    target = "aarch64-unknown-linux-ohos"
    env = os.environ.copy()
    env["CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER"] = str(compiler_dir / (target + "-clang"))
    env["CC_aarch64_unknown_linux_ohos"] = str(compiler_dir / (target + "-clang"))
    env["AR_aarch64_unknown_linux_ohos"] = str(compiler_dir / "llvm-ar")
    library = build(target, False, env) / "libmesh_avatar_ffi.so"
    install(library, root / "ohos/libs/arm64-v8a" / library.name)

print("原生库已更新；请核对许可证、更新校验清单并重新执行平台测试。")
