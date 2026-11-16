"""在开发机验证鸿蒙网格缓存；只使用 SDK 类型声明，GL 调用由测试内存缓冲实现。"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ohos-native", type=Path, required=True, help="DevEco SDK native 目录")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="mesh-ohos-cache-test-") as directory:
    temporary = Path(directory)
    # 只引入 GLES/KHR 头，避免把鸿蒙 libc 头混进宿主编译器的标准库。
    includes = args.ohos_native / "sysroot/usr/include"
    for name in ["GLES3", "KHR"]:
        shutil.copytree(includes / name, temporary / name)
    binary = temporary / "mesh_cache_test"
    subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-I" + str(temporary), "-I" + str(root / "native/include"),
                    "-I" + str(root / "ohos/src/main/cpp"),
                    str(root / "test/native/ohos_mesh_cache_test.cpp"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
