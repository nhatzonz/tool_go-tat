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
        didSet { HotKeyManager.shared.reload() }
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
        didSet { HotKeyManager.shared.reload() }
    }
    @Published var failed: Set<UUID> = []
    @Published var trusted = AXIsProcessTrusted()

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

    func remove(_ id: UUID) {
        if recordingID == id { recordingID = nil }
        snippets.first(where: { $0.id == id })?.imageFiles.forEach {
            try? FileManager.default.removeItem(at: Store.imageURL($0))
        }
        snippets.removeAll { $0.id == id }
    }

    private init() {}

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

        var failed = Set<UUID>()
        var seen = Set<String>()
        // Phím mở app luôn hoạt động (kể cả khi tắt phím tắt dán), trừ lúc đang ghi phím
        if store.recordingID == nil, let code = open.keyCode {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x444E_4E48), id: HotKeyManager.openHotKeyID)
            let status = RegisterEventHotKey(code, open.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
            log("Đăng ký phím mở app \(open.keyLabel) -> status \(status)")
            if status == noErr, let ref { refs.append(ref); seen.insert("\(code)-\(open.modifiers)") }
            else { failed.insert(Store.openKeyID) }
        }
        if active {
            for (i, s) in store.snippets.enumerated() {
                guard let code = s.keyCode else { continue }
                let combo = "\(code)-\(s.modifiers)"
                if !seen.insert(combo).inserted { failed.insert(s.id); continue }
                let hkID = EventHotKeyID(signature: OSType(0x444E_4E48), id: UInt32(i + 1))
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(code, s.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
                log("Đăng ký \(s.keyLabel) (code \(code), mods \(s.modifiers)) -> status \(status)")
                if status == noErr, let ref {
                    refs.append(ref)
                    idMap[UInt32(i + 1)] = s.id
                } else {
                    failed.insert(s.id)
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

// MARK: - UI

struct ContentView: View {
    @ObservedObject var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Bật phím tắt", isOn: $store.enabled)
                Divider().frame(height: 16)
                Text("Phím mở app:")
                let recordingOpen = store.recordingID == Store.openKeyID
                Button {
                    store.recordingID = recordingOpen ? nil : Store.openKeyID
                } label: {
                    Text(recordingOpen ? "Nhấn phím…" : (store.openKey.keyCode == nil ? "Chưa đặt" : store.openKey.keyLabel))
                        .frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .tint(recordingOpen ? .accentColor : (store.failed.contains(Store.openKeyID) ? .red : nil))
                .help("Nhấn phím này ở bất kỳ đâu để mở cửa sổ Dán Nhanh")
                Spacer()
                if store.trusted {
                    Label("Đã cấp quyền", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                } else {
                    Button("Cấp quyền Trợ năng (Accessibility)…") { Paster.requestAccessibility() }
                        .foregroundColor(.red)
                }
            }

            Text("Bấm vào ô phím tắt rồi nhấn tổ hợp phím muốn dùng (Esc để huỷ, ⌫ để xoá).")
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(store.snippets.enumerated()), id: \.element.id) { index, snippet in
                        SnippetRow(index: index + 1, snippetID: snippet.id)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button {
                    store.snippets.append(Snippet())
                } label: {
                    Label("Thêm phím tắt", systemImage: "plus")
                }
                Spacer()
                Text("Mẹo: phím F trên Mac có thể cần giữ fn, hoặc bật “Dùng F1, F2… làm phím chức năng chuẩn”.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 460)
    }
}

struct SnippetRow: View {
    @ObservedObject var store = Store.shared
    let index: Int
    let snippetID: UUID
    @FocusState private var editorFocused: Bool

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
            let recording = store.recordingID == s.id
            let failed = store.failed.contains(s.id)

            HStack(alignment: .top, spacing: 10) {
                Text("\(index)").font(.headline).frame(width: 22).padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        store.recordingID = recording ? nil : s.id
                    } label: {
                        Text(recording ? "Nhấn phím…" : (s.keyCode == nil ? "Đặt phím tắt" : s.keyLabel))
                            .frame(width: 120)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(recording ? .accentColor : (failed ? .red : nil))

                    if failed {
                        Text("Trùng hoặc đã bị app khác chiếm")
                            .font(.caption2).foregroundColor(.red).frame(width: 130, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: b.text)
                        .focused($editorFocused)
                        .onChange(of: editorFocused) { _, focused in
                            if focused { store.focusedID = s.id }
                            else if store.focusedID == s.id { store.focusedID = nil }
                        }
                        .font(.body)
                        .frame(minHeight: 54, maxHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))

                    if !s.imageFiles.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(Array(s.imageFiles.enumerated()), id: \.element) { pos, name in
                                    thumbnail(name: name, pos: pos, count: s.imageFiles.count, id: s.id)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Thêm ảnh…") { chooseImages(for: s.id) }
                        Button("Lấy ảnh từ clipboard") {
                            let imgs = Store.imagesFromPasteboard()
                            if imgs.isEmpty { NSSound.beep() } else { store.addImages(imgs, to: s.id) }
                        }
                        Text(s.imageFiles.isEmpty ? "hoặc kéo-thả ảnh vào đây"
                                                  : "\(s.imageFiles.count) ảnh · kéo-thả để thêm")
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                    handleDrop(providers, id: s.id)
                }

                Button(role: .destructive) {
                    store.remove(s.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
        }
    }

    private func thumbnail(name: String, pos: Int, count: Int, id: UUID) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topLeading) {
                if let img = NSImage(contentsOf: Store.imageURL(name)) {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 84, height: 84).clipped()
                } else {
                    Color.secondary.opacity(0.2).frame(width: 84, height: 84)
                }
                Text("\(pos + 1)").font(.caption2.bold()).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.6))).padding(3)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
            .cornerRadius(4)

            HStack(spacing: 6) {
                Button { store.moveImage(name, in: id, by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(pos == 0).help("Dời lên trước")
                Button { store.removeImage(name, from: id) } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundColor(.red).help("Xoá ảnh này")
                Button { store.moveImage(name, in: id, by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(pos == count - 1).help("Dời ra sau")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
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
        group.notify(queue: .main) { store.addImages(results.compactMap { $0 }, to: id) }
        return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var keyMonitor: Any?
    var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Dán Nhanh"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleEnabled() {
        Store.shared.enabled.toggle()
        toggleItem.state = Store.shared.enabled ? .on : .off
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Dán Nhanh")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mở cài đặt", action: #selector(showWindow), keyEquivalent: ""))
        toggleItem = NSMenuItem(title: "Bật phím tắt", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.state = Store.shared.enabled ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Thoát", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        menu.delegate = self
        statusItem.menu = menu
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Thoát Dán Nhanh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Sửa")
        edit.addItem(NSMenuItem(title: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    /// Bắt phím khi người dùng đang ghi phím tắt cho một dòng,
    /// và cho phép ⌘V / ⌃V dán ảnh vào dòng đang soạn.
    private func setupRecorder() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let store = Store.shared
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if store.recordingID == nil, let id = store.focusedID,
               Int(event.keyCode) == kVK_ANSI_V, mods == .command || mods == .control {
                let imgs = Store.imagesFromPasteboard()
                if !imgs.isEmpty {
                    store.addImages(imgs, to: id)
                    return nil
                }
                if mods == .control { // ⌃V dán chữ giống ⌘V
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    return nil
                }
                return event
            }

            if store.recordingID == Store.openKeyID {
                switch Int(event.keyCode) {
                case kVK_Escape: break
                case kVK_Delete: store.openKey.keyCode = nil; store.openKey.keyLabel = ""
                default:
                    store.openKey.keyCode = UInt32(event.keyCode)
                    store.openKey.modifiers = KeyNames.carbonModifiers(event.modifierFlags)
                    store.openKey.keyLabel = KeyNames.label(for: event)
                }
                store.recordingID = nil
                return nil
            }

            guard let id = store.recordingID,
                  let i = store.snippets.firstIndex(where: { $0.id == id }) else { return event }

            switch Int(event.keyCode) {
            case kVK_Escape:
                break
            case kVK_Delete:
                store.snippets[i].keyCode = nil
                store.snippets[i].modifiers = 0
                store.snippets[i].keyLabel = ""
            default:
                store.snippets[i].keyCode = UInt32(event.keyCode)
                store.snippets[i].modifiers = KeyNames.carbonModifiers(event.modifierFlags)
                store.snippets[i].keyLabel = KeyNames.label(for: event)
            }
            store.recordingID = nil
            return nil
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        toggleItem.state = Store.shared.enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
