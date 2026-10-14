"""Gộp logo thành file .ico cho Windows (16→256px, mỗi cỡ là một ảnh PNG).
Dùng: python3 icon/make_ico.py icon/icon_1024.png windows/app.ico"""
import os, struct, subprocess, sys, tempfile

src, out = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
tmp = tempfile.mkdtemp()
images = []
for s in sizes:
    p = os.path.join(tmp, f"{s}.png")
    subprocess.run(["sips", "-z", str(s), str(s), src, "--out", p], check=True, capture_output=True)
    images.append(open(p, "rb").read())

header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, data in zip(sizes, images):
    dim = 0 if s >= 256 else s   # 0 nghĩa là 256
    entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
with open(out, "wb") as f:
    f.write(header + entries + b"".join(images))
print("Đã tạo", out)
