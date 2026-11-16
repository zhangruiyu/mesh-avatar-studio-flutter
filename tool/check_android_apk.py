"""检查 APK 的实际原生架构，防止只改 ABI 配置却漏装或混装运行库。"""
from pathlib import Path
import argparse
import struct
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("apk", type=Path)
parser.add_argument("--abis", nargs="+", required=True,
                    choices=["armeabi-v7a", "arm64-v8a", "x86_64"])
args = parser.parse_args()
# ELF class：1 为 32 位，2 为 64 位；machine 来自 ELF 标准架构编号。
expected = {"armeabi-v7a": (1, 40), "arm64-v8a": (2, 183), "x86_64": (2, 62)}
required = {"libflutter.so", "libmesh_avatar_ffi.so", "libmesh_avatar_bridge.so"}
with zipfile.ZipFile(args.apk) as archive:
    names = [name for name in archive.namelist() if name.startswith("lib/") and name.endswith(".so")]
    actual = {name.split("/")[1] for name in names}
    if actual != set(args.abis):
        raise SystemExit(f"APK 架构不符：实际 {sorted(actual)}，预期 {args.abis}")
    for abi in args.abis:
        libraries = [name for name in names if name.startswith(f"lib/{abi}/")]
        missing = required - {Path(name).name for name in libraries}
        if missing:
            raise SystemExit(f"{abi} 缺少原生库：{sorted(missing)}")
        for name in libraries:
            data = archive.read(name)
            if data[:4] != b"\x7fELF" or data[5] != 1:
                raise SystemExit(f"不是小端 ELF：{name}")
            elf_class = data[4]
            machine = struct.unpack_from("<H", data, 18)[0]
            if (elf_class, machine) != expected[abi]:
                raise SystemExit(f"架构目录与 ELF 内容不一致：{name}")
            # 插件的两份库都要求 16 KiB 对齐，不依赖文件名或目录推测。
            if Path(name).name in {"libmesh_avatar_ffi.so", "libmesh_avatar_bridge.so"}:
                is32 = elf_class == 1
                offset = struct.unpack_from("<I" if is32 else "<Q", data, 28 if is32 else 32)[0]
                size, count = struct.unpack_from("<HH", data, 42 if is32 else 54)
                for index in range(count):
                    entry = offset + size * index
                    if struct.unpack_from("<I", data, entry)[0] == 1:
                        align = struct.unpack_from("<I" if is32 else "<Q", data, entry + (28 if is32 else 48))[0]
                        if align < 16384:
                            raise SystemExit(f"插件库 LOAD 段未按 16 KiB 对齐：{name}")
        print(f"{abi}：{len(libraries)} 个原生库的架构正确，插件库齐全且按 16 KiB 对齐")
print("APK 原生架构检查通过；此检查不代替对应设备上的运行测试。")
