# Gõ Tắt

Gõ Tắt giúp bạn nhập liệu nhanh hơn: gán những nội dung hay dùng vào phím tắt, rồi nhấn phím tắt là nội dung được dán ngay vào ô nhập liệu đang mở, ở bất kỳ ứng dụng nào.

Phù hợp cho người thường xuyên gõ lặp lại: thông tin liên hệ, địa chỉ, mẫu trả lời khách hàng, mã QR, ảnh sản phẩm…

## Tính năng

- Gán phím tắt tuỳ ý cho từng nội dung (ví dụ `⌃1` → "Liên hệ Zalo 0123…")
- Nội dung có thể là chữ, ảnh, hoặc cả chữ lẫn nhiều ảnh: chữ được dán trước, sau đó lần lượt từng ảnh theo thứ tự
- Thêm ảnh bằng cách chọn file, kéo-thả, hoặc dán trực tiếp (`⌘V` / `⌃V`) vào ô nội dung
- Kéo-thả để sắp xếp lại thứ tự ảnh, xoá từng ảnh
- Tự khôi phục clipboard sau khi dán
- Phím tắt riêng để mở nhanh cửa sổ cài đặt (mặc định `⌃F1`, đổi được trong app)
- Cảnh báo khi phím tắt bị trùng (nói rõ trùng với dòng nào) hoặc đã bị ứng dụng khác chiếm
- Tìm kiếm theo nội dung hoặc phím tắt
- Giao diện sáng / tối (nút mặt trời/mặt trăng trên thanh tiêu đề)
- Tiếng Việt / English (chọn bằng lá cờ trên thanh tiêu đề, mặc định tiếng Việt)
- Hỏi xác nhận trước khi xoá phím tắt có nội dung
- Chạy nền trên thanh menu, bật/tắt toàn bộ phím tắt chỉ với một nút
- Dữ liệu lưu cục bộ trên máy, không gửi đi đâu

## Nền tảng

| Nền tảng | Trạng thái |
|----------|-----------|
| macOS 14+ | Đã có |
| Windows 10/11 | Đã có, xem `lenh-build.md` (chưa thử trên máy Windows thật) |
| iOS | Dự kiến (dạng bàn phím tuỳ chỉnh: iOS không cho phép phím tắt toàn hệ thống) |

## Cài đặt trên macOS

### Yêu cầu

- macOS 14 (Sonoma) trở lên
- Xcode hoặc Xcode Command Line Tools (để có `swiftc`):

  ```sh
  xcode-select --install
  ```

### Build

```sh
git clone <đường-dẫn-repo>
cd tool_dan-nhanh
./build.sh
open GoTat.app
```

Có thể kéo `GoTat.app` vào thư mục **Applications** để dùng lâu dài.

### Cấp quyền Trợ năng (bắt buộc)

App cần quyền **Accessibility** để gửi lệnh dán (`⌘V`) vào ứng dụng khác:

1. Mở **System Settings → Privacy & Security → Accessibility**
2. Bấm **+**, chọn `GoTat.app` và bật công tắc

Trong cửa sổ app, góc trên bên phải sẽ hiện **"Đã cấp quyền"** màu xanh khi thành công.

> **Lưu ý:** app đang được ký tạm (ad-hoc), nên **mỗi lần build lại** macOS coi đó là app mới. Khi đó hãy xoá mục Gõ Tắt (hoặc DanNhanh) cũ trong danh sách Accessibility (nút **–**) rồi thêm lại.

### Tự chạy khi mở máy (tuỳ chọn)

**System Settings → General → Login Items** → thêm `GoTat.app`.

## Cách dùng

1. Mở cửa sổ app (icon ⌨ trên thanh menu → **Mở Gõ Tắt**, hoặc nhấn phím mở app)
2. Bấm **Phím tắt mới** (`⌘N`), app sẽ chờ bạn nhấn tổ hợp phím ngay
3. Nhấn tổ hợp muốn dùng (`Esc` để huỷ, `⌫` để xoá). Phím tắt phải kèm `⌃`, `⌥` hoặc `⌘` (trừ phím F)
4. Nhập nội dung chữ và/hoặc thêm ảnh
5. Ở bất kỳ ứng dụng nào, đặt con trỏ vào ô nhập liệu rồi nhấn phím tắt

### Mẹo chọn phím tắt

- Nên dùng tổ hợp có phím bổ trợ như `⌃1`, `⌃2`, `⌃⌥A`… để không ảnh hưởng việc gõ chữ bình thường.
- Tránh `⌘1`…`⌘9`: nhiều ứng dụng (trình duyệt, Finder, VS Code) dùng để chuyển tab.
- Phím **F1–F12** trên Mac mặc định điều khiển độ sáng, âm lượng… Muốn dùng làm phím tắt, nhấn kèm `fn` hoặc bật **System Settings → Keyboard → Keyboard Shortcuts → Function Keys → "Use F1, F2, etc. keys as standard function keys"**.
- Ảnh chỉ dán được vào nơi nhận ảnh (khung chat, email, Word, Notes…). Ô nhập chỉ nhận chữ sẽ bỏ qua ảnh.

## Dữ liệu

| Nội dung | Vị trí |
|----------|--------|
| Danh sách phím tắt | `~/Library/Application Support/DanNhanh/snippets.json` |
| Ảnh | `~/Library/Application Support/DanNhanh/images/` |
| Log (để gỡ lỗi) | `~/Library/Logs/DanNhanh.log` |

Sao lưu hoặc chuyển sang máy khác: sao chép cả thư mục `~/Library/Application Support/DanNhanh/`.

## Cấu trúc dự án

```
main.swift   Toàn bộ mã nguồn app macOS (AppKit + SwiftUI)
build.sh     Build ra GoTat.app và ký ad-hoc
windows/     Bản Windows (C# + WPF), build bằng build-windows.sh
lenh-build.md  Lệnh build macOS / Windows và cách cài trên máy khác
icon/        Logo app: make_icon.swift vẽ ra icon_1024.png, build.sh chuyển thành AppIcon.icns
```

### Cách hoạt động

- **Phím tắt toàn hệ thống:** đăng ký bằng Carbon `RegisterEventHotKey`
- **Dán:** đưa nội dung vào clipboard, giả lập `⌘V` bằng `CGEvent`, rồi khôi phục clipboard cũ
- **Giao diện:** SwiftUI đặt trong cửa sổ AppKit, kèm icon trên thanh menu

## Lộ trình

- [ ] Bản iOS (bàn phím tuỳ chỉnh)
- [ ] Gõ tắt: gõ một cụm ngắn (ví dụ `/dc`) tự bung thành nội dung đầy đủ
- [ ] Biến động trong nội dung: `{ngay}`, `{gio}`, `{clipboard}`
- [ ] Xuất / nhập danh sách phím tắt
- [ ] Ký app bằng chứng chỉ cố định để không phải cấp lại quyền sau mỗi lần build
