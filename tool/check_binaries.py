"""核对随包原生库的体积和 SHA-256；--write 用于编译完成后更新清单。"""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[1]
files = sorted(list((root / "darwin").rglob("*.a")) +
               list((root / "android/src/main/jniLibs").rglob("*.so")) +
               list((root / "ohos/libs").rglob("*.so")))
manifest = {"upstreamCommit": "6d2817aa0869365a0a5634241bf50af6bfd78a2a",
            "rustVersion": "1.100.0", "files": [
                {"path": str(f.relative_to(root)), "bytes": f.stat().st_size,
                 "sha256": hashlib.sha256(f.read_bytes()).hexdigest()} for f in files]}
path = root / "native/BINARIES.json"
if "--write" in sys.argv:
    path.write_text(json.dumps(manifest, indent=2) + "\n")
else:
    if manifest != json.loads(path.read_text()):
        raise SystemExit("二进制与发布清单不一致，请核对构建来源")
print(f"已核对 {len(files)} 个原生库，共 {sum(f['bytes'] for f in manifest['files']) / 1024**2:.1f} MiB")
