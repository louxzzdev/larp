using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace LarpOptimizer;

internal sealed record Preferences(string Theme = "Dark", bool ReducedMotion = false, bool CompactSidebar = false,
    int RefreshSeconds = 12)
{
    internal static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LARP Optimizer");
    private static string FilePath => Path.Combine(Folder, "interface.json");

    internal static Preferences Read()
    {
        try
        {
            return (JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath)) ?? new()).Validate();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return new();
        }
    }

    internal Preferences Validate() => this with
    {
        Theme = Theme is "Light" or "Dark" ? Theme : "Dark",
        RefreshSeconds = RefreshSeconds is 0 or 12 or 30 or 60 ? RefreshSeconds : 12
    };

    internal async Task SaveAsync()
    {
        Directory.CreateDirectory(Folder);
        string temp = Path.Combine(Folder, Guid.NewGuid() + ".tmp");
        try
        {
            await File.WriteAllTextAsync(temp, JsonSerializer.Serialize(this));
            File.Move(temp, FilePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }
}

public partial class MainWindow
{
    private sealed record Section(string Page, string Glyph, string Keywords);
    private static readonly Section[] Sections =
    [
        new("Dashboard", "\uE80F", "overview health performance recent recommendations"),
        new("Optimize", "\uE945", "analyze apply game profile preset cpu power epp"),
        new("Restore", "\uE777", "history undo rollback backup sessions reports"),
        new("CPU", "\uE950", "processor power plan processes threads"),
        new("GPU", "\uE7F4", "graphics display driver refresh"),
        new("Memory", "\uE964", "ram working set startup"),
        new("Network", "\uE968", "ping DNS jitter loss adapter routes"),
        new("Diagnostics", "\uE9D9", "benchmark baseline follow-up compare export"),
        new("Tools", "\uE90F", "task manager resource monitor startup storage uninstall installed apps power graphics"),
        new("Settings", "\uE713", "theme appearance light dark motion shortcuts monitoring")
    ];
    private readonly List<Section> recent = [];
    private readonly SemaphoreSlim preferenceWrite = new(1, 1);
    private readonly List<TextBlock> groupLabels = [];
    private readonly Dictionary<string, TextBlock> linkLabels = [];
    private Preferences preferences = Preferences.Read();
    private bool compact;
    private bool Motion => !preferences.ReducedMotion && SystemParameters.ClientAreaAnimation;
    private bool Dark => preferences.Theme == "Dark";

    private void InitializeShell()
    {
        ApplyPreferences();
        for (int index = 0; index < Sections.Length; index++)
        {
            var section = Sections[index];
            string? group = index switch { 0 => "WORKSPACE", 3 => "SYSTEM", 9 => "PREFERENCES", _ => null };
            if (group is not null)
            {
                var label = Text(group, "Muted", 10);
                label.Margin = new Thickness(9, index == 0 ? 2 : 16, 0, 5);
                groupLabels.Add(label);
                Navigation.Children.Add(label);
            }
            var link = ButtonFor(section.Page, async () => await Navigate(section.Page), keepEnabled: true);
            link.HorizontalContentAlignment = HorizontalAlignment.Left;
            link.Padding = new Thickness(8, 8, 6, 8);
            link.Margin = new Thickness(1, 0, 1, 3);
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            var icon = new TextBlock { Text = section.Glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), Width = 22,
                Foreground = System.Windows.Media.Brushes.Transparent };
            icon.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = link });
            var name = new TextBlock { Text = section.Page };
            name.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = link });
            content.Children.Add(icon);
            content.Children.Add(name);
            link.Content = content;
            AutomationProperties.SetName(link, section.Page);
            link.ToolTip = section.Page;
            links.Add(section.Page, link);
            linkLabels.Add(section.Page, name);
            Navigation.Children.Add(link);
        }
        UpdateSidebar();
        SizeChanged += (_, _) => UpdateSidebar();
        SidebarToggle.Click += async (_, _) => await ToggleSidebar();
        SearchButton.Click += async (_, _) => await OpenPalette();
        PreviewKeyDown += async (_, args) =>
        {
            if (Keyboard.Modifiers != ModifierKeys.Control || args.IsRepeat) return;
            if (PaletteLayer.Visibility == Visibility.Visible) return;
            args.Handled = true;
            switch (args.Key)
            {
                case Key.K: await OpenPalette(); break;
                case Key.B: await ToggleSidebar(); break;
                case Key.D1: await Navigate("Dashboard"); break;
                case Key.D2: await Navigate("Optimize"); break;
                case Key.D3: await Navigate("Restore"); break;
                default: args.Handled = false; break;
            }
        };
    }

    private void UpdateSidebar()
    {
        bool next = preferences.CompactSidebar || ActualWidth is > 0 and < 715;
        if (Sidebar.Width.Value == (next ? 58 : 184) && compact == next && groupLabels.All(x => x.Visibility == Visibility.Visible) && !next)
            return;
        compact = next;
        Sidebar.Width = new GridLength(compact ? 58 : 184);
        foreach (var label in linkLabels.Values) label.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        foreach (var label in groupLabels) label.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
    }

    private Task ToggleSidebar() => ChangePreferences(preferences with { CompactSidebar = !preferences.CompactSidebar });

    private void ApplyPreferences()
    {
        string[] keys = ["Canvas", "Rail", "Panel", "Stroke", "Text", "Muted", "Accent", "OnAccent", "Hover"];
        string[] colors = Dark
            ? ["#111111", "#151515", "#1B1B1B", "#333333", "#F7F7F7", "#B4B4B4", "#F4F4F4", "#111111", "#292929"]
            : ["#F6F6F6", "#EEEEEE", "#FFFFFF", "#D1D1D1", "#191919", "#515151", "#202020", "#FFFFFF", "#E5E5E5"];
        for (int index = 0; index < keys.Length; index++)
            Application.Current.Resources[keys[index]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[index]));
        live.Stop();
        if (preferences.RefreshSeconds > 0)
        {
            live.Interval = TimeSpan.FromSeconds(preferences.RefreshSeconds);
            live.Start();
        }
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != IntPtr.Zero) SetCaptionTheme(handle, Dark);
        UpdateSidebar();
        RenderStatus();
    }

    private async Task ChangePreferences(Preferences value)
    {
        preferences = value.Validate();
        ApplyPreferences();
        await preferenceWrite.WaitAsync();
        try { await preferences.SaveAsync(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            RenderStatus("Could not save preferences. " + error.Message);
        }
        finally { preferenceWrite.Release(); }
    }

    private void AnimatePage()
    {
        if (Motion)
            PageBody.BeginAnimation(OpacityProperty, new DoubleAnimation(.84, 1, TimeSpan.FromMilliseconds(115)));
    }

    private void TrackPage(string destination)
    {
        var section = Sections.First(item => item.Page == destination);
        recent.Remove(section);
        recent.Insert(0, section);
        if (recent.Count > 4) recent.RemoveAt(4);
    }

    private Task OpenPalette()
    {
        if (PaletteLayer.Visibility == Visibility.Visible) return Task.CompletedTask;
        var originalFocus = Keyboard.FocusedElement;
        var frame = new Border { Width = 475, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center, CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1), Padding = new Thickness(16) };
        frame.SetResourceReference(Border.BackgroundProperty, "Canvas");
        frame.SetResourceReference(Border.BorderBrushProperty, "Stroke");
        var panel = new StackPanel();
        frame.Child = panel;
        KeyboardNavigation.SetTabNavigation(frame, KeyboardNavigationMode.Cycle);
        AutomationProperties.SetName(frame, "Command palette");
        var input = Input(panel, "Search pages and actions", width: 452);
        var list = new ListBox { MaxHeight = 280, Padding = new Thickness(4) };
        list.SetResourceReference(BackgroundProperty, "Panel");
        list.SetResourceReference(ForegroundProperty, "Text");
        list.SetResourceReference(BorderBrushProperty, "Stroke");
        AutomationProperties.SetName(list, "Matching commands");
        panel.Children.Add(list);
        var hint = Text("↑ ↓  Select     Enter  Open     Esc  Close", "Muted", 12);
        hint.Margin = new Thickness(0, 10, 0, 0);
        var actions = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        panel.Children.Add(actions);
        void Filter()
        {
            string[] terms = input.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            list.ItemsSource = (terms.Length == 0 ? recent.Concat(Sections).Distinct() : Sections)
                .Where(section => terms.All(term => (section.Page + " " + section.Keywords).Contains(term, StringComparison.OrdinalIgnoreCase)))
                .Select(section => section.Page)
                .ToArray();
            list.SelectedIndex = list.Items.Count > 0 ? 0 : -1;
            hint.Text = list.Items.Count == 0 ? "No matching commands." : "↑ ↓  Select     Enter  Open     Esc  Close";
        }
        void Close()
        {
            PaletteLayer.Children.Clear();
            PaletteLayer.Visibility = Visibility.Collapsed;
            if (originalFocus is not null) Keyboard.Focus(originalFocus);
        }
        async Task Accept()
        {
            if (list.SelectedItem is not string option) return;
            Close();
            await Navigate(option);
        }
        var open = ButtonFor("Open selected", Accept, true);
        DockPanel.SetDock(open, Dock.Right);
        actions.Children.Add(open);
        var dismiss = ButtonFor("Close", () => { Close(); return Task.CompletedTask; });
        DockPanel.SetDock(dismiss, Dock.Right);
        actions.Children.Add(dismiss);
        actions.Children.Add(hint);
        list.SelectionChanged += (_, _) => open.IsEnabled = list.SelectedIndex >= 0;
        input.TextChanged += (_, _) => Filter();
        list.MouseDoubleClick += async (_, _) => await Accept();
        frame.PreviewKeyDown += async (_, args) =>
        {
            switch (args.Key)
            {
                case Key.Escape:
                    args.Handled = true;
                    Close();
                    return;
                case Key.Enter:
                    args.Handled = true;
                    await Accept();
                    return;
                case Key.Up:
                case Key.Down:
                    if (list.Items.Count > 0)
                    {
                        list.SelectedIndex = Math.Clamp(list.SelectedIndex + (args.Key == Key.Up ? -1 : 1), 0, list.Items.Count - 1);
                        list.ScrollIntoView(list.SelectedItem);
                    }
                    break;
                default: return;
            }
            args.Handled = true;
        };
        Filter();
        frame.Loaded += (_, _) => input.Focus();
        PaletteLayer.Children.Add(frame);
        PaletteLayer.Visibility = Visibility.Visible;
        return Task.CompletedTask;
    }
}
