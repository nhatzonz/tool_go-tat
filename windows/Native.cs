using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using static GoTat.Loc;

namespace GoTat;

static class Win32
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    /// Thanh tiêu đề tối/sáng theo giao diện app (Windows 10 20H1+ và Windows 11).
    public static void SetDarkTitleBar(Window w, bool dark)
    {
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == IntPtr.Zero) return;
        int v = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref v, sizeof(int));
    }
}

// MARK: - Phím tắt toàn hệ thống

public class HotKeys
{
    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;
    public const int OpenId = 9999;

    IntPtr hwnd;
    readonly List<int> registered = new();
    readonly Dictionary<int, Guid> map = new();

    /// id phím tắt -> lý do không hoạt động
    public Dictionary<Guid, string> Failed { get; } = new();

    /// Gọi khi nhấn phím tắt; Store.OpenKeyId nghĩa là phím mở app.
    public event Action<Guid>? Fired;

    public void Attach(Window w)
    {
        hwnd = new WindowInteropHelper(w).EnsureHandle();
        HwndSource.FromHwnd(hwnd).AddHook(Hook);
    }

    /// Đăng ký lại toàn bộ phím tắt. Khi đang ghi phím thì tắt hết để bắt được tổ hợp mới.
    public void Reload(bool recording)
    {
        foreach (var id in registered) Win32.UnregisterHotKey(hwnd, id);
        registered.Clear();
        map.Clear();
        Failed.Clear();
        if (recording) return;

        var seen = new Dictionary<string, string>(); // tổ hợp -> nơi đang dùng
        var open = Store.Settings.OpenKey;
        if (open.KeyCode is uint oc)
        {
            if (Register(OpenId, open.Modifiers, oc)) seen[$"{oc}-{open.Modifiers}"] = L("phím mở app", "the open-app key");
            else Failed[Store.OpenKeyId] = L("Bị Windows hoặc app khác dùng", "Taken by Windows or another app");
        }
        if (!Store.Settings.Enabled) return;

        for (int i = 0; i < Store.Snippets.Count; i++)
        {
            var s = Store.Snippets[i];
            if (s.KeyCode is not uint code) continue;
            var combo = $"{code}-{s.Modifiers}";
            if (seen.TryGetValue(combo, out var owner)) { Failed[s.Id] = L($"Trùng với {owner}", $"Same as {owner}"); continue; }
            seen[combo] = L($"phím tắt #{i + 1}", $"shortcut #{i + 1}");
            if (Register(i + 1, s.Modifiers, code)) map[i + 1] = s.Id;
            else Failed[s.Id] = L("Bị Windows hoặc app khác dùng", "Taken by Windows or another app");
        }
    }

    bool Register(int id, uint mods, uint vk)
    {
        if (!Win32.RegisterHotKey(hwnd, id, mods | MOD_NOREPEAT, vk)) return false;
        registered.Add(id);
        return true;
    }

    IntPtr Hook(IntPtr h, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_HOTKEY) return IntPtr.Zero;
        int id = wParam.ToInt32();
        if (id == OpenId) Fired?.Invoke(Store.OpenKeyId);
        else if (map.TryGetValue(id, out var g)) Fired?.Invoke(g);
        handled = true;
        return IntPtr.Zero;
    }
}

// MARK: - Dán qua clipboard + Ctrl+V

public static class Paster
{
    static bool busy;

    /// Dán chữ trước (nếu có), sau đó lần lượt từng ảnh theo thứ tự, rồi trả lại clipboard cũ.
    public static async void Paste(Snippet s)
    {
        if (busy) return;
        var steps = new List<Action>();
        if (s.Text.Length > 0)
        {
            var text = s.Text;
            steps.Add(() => Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), true));
        }
        foreach (var name in s.ImageFiles)
        {
            var path = Store.ImagePath(name);
            if (!File.Exists(path)) continue;
            steps.Add(() =>
            {
                var data = new DataObject();
                if (Store.LoadImage(name) is BitmapSource img) data.SetImage(img);
                data.SetData("PNG", new MemoryStream(File.ReadAllBytes(path)));
                Clipboard.SetDataObject(data, true);
            });
        }
        if (steps.Count == 0) return;

        busy = true;
        try
        {
            var saved = SaveClipboard();
            uint seq = 0;
            for (int i = 0; i < steps.Count; i++)
            {
                if (!Retry(steps[i])) return;
                seq = Win32.GetClipboardSequenceNumber();
                SendCtrlV();
                await Task.Delay(i + 1 < steps.Count ? 400 : 800);
            }
            // Người dùng chưa copy thứ khác trong lúc dán thì trả lại clipboard cũ
            if (saved != null && Win32.GetClipboardSequenceNumber() == seq) Retry(() => Clipboard.SetDataObject(saved, true));
        }
        finally { busy = false; }
    }

    /// Clipboard hay bị app khác giữ trong tích tắc, nên thử lại vài lần.
    static bool Retry(Action a)
    {
        for (int i = 0; i < 6; i++)
        {
            try { a(); return true; }
            catch (ExternalException) { Thread.Sleep(40); }
        }
        return false;
    }

    static DataObject? SaveClipboard()
    {
        try
        {
            var src = Clipboard.GetDataObject();
            if (src == null) return null;
            var copy = new DataObject();
            foreach (var f in src.GetFormats(false))
            {
                try { if (src.GetData(f, false) is object d) copy.SetData(f, d, false); } catch { }
            }
            return copy.GetFormats().Length > 0 ? copy : null;
        }
        catch { return null; }
    }

    static void SendCtrlV()
    {
        const ushort VK_CONTROL = 0x11, VK_V = 0x56;
        var inputs = new List<Win32.INPUT> { Key(VK_CONTROL, false) };
        // Nhả Shift / Alt / Win đang giữ của phím tắt, nếu không ứng dụng sẽ nhận Ctrl+Alt+V…
        foreach (ushort vk in new ushort[] { 0x10, 0x12, 0x5B, 0x5C })
            if ((Win32.GetAsyncKeyState(vk) & 0x8000) != 0) inputs.Add(Key(vk, true));
        inputs.Add(Key(VK_V, false));
        inputs.Add(Key(VK_V, true));
        inputs.Add(Key(VK_CONTROL, true));
        var arr = inputs.ToArray();
        Win32.SendInput((uint)arr.Length, arr, Marshal.SizeOf<Win32.INPUT>());
    }

    static Win32.INPUT Key(ushort vk, bool up)
    {
        uint flags = up ? 2u : 0u;                 // KEYEVENTF_KEYUP
        if (vk is 0x5B or 0x5C) flags |= 1u;       // phím Win là phím mở rộng
        return new Win32.INPUT { type = 1, U = new Win32.InputUnion { ki = new Win32.KEYBDINPUT { wVk = vk, dwFlags = flags } } };
    }
}

// MARK: - Đọc ảnh từ clipboard / file

public static class ImageInput
{
    static readonly string[] Exts = { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff" };

    public static List<BitmapSource> FromFiles(IEnumerable<string> paths)
    {
        var list = new List<BitmapSource>();
        foreach (var p in paths.Where(p => Exts.Contains(Path.GetExtension(p).ToLowerInvariant()))
                               .OrderBy(p => Path.GetFileName(p), StringComparer.CurrentCultureIgnoreCase))
        {
            try
            {
                var img = new BitmapImage();
                img.BeginInit();
                img.CacheOption = BitmapCacheOption.OnLoad;
                img.UriSource = new Uri(p);
                img.EndInit();
                img.Freeze();
                list.Add(img);
            }
            catch { }
        }
        return list;
    }

    /// Ảnh trong clipboard: ưu tiên file ảnh copy từ Explorer, sau đó tới dữ liệu ảnh.
    /// Trả về rỗng nếu clipboard là chữ, để ô nội dung dán chữ như bình thường.
    public static List<BitmapSource> FromClipboard()
    {
        try
        {
            if (Clipboard.ContainsFileDropList())
                return FromFiles(Clipboard.GetFileDropList().Cast<string>());
            if (Clipboard.ContainsText()) return new();
            if (Clipboard.GetData("PNG") is MemoryStream png)
            {
                var dec = BitmapDecoder.Create(png, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                return new() { dec.Frames[0] };
            }
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is BitmapSource img) return new() { img };
        }
        catch { }
        return new();
    }
}
