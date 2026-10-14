using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace GoTat;

// MARK: - Ngôn ngữ

public static class Loc
{
    public static string Lang = "vi";

    /// Chọn chuỗi theo ngôn ngữ đang dùng (mặc định tiếng Việt).
    public static string L(string vi, string en) => Lang == "en" ? en : vi;
}

// MARK: - Dữ liệu

public class Snippet
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public uint? KeyCode { get; set; }          // mã phím ảo Windows, null = chưa gán
    public uint Modifiers { get; set; }         // MOD_ALT=1, MOD_CONTROL=2, MOD_SHIFT=4, MOD_WIN=8
    public string KeyLabel { get; set; } = "";  // vd. "Ctrl+Alt+1"
    public string Text { get; set; } = "";
    public List<string> ImageFiles { get; set; } = new(); // tên file PNG trong thư mục images, dán theo thứ tự
}

public class Settings
{
    public string Lang { get; set; } = "vi";
    public string Theme { get; set; } = "";     // "light", "dark" hoặc "" = theo Windows
    public bool Enabled { get; set; } = true;
    public Snippet OpenKey { get; set; } = new() { KeyCode = 0x70, Modifiers = 2, KeyLabel = "Ctrl+F1" };
}

public static class Store
{
    public static readonly Guid OpenKeyId = new("00000000-0000-0000-0000-000000000001");
    public static readonly string BaseDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "GoTat");
    static string ImagesDir => Path.Combine(BaseDir, "images");
    static string SnippetsFile => Path.Combine(BaseDir, "snippets.json");
    static string SettingsFile => Path.Combine(BaseDir, "settings.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public static List<Snippet> Snippets = new();
    public static Settings Settings = new();

    public static void Load()
    {
        Directory.CreateDirectory(ImagesDir);
        if (File.Exists(SnippetsFile))
        {
            try { Snippets = JsonSerializer.Deserialize<List<Snippet>>(File.ReadAllText(SnippetsFile), Json) ?? new(); }
            catch { File.Copy(SnippetsFile, SnippetsFile + ".bak", true); Snippets = new(); } // giữ lại file hỏng để cứu dữ liệu
        }
        if (File.Exists(SettingsFile))
        {
            try { Settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsFile), Json) ?? new(); }
            catch { Settings = new(); }
        }
        Settings.OpenKey.Id = OpenKeyId;
        Loc.Lang = Settings.Lang;
    }

    public static void Save() => File.WriteAllText(SnippetsFile, JsonSerializer.Serialize(Snippets, Json));
    public static void SaveSettings() => File.WriteAllText(SettingsFile, JsonSerializer.Serialize(Settings, Json));

    public static string ImagePath(string name) => Path.Combine(ImagesDir, name);

    /// Lưu các ảnh dưới dạng PNG và thêm vào cuối danh sách ảnh.
    public static void AddImages(Snippet s, IEnumerable<BitmapSource> images)
    {
        foreach (var img in images)
        {
            var name = Guid.NewGuid() + ".png";
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(img));
            using (var fs = File.Create(ImagePath(name))) enc.Save(fs);
            s.ImageFiles.Add(name);
        }
        Save();
    }

    public static void RemoveImage(Snippet s, string name)
    {
        s.ImageFiles.Remove(name);
        Thumbs.Remove(name);
        try { File.Delete(ImagePath(name)); } catch { }
        Save();
    }

    public static void MoveImage(Snippet s, string name, int to)
    {
        int from = s.ImageFiles.IndexOf(name);
        if (from < 0 || from == to || to < 0 || to >= s.ImageFiles.Count) return;
        s.ImageFiles.RemoveAt(from);
        s.ImageFiles.Insert(to, name);
        Save();
    }

    public static void Remove(Snippet s)
    {
        foreach (var name in s.ImageFiles.ToList()) { Thumbs.Remove(name); try { File.Delete(ImagePath(name)); } catch { } }
        Snippets.Remove(s);
        Save();
    }

    /// Ảnh thu nhỏ có cache, đọc hết vào bộ nhớ để không khoá file.
    static readonly Dictionary<string, BitmapImage> Thumbs = new();
    public static BitmapImage? Thumbnail(string name)
    {
        if (Thumbs.TryGetValue(name, out var cached)) return cached;
        var img = LoadImage(name, 240);
        if (img != null) Thumbs[name] = img;
        return img;
    }

    public static BitmapImage? LoadImage(string name, int decodeWidth = 0)
    {
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.UriSource = new Uri(ImagePath(name));
            if (decodeWidth > 0) img.DecodePixelWidth = decodeWidth;
            img.EndInit();
            img.Freeze();
            return img;
        }
        catch { return null; }
    }
}

// MARK: - Giao diện sáng / tối

public static class Theme
{
    static readonly Dictionary<string, (uint Light, uint Dark)> Tokens = new()
    {
        ["Win"] = (0xFBFCFC, 0x161D1C),
        ["Side"] = (0xF2F5F4, 0x121918),
        ["Line"] = (0xDDE4E2, 0x26302E),
        ["Field"] = (0xFFFFFF, 0x1C2523),
        ["Hover"] = (0xE7EDEB, 0x202A28),
        ["Fg"] = (0x16211F, 0xE6EEEC),
        ["Muted"] = (0x5F6F6C, 0x93A4A0),
        ["Faint"] = (0x97A5A2, 0x5D6D69),
        ["Accent"] = (0x0E8F7E, 0x2FC2AB),
        ["AccentSoft"] = (0xDFF3EF, 0x163A34),
        ["AccentFg"] = (0xFFFFFF, 0x06221D),
        ["Cap"] = (0xFFFFFF, 0x26302E),
        ["CapEdge"] = (0xC9D3D1, 0x0B100F),
        ["Danger"] = (0xD1453B, 0xF0675C),
        ["Warn"] = (0xC27C0E, 0xE8A43A),
    };

    public static bool IsDark { get; private set; }

    public static void Apply(string preference)
    {
        IsDark = preference == "dark" || (preference == "" && SystemPrefersDark());
        foreach (var (key, v) in Tokens) Application.Current.Resources[key] = Brush(IsDark ? v.Dark : v.Light);
    }

    static bool SystemPrefersDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    public static SolidColorBrush Brush(uint hex)
    {
        var b = new SolidColorBrush(Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex));
        b.Freeze();
        return b;
    }

    public static Brush B(string key) => (Brush)Application.Current.Resources[key];
}
