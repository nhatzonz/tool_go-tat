import Cocoa
import SwiftUI
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Log

func log(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DanNhanh.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Localization

/// Chọn chuỗi theo ngôn ngữ đang dùng (mặc định tiếng Việt).
func L(_ vi: String, _ en: String) -> String { Store.shared.lang == "en" ? en : vi }

// MARK: - Model

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var keyCode: UInt32?          // nil = chưa gán phím tắt
    var modifiers: UInt32 = 0     // Carbon modifiers (cmdKey, shiftKey, ...)
    var keyLabel: String = ""
    var text: String = ""
    var imageFiles: [String] = [] // tên các file PNG trong thư mục images, dán theo thứ tự

    init(keyCode: UInt32? = nil, modifiers: UInt32 = 0, keyLabel: String = "", text: String = "") {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel; self.text = text
    }

    private enum CodingKeys: String, CodingKey { case id, keyCode, modifiers, keyLabel, text, imageFiles, imageFile }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keyCode = try c.decodeIfPresent(UInt32.self, forKey: .keyCode)
        modifiers = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? 0
        keyLabel = try c.decodeIfPresent(String.self, forKey: .keyLabel) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageFiles = try c.decodeIfPresent([String].self, forKey: .imageFiles) ?? []
        if let old = try c.decodeIfPresent(String.self, forKey: .imageFile) { imageFiles.insert(old, at: 0) } // bản cũ: 1 ảnh
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(keyCode, forKey: .keyCode)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(keyLabel, forKey: .keyLabel)
        try c.encode(text, forKey: .text)
        try c.encode(imageFiles, forKey: .imageFiles)
    }
}

final class Store: ObservableObject {
    static let shared = Store()

    @Published var snippets: [Snippet] = Store.load() {
        didSet { save(); HotKeyManager.shared.reload() }
    }
    @Published var enabled = true {
        didSet {
            HotKeyManager.shared.reload()
            (NSApp.delegate as? AppDelegate)?.refreshStatusItem()
        }
    }
    /// Phím tắt mở cửa sổ app (dùng chung struct Snippet, chỉ lấy phần phím).
    static let openKeyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @Published var openKey: Snippet = Store.loadOpenKey() {
        didSet {
            if let data = try? JSONEncoder().encode(openKey) { UserDefaults.standard.set(data, forKey: "openKey") }
            HotKeyManager.shared.reload()
        }
    }
    @Published var focusedID: UUID?   // dòng đang có con trỏ trong ô nội dung
    @Published var recordingID: UUID? {
        didSet { recordHint = nil; HotKeyManager.shared.reload() }
    }
    @Published var recordHint: String?          // nhắc lỗi khi ghi phím không hợp lệ
    @Published var failed: [UUID: String] = [:] // id dòng -> lý do phím tắt không hoạt động
    @Published var trusted = AXIsProcessTrusted()
    @Published var selectedID: UUID?  // phím tắt đang mở ở khung chi tiết
    /// "vi" hoặc "en", mặc định tiếng Việt.
    @Published var lang = UserDefaults.standard.string(forKey: "lang") ?? "vi" {
        didSet {
            UserDefaults.standard.set(lang, forKey: "lang")
            HotKeyManager.shared.reload(force: true) // cập nhật lại câu báo lỗi phím tắt
            (NSApp.delegate as? AppDelegate)?.rebuildMenus()
        }
    }
    /// "light", "dark" hoặc "" (theo hệ thống).
    @Published var theme = UserDefaults.standard.string(forKey: "theme") ?? "" {
        didSet { UserDefaults.standard.set(theme, forKey: "theme"); Store.applyTheme(theme) }
    }

    static func applyTheme(_ theme: String) {
        switch theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private static let baseDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanNhanh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        return dir
    }()
    private static let fileURL = baseDir.appendingPathComponent("snippets.json")

    static func imageURL(_ name: String) -> URL {
        baseDir.appendingPathComponent("images").appendingPathComponent(name)
    }

    /// Lưu các ảnh dưới dạng PNG và thêm vào cuối danh sách ảnh của dòng có id tương ứng.
    func addImages(_ images: [NSImage], to id: UUID) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        var names: [String] = []
        for image in images {
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let name = "\(UUID().uuidString).png"
            if (try? png.write(to: Store.imageURL(name))) != nil { names.append(name) }
        }
        if !names.isEmpty { snippets[i].imageFiles += names }
    }

    /// Ảnh trong clipboard: ưu tiên file ảnh copy từ Finder, sau đó tới dữ liệu ảnh.
    /// Trả về rỗng nếu clipboard là chữ, để ô nội dung dán chữ như bình thường.
    static func imagesFromPasteboard(_ pb: NSPasteboard = .general) -> [NSImage] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            return urls.compactMap { NSImage(contentsOf: $0) }
        }
        if pb.availableType(from: [.string]) != nil { return [] }
        return pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
    }

    /// Ảnh thu nhỏ có cache, tránh đọc lại file mỗi lần giao diện vẽ lại.
    private static let thumbCache = NSCache<NSString, NSImage>()
    static func thumbnail(_ name: String) -> NSImage? {
        if let img = thumbCache.object(forKey: name as NSString) { return img }
        guard let img = NSImage(contentsOf: imageURL(name)) else { return nil }
        thumbCache.setObject(img, forKey: name as NSString)
        return img
    }

    /// Thêm dòng mới và bắt đầu ghi phím tắt cho nó ngay.
    func addSnippet() {
        let s = Snippet()
        snippets.append(s)
        selectedID = s.id
        recordingID = s.id
    }

    func removeImage(_ name: String, from id: UUID) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].imageFiles.removeAll { $0 == name }
        try? FileManager.default.removeItem(at: Store.imageURL(name))
    }

    func moveImage(_ name: String, in id: UUID, by offset: Int) {
        guard let i = snippets.firstIndex(where: { $0.id == id }),
              let from = snippets[i].imageFiles.firstIndex(of: name) else { return }
        let to = from + offset
        guard snippets[i].imageFiles.indices.contains(to) else { return }
        snippets[i].imageFiles.swapAt(from, to)
    }

    /// Dời ảnh tới vị trí `index` (dùng khi kéo-thả sắp xếp).
    func moveImage(_ name: String, in id: UUID, to index: Int) {
        guard let i = snippets.firstIndex(where: { $0.id == id }),
              let from = snippets[i].imageFiles.firstIndex(of: name), from != index,
              snippets[i].imageFiles.indices.contains(index) else { return }
        var files = snippets[i].imageFiles
        files.insert(files.remove(at: from), at: index)
        snippets[i].imageFiles = files
    }

    func remove(_ id: UUID) {
        if recordingID == id { recordingID = nil }
        if selectedID == id, let i = snippets.firstIndex(where: { $0.id == id }) {
            let rest = snippets.filter { $0.id != id }
            selectedID = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
        }
        snippets.first(where: { $0.id == id })?.imageFiles.forEach {
            try? FileManager.default.removeItem(at: Store.imageURL($0))
        }
        snippets.removeAll { $0.id == id }
    }

    private init() { selectedID = snippets.first?.id }

    private static func loadOpenKey() -> Snippet {
        if let data = UserDefaults.standard.data(forKey: "openKey"),
           let key = try? JSONDecoder().decode(Snippet.self, from: data) { return key }
        var key = Snippet(keyCode: UInt32(kVK_F1), modifiers: UInt32(controlKey), keyLabel: "⌃F1")
        key.id = openKeyID
        return key
    }

    private static func load() -> [Snippet] {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Snippet].self, from: data) {
            return list
        }
        return [Snippet(keyCode: UInt32(kVK_F2), keyLabel: "F2", text: "abc")]
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(snippets) { try? data.write(to: Store.fileURL, options: .atomic) }
    }
}

// MARK: - Global hotkeys (Carbon)

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var refs: [EventHotKeyRef] = []
    private var idMap: [UInt32: UUID] = [:]
    private var lastSignature = ""

    func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        reload(force: true)
    }

    func reload(force: Bool = false) {
        let store = Store.shared
        let active = store.enabled && store.recordingID == nil
        let open = store.openKey
        let openSig = store.recordingID == nil ? "\(open.keyCode.map(String.init) ?? "-")-\(open.modifiers)" : "off"
        let sig = openSig + "|" + (active
            ? store.snippets.map { "\($0.id)-\($0.keyCode.map(String.init) ?? "-")-\($0.modifiers)" }.joined(separator: ",")
            : "off")
        if sig == lastSignature && !force { return }
        lastSignature = sig

        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        idMap.removeAll()

        var failed: [UUID: String] = [:]
        var seen: [String: String] = [:] // tổ hợp -> nơi đang dùng
        // Phím mở app luôn hoạt động (kể cả khi tắt phím tắt dán), trừ lúc đang ghi phím
        if store.recordingID == nil, let code = open.keyCode {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x444E_4E48), id: HotKeyManager.openHotKeyID)
            let status = RegisterEventHotKey(code, open.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
            log("Đăng ký phím mở app \(open.keyLabel) -> status \(status)")
            if status == noErr, let ref { refs.append(ref); seen["\(code)-\(open.modifiers)"] = L("phím mở app", "the open-app key") }
            else { failed[Store.openKeyID] = L("Bị hệ thống hoặc app khác dùng", "Taken by macOS or another app") }
        }
        if active {
            for (i, s) in store.snippets.enumerated() {
                guard let code = s.keyCode else { continue }
                let combo = "\(code)-\(s.modifiers)"
                if let owner = seen[combo] { failed[s.id] = L("Trùng với \(owner)", "Same as \(owner)"); continue }
                seen[combo] = L("phím tắt #\(i + 1)", "shortcut #\(i + 1)")
                let hkID = EventHotKeyID(signature: OSType(0x444E_4E48), id: UInt32(i + 1))
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(code, s.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
                log("Đăng ký \(s.keyLabel) (code \(code), mods \(s.modifiers)) -> status \(status)")
                if status == noErr, let ref {
                    refs.append(ref)
                    idMap[UInt32(i + 1)] = s.id
                } else {
                    failed[s.id] = L("Bị hệ thống hoặc app khác dùng", "Taken by macOS or another app")
                }
            }
        }
        if store.failed != failed {
            DispatchQueue.main.async { store.failed = failed }
        }
    }

    static let openHotKeyID: UInt32 = 9999

    private func fire(_ hotKeyID: UInt32) {
        log("Nhận phím tắt id \(hotKeyID)")
        if hotKeyID == HotKeyManager.openHotKeyID {
            (NSApp.delegate as? AppDelegate)?.showWindow()
            return
        }
        guard let uuid = idMap[hotKeyID],
              let snippet = Store.shared.snippets.first(where: { $0.id == uuid }) else { return }
        Paster.paste(snippet)
    }
}

// MARK: - Paste via clipboard + ⌘V

enum Paster {
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        Store.shared.trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Dán chữ trước (nếu có), sau đó lần lượt từng ảnh theo thứ tự.
    static func paste(_ snippet: Snippet) {
        var steps: [(NSPasteboard) -> Void] = []
        if !snippet.text.isEmpty {
            let text = snippet.text
            steps.append { $0.setString(text, forType: .string) }
        }
        for name in snippet.imageFiles {
            guard let png = try? Data(contentsOf: Store.imageURL(name)) else { continue }
            let tiff = NSImage(data: png)?.tiffRepresentation
            steps.append { pb in
                pb.setData(png, forType: .png)
                if let tiff { pb.setData(tiff, forType: .tiff) }
            }
        }
        guard !steps.isEmpty else { return }

        let trusted = AXIsProcessTrusted()
        log("Dán \(snippet.text.count) ký tự, \(snippet.imageFiles.count) ảnh, quyền Trợ năng = \(trusted)")
        guard trusted else { requestAccessibility(); return }

        let pb = NSPasteboard.general
        // Lưu clipboard hiện tại để khôi phục sau khi dán
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        func run(_ i: Int) {
            pb.clearContents()
            steps[i](pb)
            let changeCount = pb.changeCount
            sendCommandV()
            if i + 1 < steps.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { run(i + 1) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard pb.changeCount == changeCount else { return } // người dùng đã copy thứ khác
                    pb.clearContents()
                    if !saved.isEmpty { pb.writeObjects(saved) }
                }
            }
        }
        run(0)
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand   // ghi đè các phím bổ trợ đang giữ (vd. ⌃ của phím tắt)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Shortcut recording

enum KeyNames {
    static let special: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
    ]

    static func isFunctionKey(_ code: Int) -> Bool {
        guard let name = special[code], name.hasPrefix("F") else { return false }
        return Int(name.dropFirst()) != nil
    }

    static func label(for event: NSEvent) -> String {
        let f = event.modifierFlags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        if let name = special[Int(event.keyCode)] {
            s += name
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            s += chars.uppercased()
        } else {
            s += "#\(event.keyCode)"
        }
        return s
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}

// MARK: - UI: design tokens

enum UI {
    static let pad: CGFloat = 16
    static let gap: CGFloat = 12
    static let radius: CGFloat = 10
    static let smallRadius: CGFloat = 7
    static let sidebar: CGFloat = 280
}

/// Bảng màu, tự đổi theo chế độ sáng / tối.
enum Palette {
    static func ns(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    static let nsWindow = ns(0xFBFCFC, 0x161D1C)
    static let nsSide = ns(0xF2F5F4, 0x121918)

    static let window = Color(nsColor: nsWindow)
    static let side = Color(nsColor: nsSide)
    static let line = Color(nsColor: ns(0xDDE4E2, 0x26302E))
    static let field = Color(nsColor: ns(0xFFFFFF, 0x1C2523))
    static let fg = Color(nsColor: ns(0x16211F, 0xE6EEEC))
    static let muted = Color(nsColor: ns(0x5F6F6C, 0x93A4A0))
    static let faint = Color(nsColor: ns(0x97A5A2, 0x5D6D69))
    static let accent = Color(nsColor: ns(0x0E8F7E, 0x2FC2AB))
    static let accentSoft = Color(nsColor: ns(0xDFF3EF, 0x163A34))
    static let accentFg = Color(nsColor: ns(0xFFFFFF, 0x06221D))
    static let cap = Color(nsColor: ns(0xFFFFFF, 0x26302E))
    static let capEdge = Color(nsColor: ns(0xC9D3D1, 0x0B100F))
    static let danger = Color(nsColor: ns(0xD1453B, 0xF0675C))
    static let warn = Color(nsColor: ns(0xC27C0E, 0xE8A43A))
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.accentFg)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: UI.smallRadius).fill(Palette.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.field))
            .overlay(Capsule().strokeBorder(Palette.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Nhãn nhỏ viết hoa đặt trên mỗi phần của khung chi tiết.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Palette.faint)
    }
}

/// Xếp các view con thành hàng, tự xuống dòng khi hết chỗ.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - UI: keycaps

/// Vẽ phím tắt như phím bàn phím thật: "⌃⌥F1" → [⌃] [⌥] [F1].
struct KeyCaps: View {
    let label: String
    var size: CGFloat = 12

    private var keys: [String] {
        var out: [String] = []
        var rest = Substring(label)
        while let c = rest.first, "⌃⌥⇧⌘".contains(c) { out.append(String(c)); rest = rest.dropFirst() }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }

    var body: some View {
        HStack(spacing: size * 0.25) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: size, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.fg)
                    .padding(.horizontal, size * 0.45)
                    .frame(minWidth: size * 1.85, minHeight: size * 1.85)
                    .background(RoundedRectangle(cornerRadius: size * 0.42)
                        .fill(Palette.cap)
                        .shadow(color: Palette.capEdge, radius: 0, x: 0, y: max(1.5, size * 0.12)))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.42).strokeBorder(Palette.capEdge))
            }
        }
        .padding(.bottom, max(1.5, size * 0.12))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Ô phím viền đứt, dùng khi chưa có phím tắt hoặc đang chờ nhấn phím.
struct EmptyCap: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Palette.faint

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.9, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, size * 0.6)
            .frame(minHeight: size * 1.85)
            .overlay(RoundedRectangle(cornerRadius: size * 0.42)
                .strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .fixedSize()
    }
}

/// Ô hiển thị / ghi phím tắt, dùng cho phím tắt dán và phím mở app.
struct ShortcutButton: View {
    let label: String
    let recording: Bool
    let problem: String?
    var size: CGFloat = 12
    var showAction = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: size * 0.6) {
                if recording {
                    Image(systemName: "record.circle")
                        .font(.system(size: size * 0.95, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .symbolEffect(.pulse)
                    EmptyCap(text: L("Nhấn tổ hợp phím…", "Press keys…"), size: size, color: Palette.accent)
                } else if label.isEmpty {
                    EmptyCap(text: L("Chưa đặt", "Not set"), size: size)
                } else {
                    KeyCaps(label: label, size: size)
                }
                if problem != nil && !recording {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                }
                if showAction {
                    Text(recording ? L("Esc để huỷ", "Esc to cancel")
                         : label.isEmpty ? L("Bấm để đặt phím", "Click to set") : L("Đổi phím", "Change"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(size * 0.4)
            .background(RoundedRectangle(cornerRadius: UI.radius).fill(recording ? Palette.accentSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: UI.radius)
                .strokeBorder(recording ? Palette.accent : (hover ? Palette.line : .clear),
                              style: StrokeStyle(lineWidth: recording ? 1.5 : 1, dash: recording ? [] : [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(recording ? L("Nhấn tổ hợp phím · Esc để huỷ · ⌫ để xoá", "Press a key combo · Esc to cancel · ⌫ to clear")
                        : L("Bấm để đặt hoặc đổi phím tắt", "Click to set or change the shortcut"))
        .accessibilityLabel(label.isEmpty ? L("Đặt phím tắt", "Set shortcut") : L("Phím tắt \(label)", "Shortcut \(label)"))
    }
}

/// Dòng chú thích dưới ô phím tắt: hướng dẫn khi đang ghi, hoặc lý do lỗi.
struct ShortcutStatus: View {
    @ObservedObject var store = Store.shared
    let recording: Bool
    let problem: String?

    var body: some View {
        if recording {
            if let hint = store.recordHint {
                Label(hint, systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger)
            } else {
                Text(L("Esc huỷ · ⌫ xoá phím", "Esc cancel · ⌫ clear")).foregroundStyle(Palette.muted)
            }
        } else if let problem {
            Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger)
        }
    }
}

// MARK: - UI: title bar

/// Nút trên thanh tiêu đề: ngôn ngữ, sáng/tối, bật/tắt phím tắt dán.
struct TitleBarControls: View {
    @ObservedObject var store = Store.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                flag("vi", "🇻🇳", "Tiếng Việt")
                flag("en", "🇬🇧", "English")
            }
            .padding(2)
            .background(Capsule().fill(Palette.field))
            .overlay(Capsule().strokeBorder(Palette.line))

            Button { store.theme = scheme == .dark ? "light" : "dark" } label: {
                Image(systemName: scheme == .dark ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .help(scheme == .dark ? L("Chuyển sang giao diện sáng", "Switch to light mode")
                                  : L("Chuyển sang giao diện tối", "Switch to dark mode"))

            HStack(spacing: 6) {
                Circle().fill(store.enabled ? Palette.accent : Palette.warn).frame(width: 7, height: 7)
                Text(store.enabled ? L("Đang hoạt động", "Active") : L("Tạm dừng", "Paused"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                Toggle(isOn: $store.enabled) { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(store.enabled ? L("Tạm dừng tất cả phím tắt dán", "Pause all paste shortcuts")
                                        : L("Bật lại phím tắt dán", "Turn paste shortcuts back on"))
            }
        }
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .tint(Palette.accent)
    }

    private func flag(_ code: String, _ emoji: String, _ name: String) -> some View {
        let on = store.lang == code
        return Button { store.lang = code } label: {
            Text(emoji)
                .font(.system(size: 13))
                .frame(width: 28, height: 18)
                .background(Capsule().fill(on ? Palette.accentSoft : .clear))
                .opacity(on ? 1 : 0.45)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

// MARK: - UI: main window

struct ContentView: View {
    @ObservedObject var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1)
            if !store.trusted {
                PermissionBanner().padding(UI.pad).background(Palette.window)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
            HStack(spacing: 0) {
                Sidebar().frame(width: UI.sidebar)
                Rectangle().fill(Palette.line).frame(width: 1)
                DetailPane().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.window)
        .foregroundStyle(Palette.fg)
        .tint(Palette.accent)
        .frame(minWidth: 720, minHeight: 460)
    }
}

struct Sidebar: View {
    @ObservedObject var store = Store.shared
    @State private var query = ""

    private var visible: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.text.localizedCaseInsensitiveContains(q) || $0.keyLabel.localizedCaseInsensitiveContains(q)
        }
    }

    private var usesFunctionKey: Bool {
        (store.snippets + [store.openKey]).contains { $0.keyCode.map { KeyNames.isFunctionKey(Int($0)) } ?? false }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                searchField
                Button {
                    query = ""
                    store.addSnippet()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text(L("Phím tắt mới", "New shortcut"))
                        Text("⌘N").font(.system(size: 11, weight: .medium, design: .monospaced)).opacity(0.75)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("n", modifiers: .command)
                .help(L("Thêm phím tắt mới (⌘N)", "Add a new shortcut (⌘N)"))
            }
            .padding(12)

            list

            Rectangle().fill(Palette.line).frame(height: 1)
            footer
        }
        .background(Palette.side)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.faint)
            TextField(L("Tìm nội dung hoặc phím", "Search text or keys"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.faint)
                    .accessibilityLabel(L("Xoá tìm kiếm", "Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: UI.smallRadius).fill(Palette.field))
        .overlay(RoundedRectangle(cornerRadius: UI.smallRadius).strokeBorder(Palette.line))
    }

    @ViewBuilder private var list: some View {
        if visible.isEmpty {
            VStack(spacing: 6) {
                Text(query.isEmpty ? L("Chưa có phím tắt", "No shortcuts yet") : L("Không tìm thấy", "No matches"))
                    .foregroundStyle(Palette.faint)
                if !query.isEmpty {
                    Button(L("Xoá tìm kiếm", "Clear search")) { query = "" }.buttonStyle(ChipButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible) { s in
                            SidebarRow(snippet: s, selected: s.id == store.selectedID, problem: store.failed[s.id]) {
                                if store.recordingID != nil && store.recordingID != s.id { store.recordingID = nil }
                                store.selectedID = s.id
                            }
                            .id(s.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var footer: some View {
        let recordingOpen = store.recordingID == Store.openKeyID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Mở app nhanh", "Open app")).foregroundStyle(Palette.muted).fixedSize()
                Spacer(minLength: 0)
                ShortcutButton(label: store.openKey.keyCode == nil ? "" : store.openKey.keyLabel,
                               recording: recordingOpen,
                               problem: store.failed[Store.openKeyID], size: 11) {
                    store.recordingID = recordingOpen ? nil : Store.openKeyID
                }
                .help(L("Nhấn phím này ở bất kỳ đâu để mở cửa sổ Gõ Tắt", "Press this anywhere to open Gõ Tắt"))
            }
            ShortcutStatus(recording: recordingOpen, problem: store.failed[Store.openKeyID])
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if usesFunctionKey {
                Label(L("Phím F: nhấn kèm fn", "F-keys: hold fn"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Palette.faint)
                    .help(L("Trên Mac, F1–F12 mặc định điều khiển độ sáng, âm lượng… Hãy nhấn kèm fn, hoặc bật “Use F1, F2, etc. keys as standard function keys” trong System Settings → Keyboard.",
                            "On a Mac, F1–F12 control brightness, volume… by default. Hold fn, or turn on “Use F1, F2, etc. keys as standard function keys” in System Settings → Keyboard."))
            }
        }
        .font(.system(size: 12.5))
        .padding(12)
    }
}

struct SidebarRow: View {
    let snippet: Snippet
    let selected: Bool
    let problem: String?
    let action: () -> Void
    @State private var hover = false

    private var preview: String {
        let firstLine = snippet.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if !firstLine.isEmpty { return firstLine }
        return snippet.imageFiles.isEmpty ? L("Trống", "Empty") : L("Chỉ ảnh", "Images only")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if snippet.keyCode == nil { EmptyCap(text: "—", size: 11) }
                    else { KeyCaps(label: snippet.keyLabel, size: 11) }
                }
                .frame(minWidth: 52, alignment: .leading)

                Text(preview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(snippet.text.isEmpty ? Palette.faint : (selected ? Palette.fg : Palette.muted))
                    .italic(snippet.text.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if problem != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.danger)
                        .help(problem ?? "")
                }
                if !snippet.imageFiles.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "photo")
                        Text("\(snippet.imageFiles.count)").monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: UI.smallRadius + 1)
                .fill(selected ? Palette.accentSoft : (hover ? Palette.fg.opacity(0.05) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct DetailPane: View {
    @ObservedObject var store = Store.shared

    var body: some View {
        if store.snippets.isEmpty {
            EmptyStateView(icon: "keyboard", title: L("Chưa có phím tắt nào", "No shortcuts yet"),
                           message: L("Thêm phím tắt đầu tiên, ví dụ ⌃1 → số điện thoại của bạn.",
                                      "Add your first shortcut, e.g. ⌃1 → your phone number.")) {
                Button { store.addSnippet() } label: { Label(L("Thêm phím tắt", "Add shortcut"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } else if let id = store.selectedID, store.snippets.contains(where: { $0.id == id }) {
            SnippetDetail(snippetID: id).id(id)
        } else {
            EmptyStateView(icon: "sidebar.left", title: L("Chưa chọn phím tắt", "No shortcut selected"),
                           message: L("Chọn một mục bên trái hoặc tạo mới.", "Pick one on the left or create a new one.")) {
                EmptyView()
            }
        }
    }
}

struct EmptyStateView<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.faint)
            Text(title).font(.headline)
            Text(message)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            action().padding(.top, 4)
        }
        .padding(UI.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PermissionBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Palette.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Cần cấp quyền Trợ năng để dán", "Accessibility permission is needed to paste"))
                    .font(.callout.weight(.semibold))
                Text(L("Vào Privacy & Security → Accessibility và bật Gõ Tắt. Nếu đã bật mà vẫn thấy thông báo này, hãy xoá mục cũ (nút –) rồi thêm lại.",
                       "Open Privacy & Security → Accessibility and turn on Gõ Tắt. If it is already on and you still see this, remove the old entry (– button) and add it again."))
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UI.gap)
            Button(L("Mở cài đặt", "Open Settings")) { Paster.openAccessibilitySettings() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: UI.radius).fill(Palette.warn.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Palette.warn.opacity(0.4)))
    }
}

// MARK: - UI: snippet detail

struct SnippetDetail: View {
    @ObservedObject var store = Store.shared
    let snippetID: UUID
    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false
    @State private var confirmDelete = false
    @State private var note: String?
    @State private var dragging: String?   // ảnh đang được kéo để sắp xếp

    private var binding: Binding<Snippet>? {
        guard let i = store.snippets.firstIndex(where: { $0.id == snippetID }) else { return nil }
        return Binding(
            get: { store.snippets.indices.contains(i) ? store.snippets[i] : Snippet() },
            set: { if store.snippets.indices.contains(i) { store.snippets[i] = $0 } }
        )
    }

    var body: some View {
        if let b = binding {
            let s = b.wrappedValue
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header(s)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: L("Nội dung chữ", "Text"))
                        editor(b)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: s.imageFiles.isEmpty ? L("Ảnh", "Images")
                                                                : L("Ảnh · \(s.imageFiles.count)", "Images · \(s.imageFiles.count)"))
                        imageGrid(s)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: L("Khi nhấn phím", "When pressed"))
                        pasteFlow(s)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: UI.radius)
                        .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(RoundedRectangle(cornerRadius: UI.radius).fill(Palette.accentSoft.opacity(0.5)))
                        .overlay(Label(L("Thả ảnh vào đây", "Drop images here"), systemImage: "photo.badge.plus")
                            .font(.headline).foregroundStyle(Palette.accent))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                handleDrop(providers, id: s.id)
            }
            .confirmationDialog(L("Xoá phím tắt \(s.keyLabel.isEmpty ? "này" : s.keyLabel)?",
                                  "Delete shortcut \(s.keyLabel.isEmpty ? "" : s.keyLabel)?"),
                                isPresented: $confirmDelete) {
                Button(L("Xoá", "Delete"), role: .destructive) { store.remove(s.id) }
                Button(L("Huỷ", "Cancel"), role: .cancel) {}
            } message: {
                Text(s.imageFiles.isEmpty
                     ? L("Nội dung của phím tắt này sẽ bị xoá vĩnh viễn.", "This shortcut's content will be deleted permanently.")
                     : L("Nội dung và \(s.imageFiles.count) ảnh của phím tắt này sẽ bị xoá vĩnh viễn.",
                         "This shortcut's text and \(s.imageFiles.count) images will be deleted permanently."))
            }
        }
    }

    private func header(_ s: Snippet) -> some View {
        let recording = store.recordingID == s.id
        let problem = store.failed[s.id]
        return HStack(alignment: .top, spacing: UI.gap) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: L("Phím tắt", "Shortcut"))
                ShortcutButton(label: s.keyCode == nil ? "" : s.keyLabel, recording: recording, problem: problem,
                               size: 20, showAction: true) {
                    store.recordingID = recording ? nil : s.id
                }
                .padding(.leading, -8)
                ShortcutStatus(recording: recording, problem: problem)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UI.gap)
            DeleteButton {
                if s.text.isEmpty && s.imageFiles.isEmpty { store.remove(s.id) } else { confirmDelete = true }
            }
        }
    }

    private func editor(_ b: Binding<Snippet>) -> some View {
        let s = b.wrappedValue
        return VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: b.text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($editorFocused)
                    .onChange(of: editorFocused) { _, focused in
                        if focused { store.focusedID = s.id }
                        else if store.focusedID == s.id { store.focusedID = nil }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .accessibilityLabel(L("Nội dung dán", "Paste content"))
                if s.text.isEmpty {
                    Text(s.imageFiles.isEmpty ? L("Nhập nội dung sẽ được dán…", "Type what should be pasted…")
                                              : L("Thêm chữ (tuỳ chọn), sẽ dán trước ảnh…", "Add text (optional), pasted before the images…"))
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.faint)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 13)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 100, maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: UI.radius).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: UI.radius)
                .strokeBorder(editorFocused ? Palette.accent : Palette.line, lineWidth: editorFocused ? 1.5 : 1))

            Text(L("\(s.text.count) ký tự", "\(s.text.count) characters"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.faint)
        }
    }

    private func imageGrid(_ s: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(Array(s.imageFiles.enumerated()), id: \.element) { pos, name in
                    ThumbView(name: name, pos: pos, count: s.imageFiles.count, id: s.id, dragging: $dragging)
                }
                AddImageTile { chooseImages(for: s.id) }
            }
            .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }

            HStack(spacing: 10) {
                Button {
                    let imgs = Store.imagesFromPasteboard()
                    if imgs.isEmpty { flash(L("Clipboard không có ảnh", "No image in clipboard")) }
                    else { store.addImages(imgs, to: s.id) }
                } label: {
                    Label(L("Dán ảnh từ clipboard", "Paste image from clipboard"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(ChipButtonStyle())
                if let note {
                    Text(note).font(.caption).foregroundStyle(Palette.warn)
                }
            }
        }
    }

    private func pasteFlow(_ s: Snippet) -> some View {
        var steps: [String] = []
        if !s.text.isEmpty { steps.append(L("Chữ", "Text")) }
        steps += s.imageFiles.indices.map { L("Ảnh \($0 + 1)", "Image \($0 + 1)") }
        return Group {
            if steps.isEmpty {
                Text(L("Chưa có gì để dán", "Nothing to paste yet")).foregroundStyle(Palette.faint)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        if i > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.faint)
                                .frame(height: 24)
                        }
                        Text(step)
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UI.radius).fill(Palette.side))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Palette.line))
    }

    private func flash(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if note == text { note = nil } }
    }

    private func chooseImages(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        store.addImages(urls.compactMap { NSImage(contentsOf: $0) }, to: id)
    }

    /// Nhận nhiều ảnh kéo-thả cùng lúc, giữ nguyên thứ tự.
    private func handleDrop(_ providers: [NSItemProvider], id: UUID) -> Bool {
        guard !providers.isEmpty else { return false }
        var results = [NSImage?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (n, provider) in providers.enumerated() {
            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    let img = url.flatMap { NSImage(contentsOf: $0) }
                    lock.lock(); results[n] = img; lock.unlock()
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    lock.lock(); results[n] = obj as? NSImage; lock.unlock()
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let imgs = results.compactMap { $0 }
            if imgs.isEmpty { flash(L("Không đọc được ảnh", "Couldn't read the image")) } else { store.addImages(imgs, to: id) }
        }
        return true
    }
}

struct DeleteButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .frame(width: 34, height: 34)
                .foregroundStyle(hover ? Palette.danger : Palette.muted)
                .background(RoundedRectangle(cornerRadius: UI.smallRadius + 1).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: UI.smallRadius + 1)
                    .strokeBorder(hover ? Palette.danger : Palette.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Xoá phím tắt này", "Delete this shortcut"))
        .accessibilityLabel(L("Xoá phím tắt", "Delete shortcut"))
    }
}

/// Ô vuông "+ Thêm ảnh" nằm cuối lưới ảnh.
struct AddImageTile: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 20, weight: .light))
                        Text(L("Thêm ảnh", "Add image")).font(.system(size: 12, weight: .medium))
                        Text(L("hoặc kéo-thả, ⌘V", "or drag & drop, ⌘V"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(hover ? Palette.accent : Palette.faint)
                    }
                    .multilineTextAlignment(.center)
                    .padding(6)
                )
                .foregroundStyle(hover ? Palette.accent : Palette.muted)
                .background(RoundedRectangle(cornerRadius: UI.radius).fill(hover ? Palette.accentSoft : .clear))
                .overlay(RoundedRectangle(cornerRadius: UI.radius)
                    .strokeBorder(hover ? Palette.accent : Palette.capEdge, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Chọn ảnh từ máy", "Choose images from disk"))
    }
}

/// Ảnh thu nhỏ: số thứ tự, nút xoá khi rê chuột, kéo-thả để đổi chỗ.
struct ThumbView: View {
    @ObservedObject var store = Store.shared
    let name: String
    let pos: Int
    let count: Int
    let id: UUID
    @Binding var dragging: String?
    @State private var hover = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = Store.thumbnail(name) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Palette.field.overlay(Image(systemName: "photo").foregroundStyle(Palette.faint))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: UI.radius))
            .overlay(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Palette.line))
            .overlay(alignment: .topLeading) {
                Text("\(pos + 1)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button { store.removeImage(name, from: id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.62)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help(L("Xoá ảnh này", "Remove this image"))
                    .accessibilityLabel(L("Xoá ảnh \(pos + 1)", "Remove image \(pos + 1)"))
                }
            }
            .onHover { hover = $0 }
            .onDrag {
                dragging = name
                return NSItemProvider(object: name as NSString)
            }
            .onDrop(of: [.text], delegate: ReorderDropDelegate(name: name, id: id, dragging: $dragging))
            .contextMenu {
                Button(L("Dời lên trước", "Move earlier")) { store.moveImage(name, in: id, by: -1) }.disabled(pos == 0)
                Button(L("Dời ra sau", "Move later")) { store.moveImage(name, in: id, by: 1) }.disabled(pos == count - 1)
                Divider()
                Button(L("Xoá ảnh", "Remove image"), role: .destructive) { store.removeImage(name, from: id) }
            }
            .help(L("Kéo để đổi thứ tự", "Drag to reorder"))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Ảnh \(pos + 1)", "Image \(pos + 1)"))
    }
}

/// Khi kéo một ảnh qua ảnh khác, đổi chỗ ngay để thấy thứ tự mới.
struct ReorderDropDelegate: DropDelegate {
    let name: String
    let id: UUID
    @Binding var dragging: String?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != name,
              let to = Store.shared.snippets.first(where: { $0.id == id })?.imageFiles.firstIndex(of: name) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { Store.shared.moveImage(from, in: id, to: to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - App

let appName = "Gõ Tắt"

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var keyMonitor: Any?
    var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.applyTheme(Store.shared.theme)
        setupMainMenu()
        setupWindow()
        setupStatusItem()
        setupRecorder()
        log("Khởi động, quyền Trợ năng = \(AXIsProcessTrusted())")
        HotKeyManager.shared.installHandler()

        if !AXIsProcessTrusted() { Paster.requestAccessibility() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let t = AXIsProcessTrusted()
            if Store.shared.trusted != t { Store.shared.trusted = t }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    private func setupWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.nsSide // thanh tiêu đề liền màu với giao diện
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView())

        // Nút ngôn ngữ, sáng/tối, bật/tắt nằm bên phải thanh tiêu đề
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let controls = NSHostingView(rootView: TitleBarControls())
        controls.frame = NSRect(x: 0, y: 0, width: 330, height: 28)
        accessory.view = controls
        window.addTitlebarAccessoryViewController(accessory)

        window.center()
        window.setFrameAutosaveName("GoTatMain") // nhớ kích thước, vị trí cửa sổ
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleEnabled() {
        Store.shared.enabled.toggle()
    }

    /// Dựng lại menu khi đổi ngôn ngữ.
    func rebuildMenus() {
        setupMainMenu()
        statusItem?.menu = buildStatusMenu()
        refreshStatusItem()
    }

    /// Icon thanh menu mờ đi khi đang tạm dừng.
    func refreshStatusItem() {
        let on = Store.shared.enabled
        statusItem?.button?.appearsDisabled = !on
        statusItem?.button?.toolTip = on ? L("\(appName): đang bật", "\(appName): on")
                                         : L("\(appName): đang tạm dừng", "\(appName): paused")
        toggleItem?.state = on ? .on : .off
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: appName)
        statusItem.menu = buildStatusMenu()
        refreshStatusItem()
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("Mở \(appName)", "Open \(appName)"), action: #selector(showWindow), keyEquivalent: ""))
        toggleItem = NSMenuItem(title: L("Bật phím tắt", "Enable shortcuts"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.state = Store.shared.enabled ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Thoát", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        menu.delegate = self
        return menu
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L("Đóng cửa sổ", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Thoát \(appName)", "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("Sửa", "Edit"))
        edit.addItem(NSMenuItem(title: L("Hoàn tác", "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: L("Cắt", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("Sao chép", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("Dán", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("Chọn tất cả", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    /// Bắt phím khi người dùng đang ghi phím tắt,
    /// và cho phép ⌘V / ⌃V dán ảnh vào phím tắt đang mở.
    private func setupRecorder() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let store = Store.shared
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Đang gõ trong ô nội dung → dán vào dòng đó; không gõ ở ô nào → dán vào phím tắt đang chọn
            let typing = NSApp.keyWindow?.firstResponder is NSText
            let pasteTarget = store.focusedID ?? (typing || NSApp.keyWindow !== self?.window ? nil : store.selectedID)
            if store.recordingID == nil, let id = pasteTarget,
               Int(event.keyCode) == kVK_ANSI_V, mods == .command || mods == .control {
                let imgs = Store.imagesFromPasteboard()
                if !imgs.isEmpty {
                    store.addImages(imgs, to: id)
                    return nil
                }
                if mods == .control && typing { // ⌃V dán chữ giống ⌘V
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    return nil
                }
                return event
            }

            guard let target = store.recordingID else { return event }

            /// Cập nhật phím cho dòng đang ghi (hoặc phím mở app).
            func apply(_ update: (inout Snippet) -> Void) {
                if target == Store.openKeyID {
                    update(&store.openKey)
                } else if let i = store.snippets.firstIndex(where: { $0.id == target }) {
                    update(&store.snippets[i])
                }
            }

            let code = Int(event.keyCode)
            switch code {
            case kVK_Escape:
                break
            case kVK_Delete:
                apply { $0.keyCode = nil; $0.modifiers = 0; $0.keyLabel = "" }
            default:
                let modifiers = KeyNames.carbonModifiers(event.modifierFlags)
                let strong = modifiers & UInt32(cmdKey | controlKey | optionKey)
                // Phím đơn (chữ, số…) sẽ chặn việc gõ phím đó ở mọi app, nên bắt buộc kèm ⌃ ⌥ hoặc ⌘
                if strong == 0 && !KeyNames.isFunctionKey(code) {
                    NSSound.beep()
                    store.recordHint = L("Cần kèm ⌃, ⌥ hoặc ⌘", "Add ⌃, ⌥ or ⌘")
                    return nil
                }
                apply {
                    $0.keyCode = UInt32(code)
                    $0.modifiers = modifiers
                    $0.keyLabel = KeyNames.label(for: event)
                }
            }
            store.recordingID = nil
            return nil
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusItem()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
