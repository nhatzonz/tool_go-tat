# Lệnh build Gõ Tắt

Chạy các lệnh trong Terminal, tại thư mục dự án:

```sh
cd /Users/nhatnguyen/tool_dan-nhanh
```

## macOS

```sh
./build.sh
ditto -c -k --keepParent GoTat.app GoTat-macOS.zip
```

| Lệnh | Tạo ra | Dùng để |
|------|--------|---------|
| `./build.sh` | `GoTat.app` | Chạy thử trên máy mình (`open GoTat.app`) |
| `ditto …` | `GoTat-macOS.zip` | Gửi cho máy khác |

- Cả hai file nằm ngay trong thư mục dự án. Mỗi lần build, bản mới ghi đè bản cũ.
- Chạy được trên Mac chip Apple và Mac chip Intel, cần macOS 14 trở lên.
- Sau mỗi lần build lại, phải cấp lại quyền Accessibility (xoá mục cũ, thêm lại).

### Máy nhận cài đặt thế nào

1. Giải nén, kéo `GoTat.app` vào **Applications**.
2. Mở app, bị chặn thì vào **System Settings → Privacy & Security → Open Anyway**.
   Nếu báo "app bị hỏng": chạy `xattr -cr /Applications/GoTat.app` rồi mở lại.
3. Bật **Gõ Tắt** trong **System Settings → Privacy & Security → Accessibility**.

## Windows

Build ngay trên máy Mac này, không cần máy Windows:

```sh
./build-windows.sh
```

| Tạo ra | Dùng để |
|--------|---------|
| `build/windows/GoTat.exe` | File chạy của app |
| `GoTat-Windows.zip` | Gửi cho máy Windows khác |

- Cần .NET SDK 8 (đã cài ở `~/.dotnet`). Máy khác chưa có thì cài bằng:
  `curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0 --install-dir ~/.dotnet`
- File `.exe` khoảng 70 MB vì đã gói sẵn .NET bên trong, máy nhận không phải cài gì thêm.
- Chạy trên Windows 10 / 11 bản 64-bit.

### Máy nhận cài đặt thế nào

1. Giải nén, đặt `GoTat.exe` ở chỗ cố định (vd. `C:\Users\<tên>\GoTat\`).
2. Mở `GoTat.exe`. Nếu Windows hiện **"Windows protected your PC"**: bấm **More info → Run anyway**.
3. Đóng cửa sổ thì app vẫn chạy ở khay hệ thống (góc phải thanh Taskbar). Nhấn `Ctrl+F1` để mở lại.
4. Muốn tự chạy khi mở máy: nhấn `Win+R`, gõ `shell:startup`, đặt shortcut của `GoTat.exe` vào thư mục vừa mở.

Lưu ý: phím tắt không dán được vào app đang chạy bằng quyền Administrator, trừ khi Gõ Tắt cũng chạy bằng quyền Administrator.

## Build cả hai cùng lúc

```sh
./build.sh && ditto -c -k --keepParent GoTat.app GoTat-macOS.zip && ./build-windows.sh
```

## Vẽ lại logo

```sh
swift icon/make_icon.swift icon/icon_1024.png
python3 icon/make_ico.py icon/icon_1024.png windows/app.ico
./build.sh && ./build-windows.sh
```
