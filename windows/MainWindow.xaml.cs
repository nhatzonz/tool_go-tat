using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using static GoTat.Loc;
using WF = System.Windows.Forms;

namespace GoTat;

public partial class MainWindow : Window
{
    readonly HotKeys hotKeys = new();
    WF.NotifyIcon? tray;
    Guid? selectedId;
    Guid? recordingId;     // phím tắt đang chờ nhấn tổ hợp phím (Store.OpenKeyId = phím mở app)
    string? recordHint;    // nhắc lỗi khi ghi phím không hợp lệ
    string? note;          // thông báo ngắn dưới lưới ảnh
    bool quitting, trayTipShown;

    // Các phần của khung chi tiết được cập nhật riêng, để không mất con trỏ khi đang gõ
    TextBlock? imagesLabel, noteText;
    WrapPanel? imagesPanel, flowPanel;

    static readonly Brush Shade = new SolidColorBrush(Color.FromArgb(0xA0, 0, 0, 0));

    public MainWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => Win32.SetDarkTitleBar(this, Theme.IsDark);
        selectedId = Store.Snippets.FirstOrDefault()?.Id;
        hotKeys.Attach(this);
        hotKeys.Fired += OnHotKey;
        PreviewKeyDown += OnPreviewKeyDown;
        Closing += (_, e) =>
        {
            if (quitting) return;
            e.Cancel = true;   // đóng cửa sổ = ẩn xuống khay, phím tắt vẫn chạy
            Hide();
            ShowTrayTip();
        };
        SetupTray();
        hotKeys.Reload(false);
        RenderAll();
    }

    static Brush B(string key) => Theme.B(key);
    Snippet? Selected() => Store.Snippets.FirstOrDefault(x => x.Id == selectedId);
    static Snippet? Find(Guid id) => Store.Snippets.FirstOrDefault(x => x.Id == id);

    public void ShowFromTray()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
    }

    void OnHotKey(Guid id)
    {
        if (id == Store.OpenKeyId) { ShowFromTray(); return; }
        if (Find(id) is Snippet s) Paster.Paste(s);
    }

    void ReloadHotKeys() => hotKeys.Reload(recordingId != null);

    // MARK: - Khay hệ thống

    void SetupTray()
    {
        tray = new WF.NotifyIcon { Visible = true };
        try { tray.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { }
        tray.DoubleClick += (_, _) => ShowFromTray();
        BuildTrayMenu();
    }

    void BuildTrayMenu()
    {
        if (tray == null) return;
        var menu = new WF.ContextMenuStrip();
        menu.Items.Add(L("Mở Gõ Tắt", "Open Gõ Tắt"), null, (_, _) => ShowFromTray());
        var toggle = new WF.ToolStripMenuItem(L("Bật phím tắt", "Enable shortcuts")) { Checked = Store.Settings.Enabled };
        toggle.Click += (_, _) => SetEnabled(!Store.Settings.Enabled);
        menu.Items.Add(toggle);
        menu.Items.Add(new WF.ToolStripSeparator());
        menu.Items.Add(L("Thoát", "Quit"), null, (_, _) => Quit());
        var old = tray.ContextMenuStrip;
        tray.ContextMenuStrip = menu;
        old?.Dispose();
        tray.Text = Store.Settings.Enabled ? L("Gõ Tắt: đang bật", "Gõ Tắt: on") : L("Gõ Tắt: đang tạm dừng", "Gõ Tắt: paused");
    }

    void ShowTrayTip()
    {
        if (trayTipShown || tray == null) return;
        trayTipShown = true;
        var key = Store.Settings.OpenKey.KeyLabel;
        tray.ShowBalloonTip(4000, "Gõ Tắt",
            key.Length > 0 ? L($"App vẫn chạy ở khay hệ thống. Nhấn {key} để mở lại.", $"Still running in the system tray. Press {key} to open it.")
                           : L("App vẫn chạy ở khay hệ thống.", "Still running in the system tray."),
            WF.ToolTipIcon.Info);
    }

    void Quit()
    {
        quitting = true;
        if (tray != null) { tray.Visible = false; tray.Dispose(); }
        Application.Current.Shutdown();
    }

    // MARK: - Thanh trên

    void FlagVi_Click(object sender, RoutedEventArgs e) => SetLang("vi");
    void FlagEn_Click(object sender, RoutedEventArgs e) => SetLang("en");

    void SetLang(string lang)
    {
        Store.Settings.Lang = Loc.Lang = lang;
        Store.SaveSettings();
        ReloadHotKeys(); // câu báo lỗi phím tắt đổi theo ngôn ngữ
        BuildTrayMenu();
        RenderAll();
    }

    void ThemeBtn_Click(object sender, RoutedEventArgs e)
    {
        Store.Settings.Theme = Theme.IsDark ? "light" : "dark";
        Store.SaveSettings();
        Theme.Apply(Store.Settings.Theme);
        Win32.SetDarkTitleBar(this, Theme.IsDark);
        RenderAll();
    }

    void EnabledSwitch_Click(object sender, RoutedEventArgs e) => SetEnabled(EnabledSwitch.IsChecked == true);

    void SetEnabled(bool on)
    {
        Store.Settings.Enabled = on;
        Store.SaveSettings();
        ReloadHotKeys();
        BuildTrayMenu();
        RenderAll();
    }

    // MARK: - Vẽ giao diện

    void RenderAll()
    {
        RenderChrome();
        RenderSidebar();
        RenderFooter();
        RenderDetail();
    }

    void RenderChrome()
    {
        bool vi = Loc.Lang != "en";
        FlagVi.Background = vi ? B("AccentSoft") : Brushes.Transparent;
        FlagEn.Background = vi ? Brushes.Transparent : B("AccentSoft");
        FlagVi.Opacity = vi ? 1 : 0.45;
        FlagEn.Opacity = vi ? 0.45 : 1;

        ThemeIcon.Text = Theme.IsDark ? "" : "";
        ThemeBtn.ToolTip = Theme.IsDark ? L("Chuyển sang giao diện sáng", "Switch to light mode")
                                        : L("Chuyển sang giao diện tối", "Switch to dark mode");

        bool on = Store.Settings.Enabled;
        StatusDot.Fill = on ? B("Accent") : B("Warn");
        StatusText.Text = on ? L("Đang hoạt động", "Active") : L("Tạm dừng", "Paused");
        EnabledSwitch.IsChecked = on;
        EnabledSwitch.ToolTip = on ? L("Tạm dừng tất cả phím tắt dán", "Pause all paste shortcuts")
                                   : L("Bật lại phím tắt dán", "Turn paste shortcuts back on");

        SearchHint.Text = L("Tìm nội dung hoặc phím", "Search text or keys");
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        AddLabel.Text = L("Phím tắt mới", "New shortcut");
        AddBtn.ToolTip = L("Thêm phím tắt mới (Ctrl+N)", "Add a new shortcut (Ctrl+N)");
        DropText.Text = L("Thả ảnh vào đây", "Drop images here");
    }

    void RenderSidebar()
    {
        SidebarList.Children.Clear();
        var q = SearchBox.Text.Trim();
        var rows = Store.Snippets.Where(s => q.Length == 0
            || s.Text.Contains(q, StringComparison.CurrentCultureIgnoreCase)
            || s.KeyLabel.Contains(q, StringComparison.CurrentCultureIgnoreCase)).ToList();

        if (rows.Count == 0)
        {
            SidebarList.Children.Add(new TextBlock
            {
                Text = q.Length == 0 ? L("Chưa có phím tắt", "No shortcuts yet") : L("Không tìm thấy", "No matches"),
                Foreground = B("Faint"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 24, 0, 0),
            });
            return;
        }

        foreach (var s in rows) SidebarList.Children.Add(SidebarRow(s));
    }

    UIElement SidebarRow(Snippet s)
    {
        bool selected = s.Id == selectedId;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var keys = s.KeyCode == null ? DashedCap("—", 11, B("Faint")) : Caps(s.KeyLabel, 11);
        var keyBox = new Border { MinWidth = 62, Child = keys, Margin = new Thickness(0, 0, 10, 0) };
        grid.Children.Add(keyBox);

        var firstLine = s.Text.Split('\n').FirstOrDefault()?.Trim() ?? "";
        var preview = new TextBlock
        {
            Text = firstLine.Length > 0 ? firstLine : (s.ImageFiles.Count > 0 ? L("Chỉ ảnh", "Images only") : L("Trống", "Empty")),
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = firstLine.Length == 0 ? B("Faint") : (selected ? B("Fg") : B("Muted")),
            FontStyle = firstLine.Length == 0 ? FontStyles.Italic : FontStyles.Normal,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(preview, 1);
        grid.Children.Add(preview);

        if (hotKeys.Failed.TryGetValue(s.Id, out var problem))
        {
            var warn = Glyph("", 12, B("Danger"));
            warn.Margin = new Thickness(6, 0, 0, 0);
            warn.ToolTip = problem;
            Grid.SetColumn(warn, 2);
            grid.Children.Add(warn);
        }
        if (s.ImageFiles.Count > 0)
        {
            var badge = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0) };
            badge.Children.Add(Glyph("", 11, B("Muted")));
            badge.Children.Add(new TextBlock { Text = s.ImageFiles.Count.ToString(), FontSize = 11, Foreground = B("Muted"), Margin = new Thickness(3, 0, 0, 0) });
            Grid.SetColumn(badge, 3);
            grid.Children.Add(badge);
        }

        var row = new Button
        {
            Style = (Style)FindResource("Plain"), Tag = "8", Content = grid,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(0, 0, 0, 2),
            Background = selected ? B("AccentSoft") : Brushes.Transparent,
        };
        if (!selected)
        {
            row.MouseEnter += (_, _) => row.Background = B("Hover");
            row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
        }
        row.Click += (_, _) =>
        {
            if (recordingId != null && recordingId != s.Id) { recordingId = null; ReloadHotKeys(); }
            selectedId = s.Id;
            RenderSidebar();
            RenderFooter();
            RenderDetail();
        };
        return row;
    }

    void RenderFooter()
    {
        Footer.Children.Clear();
        var open = Store.Settings.OpenKey;
        bool rec = recordingId == Store.OpenKeyId;
        var line = new DockPanel { LastChildFill = false };
        line.Children.Add(new TextBlock { Text = L("Mở app nhanh", "Open app"), Foreground = B("Muted"), FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center });
        var btn = ShortcutButton(open.KeyCode == null ? "" : open.KeyLabel, rec, hotKeys.Failed.GetValueOrDefault(Store.OpenKeyId), 11, false,
            () => ToggleRecording(Store.OpenKeyId));
        btn.ToolTip = L("Nhấn phím này ở bất kỳ đâu để mở cửa sổ Gõ Tắt", "Press this anywhere to open Gõ Tắt");
        DockPanel.SetDock(btn, Dock.Right);
        line.Children.Add(btn);
        Footer.Children.Add(line);
        if (StatusLine(rec, hotKeys.Failed.GetValueOrDefault(Store.OpenKeyId)) is TextBlock st)
        {
            st.Margin = new Thickness(0, 6, 0, 0);
            Footer.Children.Add(st);
        }
    }

    void RenderDetail()
    {
        imagesLabel = noteText = null;
        imagesPanel = flowPanel = null;

        if (Store.Snippets.Count == 0)
        {
            var add = new Button { Style = (Style)FindResource("Primary"), Content = L("+ Thêm phím tắt", "+ Add shortcut"), Margin = new Thickness(0, 6, 0, 0) };
            add.Click += (_, _) => AddSnippet();
            DetailHost.Content = EmptyState("", L("Chưa có phím tắt nào", "No shortcuts yet"),
                L("Thêm phím tắt đầu tiên, ví dụ Ctrl+1 → số điện thoại của bạn.", "Add your first shortcut, e.g. Ctrl+1 → your phone number."), add);
            return;
        }
        if (Selected() is not Snippet s)
        {
            DetailHost.Content = EmptyState("", L("Chưa chọn phím tắt", "No shortcut selected"),
                L("Chọn một mục bên trái hoặc tạo mới.", "Pick one on the left or create a new one."), null);
            return;
        }

        var root = new StackPanel { Margin = new Thickness(28, 24, 28, 24), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };

        // Phím tắt + nút xoá
        bool rec = recordingId == s.Id;
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 26) };
        var del = new Button
        {
            Style = (Style)FindResource("Plain"), Width = 36, Height = 36, VerticalAlignment = VerticalAlignment.Top,
            Background = B("Field"), BorderBrush = B("Line"), BorderThickness = new Thickness(1), Foreground = B("Muted"),
            Content = Glyph("", 14, null), ToolTip = L("Xoá phím tắt này", "Delete this shortcut"),
        };
        del.MouseEnter += (_, _) => { del.Foreground = B("Danger"); del.BorderBrush = B("Danger"); };
        del.MouseLeave += (_, _) => { del.Foreground = B("Muted"); del.BorderBrush = B("Line"); };
        del.Click += (_, _) => DeleteSnippet(s);
        DockPanel.SetDock(del, Dock.Right);
        head.Children.Add(del);
        var keyCol = new StackPanel();
        keyCol.Children.Add(SectionLabel(L("Phím tắt", "Shortcut")));
        var big = ShortcutButton(s.KeyCode == null ? "" : s.KeyLabel, rec, hotKeys.Failed.GetValueOrDefault(s.Id), 20, true, () => ToggleRecording(s.Id));
        big.HorizontalAlignment = HorizontalAlignment.Left;
        big.Margin = new Thickness(-8, 0, 0, 0);
        keyCol.Children.Add(big);
        if (StatusLine(rec, hotKeys.Failed.GetValueOrDefault(s.Id)) is TextBlock st) { st.Margin = new Thickness(0, 6, 0, 0); keyCol.Children.Add(st); }
        head.Children.Add(keyCol);
        root.Children.Add(head);

        // Nội dung chữ
        root.Children.Add(SectionLabel(L("Nội dung chữ", "Text")));
        var editor = new TextBox
        {
            Style = (Style)FindResource("FieldBox"), Text = s.Text, AcceptsReturn = true, AcceptsTab = true,
            TextWrapping = TextWrapping.Wrap, MinHeight = 110, MaxHeight = 240, FontSize = 14,
            Padding = new Thickness(10, 8, 10, 8), VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var placeholder = new TextBlock
        {
            Text = s.ImageFiles.Count == 0 ? L("Nhập nội dung sẽ được dán…", "Type what should be pasted…")
                                           : L("Thêm chữ (tuỳ chọn), sẽ dán trước ảnh…", "Add text (optional), pasted before the images…"),
            Foreground = B("Faint"), FontSize = 14, Margin = new Thickness(13, 9, 0, 0), IsHitTestVisible = false,
            Visibility = s.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed,
        };
        var editorBox = new Grid();
        editorBox.Children.Add(editor);
        editorBox.Children.Add(placeholder);
        root.Children.Add(editorBox);
        var counter = new TextBlock { Foreground = B("Faint"), FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 26) };
        counter.Text = L($"{s.Text.Length} ký tự", $"{s.Text.Length} characters");
        root.Children.Add(counter);
        editor.TextChanged += (_, _) =>
        {
            s.Text = editor.Text;
            Store.Save();
            placeholder.Visibility = s.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            counter.Text = L($"{s.Text.Length} ký tự", $"{s.Text.Length} characters");
            RenderSidebar();
            RenderFlow(s);
        };

        // Ảnh
        imagesLabel = SectionLabel("");
        root.Children.Add(imagesLabel);
        imagesPanel = new WrapPanel();
        root.Children.Add(imagesPanel);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 26) };
        var clip = new Button { Style = (Style)FindResource("Chip"), Content = IconText("", L("Dán ảnh từ clipboard", "Paste image from clipboard")) };
        clip.Click += (_, _) =>
        {
            var imgs = ImageInput.FromClipboard();
            if (imgs.Count == 0) Flash(L("Clipboard không có ảnh", "No image in clipboard"));
            else { Store.AddImages(s, imgs); RefreshImages(s); }
        };
        tools.Children.Add(clip);
        noteText = new TextBlock { Foreground = B("Warn"), FontSize = 12, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Text = note ?? "" };
        tools.Children.Add(noteText);
        root.Children.Add(tools);

        // Khi nhấn phím
        root.Children.Add(SectionLabel(L("Khi nhấn phím", "When pressed")));
        flowPanel = new WrapPanel();
        root.Children.Add(new Border
        {
            Background = B("Side"), BorderBrush = B("Line"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 12, 12, 6), Child = flowPanel,
        });

        DetailHost.Content = root;
        RefreshImages(s);
    }

    /// Vẽ lại lưới ảnh, nhãn số ảnh, dòng thứ tự dán và cột trái.
    void RefreshImages(Snippet s)
    {
        if (imagesPanel == null || imagesLabel == null) return;
        imagesLabel.Text = (s.ImageFiles.Count == 0 ? L("Ảnh", "Images") : L($"Ảnh · {s.ImageFiles.Count}", $"Images · {s.ImageFiles.Count}")).ToUpper();
        imagesPanel.Children.Clear();
        for (int i = 0; i < s.ImageFiles.Count; i++) imagesPanel.Children.Add(Thumb(s, s.ImageFiles[i], i));
        imagesPanel.Children.Add(AddTile(s));
        RenderFlow(s);
        RenderSidebar();
    }

    void RenderFlow(Snippet s)
    {
        if (flowPanel == null) return;
        flowPanel.Children.Clear();
        var steps = new List<string>();
        if (s.Text.Length > 0) steps.Add(L("Chữ", "Text"));
        for (int i = 0; i < s.ImageFiles.Count; i++) steps.Add(L($"Ảnh {i + 1}", $"Image {i + 1}"));
        if (steps.Count == 0)
        {
            flowPanel.Children.Add(new TextBlock { Text = L("Chưa có gì để dán", "Nothing to paste yet"), Foreground = B("Faint"), Margin = new Thickness(0, 0, 0, 6) });
            return;
        }
        for (int i = 0; i < steps.Count; i++)
        {
            if (i > 0)
            {
                var arrow = Glyph("", 10, B("Faint"));
                arrow.Margin = new Thickness(0, 0, 8, 6);
                arrow.VerticalAlignment = VerticalAlignment.Center;
                flowPanel.Children.Add(arrow);
            }
            flowPanel.Children.Add(new Border
            {
                Background = B("Field"), BorderBrush = B("Line"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6),
                Padding = new Thickness(9, 3, 9, 3), Margin = new Thickness(0, 0, 8, 6),
                Child = new TextBlock { Text = steps[i], FontSize = 12.5, FontWeight = FontWeights.Medium, Foreground = B("Fg") },
            });
        }
    }

    UIElement Thumb(Snippet s, string name, int pos)
    {
        var img = Store.Thumbnail(name);
        var pic = new Border
        {
            CornerRadius = new CornerRadius(10), BorderBrush = B("Line"), BorderThickness = new Thickness(1),
            Background = img != null ? new ImageBrush(img) { Stretch = Stretch.UniformToFill } : B("Field"),
        };
        var badge = new Border
        {
            Background = Shade, CornerRadius = new CornerRadius(9), Padding = new Thickness(7, 1, 7, 1), Margin = new Thickness(6),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock { Text = (pos + 1).ToString(), Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = 11, FontFamily = (FontFamily)FindResource("Mono") },
        };
        var remove = new Button
        {
            Style = (Style)FindResource("Plain"), Tag = "11", Width = 22, Height = 22, Margin = new Thickness(6),
            Background = Shade, Foreground = Brushes.White, Content = Glyph("", 9, null),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Visibility = Visibility.Collapsed, ToolTip = L("Xoá ảnh này", "Remove this image"),
        };
        remove.Click += (_, _) => { Store.RemoveImage(s, name); RefreshImages(s); };

        var cell = new Grid { Width = 112, Height = 112, Margin = new Thickness(0, 0, 12, 12), AllowDrop = true, Cursor = Cursors.Hand,
                              ToolTip = L("Kéo để đổi thứ tự", "Drag to reorder") };
        cell.Children.Add(pic);
        cell.Children.Add(badge);
        cell.Children.Add(remove);
        cell.MouseEnter += (_, _) => remove.Visibility = Visibility.Visible;
        cell.MouseLeave += (_, _) => remove.Visibility = Visibility.Collapsed;

        // Kéo-thả để đổi chỗ
        Point? down = null;
        cell.PreviewMouseLeftButtonDown += (_, e) => down = e.GetPosition(cell);
        cell.PreviewMouseLeftButtonUp += (_, _) => down = null;
        cell.MouseMove += (_, e) =>
        {
            if (down is not Point p || e.LeftButton != MouseButtonState.Pressed) return;
            var d = e.GetPosition(cell) - p;
            if (Math.Abs(d.X) < 5 && Math.Abs(d.Y) < 5) return;
            down = null;
            DragDrop.DoDragDrop(cell, new DataObject("GoTatImage", name), DragDropEffects.Move);
        };
        cell.DragOver += (_, e) =>
        {
            if (!e.Data.GetDataPresent("GoTatImage")) return;
            e.Effects = DragDropEffects.Move;
            pic.BorderBrush = B("Accent");
            pic.BorderThickness = new Thickness(2);
            e.Handled = true;
        };
        cell.DragLeave += (_, _) => { pic.BorderBrush = B("Line"); pic.BorderThickness = new Thickness(1); };
        cell.Drop += (_, e) =>
        {
            if (e.Data.GetData("GoTatImage") is not string dragged) return;
            e.Handled = true;
            Store.MoveImage(s, dragged, s.ImageFiles.IndexOf(name));
            RefreshImages(s);
        };

        var menu = new ContextMenu();
        menu.Items.Add(MenuItem(L("Dời lên trước", "Move earlier"), pos > 0, () => { Store.MoveImage(s, name, pos - 1); RefreshImages(s); }));
        menu.Items.Add(MenuItem(L("Dời ra sau", "Move later"), pos < s.ImageFiles.Count - 1, () => { Store.MoveImage(s, name, pos + 1); RefreshImages(s); }));
        menu.Items.Add(new Separator());
        menu.Items.Add(MenuItem(L("Xoá ảnh", "Remove image"), true, () => { Store.RemoveImage(s, name); RefreshImages(s); }));
        cell.ContextMenu = menu;
        return cell;
    }

    UIElement AddTile(Snippet s)
    {
        var dash = new Rectangle { Stroke = B("CapEdge"), StrokeThickness = 1.5, StrokeDashArray = new DoubleCollection { 4, 3 }, RadiusX = 10, RadiusY = 10 };
        var hint = new TextBlock { Text = L("hoặc kéo-thả, Ctrl+V", "or drag & drop, Ctrl+V"), FontSize = 10.5, Foreground = B("Faint"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6) };
        stack.Children.Add(new TextBlock { Text = "", FontFamily = (FontFamily)FindResource("Icons"), FontSize = 18, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 6) });
        stack.Children.Add(new TextBlock { Text = L("Thêm ảnh", "Add image"), FontSize = 12, FontWeight = FontWeights.Medium, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(hint);
        var content = new Grid();
        content.Children.Add(dash);
        content.Children.Add(stack);

        var tile = new Button
        {
            Style = (Style)FindResource("Plain"), Tag = "10", Width = 112, Height = 112, Margin = new Thickness(0, 0, 12, 12),
            Foreground = B("Muted"), Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch, ToolTip = L("Chọn ảnh từ máy", "Choose images from disk"),
        };
        tile.MouseEnter += (_, _) => { tile.Background = B("AccentSoft"); tile.Foreground = B("Accent"); dash.Stroke = B("Accent"); };
        tile.MouseLeave += (_, _) => { tile.Background = Brushes.Transparent; tile.Foreground = B("Muted"); dash.Stroke = B("CapEdge"); };
        tile.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Multiselect = true,
                Filter = L("Ảnh", "Images") + "|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.webp;*.tif;*.tiff",
            };
            if (dlg.ShowDialog(this) != true) return;
            Store.AddImages(s, ImageInput.FromFiles(dlg.FileNames));
            RefreshImages(s);
        };
        return tile;
    }

    // MARK: - Thao tác

    void AddSnippet()
    {
        SearchBox.Text = "";
        var s = new Snippet();
        Store.Snippets.Add(s);
        Store.Save();
        selectedId = s.Id;
        recordingId = s.Id; // chờ nhấn phím tắt ngay
        recordHint = null;
        ReloadHotKeys();
        RenderSidebar();
        RenderFooter();
        RenderDetail();
    }

    void DeleteSnippet(Snippet s)
    {
        if (s.Text.Length > 0 || s.ImageFiles.Count > 0)
        {
            var name = s.KeyLabel.Length > 0 ? s.KeyLabel : L("này", "");
            var msg = s.ImageFiles.Count == 0
                ? L("Nội dung của phím tắt này sẽ bị xoá vĩnh viễn.", "This shortcut's content will be deleted permanently.")
                : L($"Nội dung và {s.ImageFiles.Count} ảnh của phím tắt này sẽ bị xoá vĩnh viễn.", $"This shortcut's text and {s.ImageFiles.Count} images will be deleted permanently.");
            if (MessageBox.Show(this, msg, L($"Xoá phím tắt {name}?", $"Delete shortcut {name}?"),
                                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        }
        int i = Store.Snippets.IndexOf(s);
        if (recordingId == s.Id) recordingId = null;
        Store.Remove(s);
        selectedId = Store.Snippets.Count == 0 ? null : Store.Snippets[Math.Min(i, Store.Snippets.Count - 1)].Id;
        ReloadHotKeys();
        RenderSidebar();
        RenderFooter();
        RenderDetail();
    }

    void ToggleRecording(Guid id)
    {
        recordingId = recordingId == id ? null : id;
        recordHint = null;
        ReloadHotKeys();
        RenderSidebar();
        RenderFooter();
        RenderDetail();
    }

    void Flash(string text)
    {
        note = text;
        if (noteText != null) noteText.Text = text;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (note != text) return;
            note = null;
            if (noteText != null) noteText.Text = "";
        };
        timer.Start();
    }

    void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RenderSidebar();
    }

    void AddBtn_Click(object sender, RoutedEventArgs e) => AddSnippet();

    /// Ghi phím tắt khi đang chờ, Ctrl+N thêm mới, Ctrl+V dán ảnh vào phím tắt đang mở.
    void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;

        if (recordingId is Guid target)
        {
            e.Handled = true;
            if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
                    or Key.LWin or Key.RWin or Key.ImeProcessed or Key.DeadCharProcessed) return;
            if (key == Key.Escape) { ToggleRecording(target); return; }

            var snip = target == Store.OpenKeyId ? Store.Settings.OpenKey : Find(target);
            if (snip == null) { ToggleRecording(target); return; }

            if (key == Key.Back)
            {
                snip.KeyCode = null; snip.Modifiers = 0; snip.KeyLabel = "";
            }
            else
            {
                uint mods = 0;
                var m = Keyboard.Modifiers;
                if (m.HasFlag(ModifierKeys.Control)) mods |= 2;
                if (m.HasFlag(ModifierKeys.Alt)) mods |= 1;
                if (m.HasFlag(ModifierKeys.Shift)) mods |= 4;
                if (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin)) mods |= 8;
                // Phím đơn (chữ, số…) sẽ chặn việc gõ phím đó ở mọi app, nên bắt buộc kèm Ctrl, Alt hoặc Win
                if ((mods & 0b1011) == 0 && !(key >= Key.F1 && key <= Key.F24))
                {
                    System.Media.SystemSounds.Beep.Play();
                    recordHint = L("Cần kèm Ctrl, Alt hoặc Win", "Add Ctrl, Alt or Win");
                    RenderFooter();
                    RenderDetail();
                    return;
                }
                snip.KeyCode = (uint)KeyInterop.VirtualKeyFromKey(key);
                snip.Modifiers = mods;
                snip.KeyLabel = KeyLabel(mods, key);
            }
            if (target == Store.OpenKeyId) Store.SaveSettings(); else Store.Save();
            ToggleRecording(target);
            return;
        }

        if (key == Key.N && Keyboard.Modifiers == ModifierKeys.Control)
        {
            e.Handled = true;
            AddSnippet();
            return;
        }

        if (key == Key.V && Keyboard.Modifiers == ModifierKeys.Control && !SearchBox.IsKeyboardFocusWithin && Selected() is Snippet s)
        {
            var imgs = ImageInput.FromClipboard();
            if (imgs.Count == 0) return; // clipboard là chữ: để ô nội dung dán như bình thường
            e.Handled = true;
            Store.AddImages(s, imgs);
            RefreshImages(s);
        }
    }

    static string KeyLabel(uint mods, Key key)
    {
        var parts = new List<string>();
        if ((mods & 2) != 0) parts.Add("Ctrl");
        if ((mods & 1) != 0) parts.Add("Alt");
        if ((mods & 4) != 0) parts.Add("Shift");
        if ((mods & 8) != 0) parts.Add("Win");
        parts.Add(KeyName(key));
        return string.Join("+", parts);
    }

    static string KeyName(Key k) => k switch
    {
        >= Key.D0 and <= Key.D9 => ((int)(k - Key.D0)).ToString(),
        >= Key.NumPad0 and <= Key.NumPad9 => "Num" + (int)(k - Key.NumPad0),
        >= Key.A and <= Key.Z => k.ToString(),
        >= Key.F1 and <= Key.F24 => k.ToString(),
        Key.Space => "Space", Key.Enter => "Enter", Key.Tab => "Tab", Key.Delete => "Del", Key.Insert => "Ins",
        Key.Home => "Home", Key.End => "End", Key.PageUp => "PgUp", Key.PageDown => "PgDn",
        Key.Left => "←", Key.Right => "→", Key.Up => "↑", Key.Down => "↓",
        Key.Oem3 => "`", Key.OemMinus => "-", Key.OemPlus => "=", Key.OemOpenBrackets => "[", Key.Oem6 => "]",
        Key.Oem5 => "\\", Key.Oem1 => ";", Key.Oem7 => "'", Key.OemComma => ",", Key.OemPeriod => ".", Key.Oem2 => "/",
        _ => k.ToString(),
    };

    // MARK: - Kéo-thả ảnh từ ngoài vào

    void Detail_DragOver(object sender, DragEventArgs e)
    {
        bool files = e.Data.GetDataPresent(DataFormats.FileDrop) && Selected() != null;
        e.Effects = files ? DragDropEffects.Copy : DragDropEffects.None;
        DropOverlay.Visibility = files ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    void Detail_DragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    void Detail_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (Selected() is not Snippet s || e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        var imgs = ImageInput.FromFiles(paths);
        if (imgs.Count == 0) { Flash(L("Không đọc được ảnh", "Couldn't read the image")); return; }
        Store.AddImages(s, imgs);
        RefreshImages(s);
    }

    // MARK: - Thành phần dựng sẵn

    /// Vẽ phím tắt như phím bàn phím thật: "Ctrl+Alt+1" → [Ctrl] [Alt] [1].
    FrameworkElement Caps(string label, double size)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var part in label.Split('+'))
        {
            panel.Children.Add(new Border
            {
                Background = B("Cap"), BorderBrush = B("CapEdge"),
                BorderThickness = new Thickness(1, 1, 1, Math.Max(2, size * 0.15)),
                CornerRadius = new CornerRadius(size * 0.42), MinWidth = size * 1.9, Height = size * 2.05,
                Padding = new Thickness(size * 0.45, 0, size * 0.45, 0), Margin = new Thickness(0, 0, size * 0.25, 0),
                Child = new TextBlock
                {
                    Text = part, FontFamily = (FontFamily)FindResource("Mono"), FontWeight = FontWeights.Bold, FontSize = size,
                    Foreground = B("Fg"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                },
            });
        }
        return panel;
    }

    /// Ô phím viền đứt, dùng khi chưa có phím tắt hoặc đang chờ nhấn phím.
    static FrameworkElement DashedCap(string text, double size, Brush brush)
    {
        var g = new Grid { Height = size * 2.05, HorizontalAlignment = HorizontalAlignment.Left };
        g.Children.Add(new Rectangle { Stroke = brush, StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 3 }, RadiusX = size * 0.42, RadiusY = size * 0.42 });
        g.Children.Add(new TextBlock { Text = text, FontSize = size * 0.9, FontWeight = FontWeights.Medium, Foreground = brush, Margin = new Thickness(size * 0.6, 0, size * 0.6, 0), VerticalAlignment = VerticalAlignment.Center });
        return g;
    }

    Button ShortcutButton(string label, bool recording, string? problem, double size, bool showAction, Action onClick)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        if (recording)
        {
            var dot = Glyph("", size * 0.9, B("Accent"));
            dot.Margin = new Thickness(0, 0, size * 0.5, 0);
            panel.Children.Add(dot);
            panel.Children.Add(DashedCap(L("Nhấn tổ hợp phím…", "Press keys…"), size, B("Accent")));
        }
        else if (label.Length == 0) panel.Children.Add(DashedCap(L("Chưa đặt", "Not set"), size, B("Faint")));
        else panel.Children.Add(Caps(label, size));

        if (problem != null && !recording)
        {
            var warn = Glyph("", Math.Max(12, size * 0.7), B("Danger"));
            warn.Margin = new Thickness(size * 0.3, 0, 0, 0);
            panel.Children.Add(warn);
        }
        if (showAction)
        {
            panel.Children.Add(new TextBlock
            {
                Text = recording ? L("Esc để huỷ", "Esc to cancel") : label.Length == 0 ? L("Bấm để đặt phím", "Click to set") : L("Đổi phím", "Change"),
                Foreground = B("Accent"), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(size * 0.6, 0, 0, 0),
            });
        }

        var btn = new Button
        {
            Style = (Style)FindResource("Plain"), Tag = "10", Content = panel, Padding = new Thickness(size * 0.4),
            Background = recording ? B("AccentSoft") : Brushes.Transparent,
            BorderBrush = recording ? B("Accent") : Brushes.Transparent, BorderThickness = new Thickness(recording ? 1.5 : 1),
            ToolTip = recording ? L("Nhấn tổ hợp phím · Esc để huỷ · Backspace để xoá", "Press a key combo · Esc to cancel · Backspace to clear")
                                : L("Bấm để đặt hoặc đổi phím tắt", "Click to set or change the shortcut"),
        };
        if (!recording)
        {
            btn.MouseEnter += (_, _) => btn.BorderBrush = B("Line");
            btn.MouseLeave += (_, _) => btn.BorderBrush = Brushes.Transparent;
        }
        btn.Click += (_, _) => onClick();
        return btn;
    }

    /// Dòng chú thích dưới ô phím tắt: hướng dẫn khi đang ghi, hoặc lý do lỗi.
    TextBlock? StatusLine(bool recording, string? problem)
    {
        if (recording)
            return new TextBlock
            {
                Text = recordHint ?? L("Esc huỷ · Backspace xoá phím", "Esc cancel · Backspace clear"),
                Foreground = recordHint != null ? B("Danger") : B("Muted"), FontSize = 12, TextWrapping = TextWrapping.Wrap,
            };
        if (problem != null)
            return new TextBlock { Text = problem, Foreground = B("Danger"), FontSize = 12, TextWrapping = TextWrapping.Wrap };
        return null;
    }

    static TextBlock SectionLabel(string text) => new()
    {
        Text = text.ToUpper(), FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = B("Faint"), Margin = new Thickness(0, 0, 0, 8),
    };

    TextBlock Glyph(string code, double size, Brush? brush)
    {
        var t = new TextBlock { Text = code, FontFamily = (FontFamily)FindResource("Icons"), FontSize = size, VerticalAlignment = VerticalAlignment.Center };
        if (brush != null) t.Foreground = brush;
        return t;
    }

    StackPanel IconText(string glyph, string text)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        var g = Glyph(glyph, 12, null);
        g.Margin = new Thickness(0, 0, 6, 0);
        p.Children.Add(g);
        p.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return p;
    }

    static MenuItem MenuItem(string header, bool enabled, Action action)
    {
        var item = new MenuItem { Header = header, IsEnabled = enabled };
        item.Click += (_, _) => action();
        return item;
    }

    UIElement EmptyState(string glyph, string title, string message, UIElement? action)
    {
        var p = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 120, 16, 16) };
        var icon = Glyph(glyph, 34, B("Faint"));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        p.Children.Add(icon);
        p.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 4) });
        p.Children.Add(new TextBlock { Text = message, Foreground = B("Muted"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 360 });
        if (action != null) { if (action is FrameworkElement fe) fe.HorizontalAlignment = HorizontalAlignment.Center; p.Children.Add(action); }
        return p;
    }
}
