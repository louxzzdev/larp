using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace LarpOptimizer;

public partial class MainWindow : Window
{
    private static readonly string[] Profiles = ["General Gaming", "Valorant", "Counter-Strike 2", "Fortnite", "Minecraft", "Roblox", "Call of Duty"];
    private static readonly string[] Presets = ["Performance", "Safe", "Balanced", "Competitive", "Custom"];
    private static readonly string[] Providers = ["Default", "Cloudflare", "Google", "Quad9", "Custom"];
    private static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };
    private readonly DispatcherTimer live = new() { Interval = TimeSpan.FromSeconds(12) };
    private readonly Dictionary<string, Button> links = [];
    private readonly bool admin;
    private readonly HashSet<CancellationTokenSource> scans = [];
    private int pageRevision;
    private CancellationTokenSource? liveWork;
    private bool modifying;
    private string page = "";
    private string activeProfile = Profiles[0];
    private string activePreset = Presets[0];
    private JsonArray adapters = [];
    private JsonArray plans = [];
    private JsonObject? baselineRequest;
    private JsonNode? baselineResult;
    private JsonNode? followUp;
    private JsonNode? latestNetwork;
    private JsonNode? latestResult;
    private StackPanel? liveMetrics;
    private readonly Queue<JsonObject> samples = new();
    private JsonNode? dashboardCache;
    private DateTime dashboardCachedAt;
    private string chartMetric = "CPU";
    private Action<JsonNode>? paintMetrics;

    public MainWindow()
    {
        InitializeComponent();
        UseDarkCaption(this);
        using var identity = WindowsIdentity.GetCurrent();
        admin = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        Device.Text = Environment.MachineName + "  /  Windows build " + Environment.OSVersion.Version.Build;
        Access.Text = admin ? "Administrator" : "Standard access";
        InitializeShell();
        CancelButton.Click += (_, _) => CancelScans();
        Loaded += async (_, _) => await Navigate("Dashboard");
        live.Tick += async (_, _) => await RefreshLive();
        Closing += (_, args) =>
        {
            if (modifying)
            {
                args.Cancel = true;
                Status.Text = "Wait for Windows to finish and verify the change.";
                return;
            }
            live.Stop();
            CancelScans();
            liveWork?.Cancel();
        };
    }

    private async Task Navigate(string destination)
    {
        pageRevision++;
        CancelScans();
        liveWork?.Cancel();
        page = destination;
        TrackPage(destination);
        Heading.Text = destination;
        Subtitle.Text = "";
        RenderStatus();
        Controls.Children.Clear();
        Results.Children.Clear();
        Results.Visibility = Visibility.Visible;
        PageScroll.ScrollToTop();
        liveMetrics = null;
        paintMetrics = null;
        foreach (var (name, link) in links)
        {
            if (name == page)
            {
                link.SetResourceReference(BackgroundProperty, "Hover");
                link.SetResourceReference(BorderBrushProperty, "Stroke");
            }
            else
            {
                link.Background = Brushes.Transparent;
                link.BorderBrush = Brushes.Transparent;
            }
            link.SetResourceReference(ForegroundProperty, name == page ? "Text" : "Muted");
        }
        AnimatePage();

        switch (page)
        {
            case "Dashboard": await Dashboard(); break;
            case "Optimize": await Optimize(); break;
            case "CPU": await Cpu(); break;
            case "GPU": await Gpu(); break;
            case "Memory": await Memory(); break;
            case "Network": await Network(); break;
            case "Diagnostics": Diagnostics(); break;
            case "Tools": Tools(); break;
            case "Restore": await Restore(); break;
            case "Settings": await Settings(); break;
            case "About": About(); break;
        }
    }

    private async Task RefreshLive()
    {
        if (!IsActive || WindowState == WindowState.Minimized || scans.Count != 0 ||
            liveWork is not null || page != "Dashboard" || liveMetrics is null) return;
        int revision = pageRevision;
        using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        liveWork = cancel;
        try
        {
            var result = await EngineClient.InvokeAsync(Request("metrics"), _ => { }, cancel.Token);
            if (result.FirstOrDefault() is JsonObject metrics && revision == pageRevision && liveMetrics is not null)
                UpdateMetrics(liveMetrics, metrics);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (revision == pageRevision) Status.Text = "Live refresh: " + error.Message; }
        finally { liveWork = null; }
    }

    private void CancelScans()
    {
        foreach (var scan in scans.ToArray()) scan.Cancel();
        scans.Clear();
        RenderStatus();
    }

    private void RenderStatus(string message = "Ready")
    {
        CancelButton.Visibility = scans.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        bool busy = modifying || scans.Count > 0;
        Activity.Visibility = busy && Motion ? Visibility.Visible : Visibility.Collapsed;
        Activity.IsIndeterminate = busy && Motion;
        Status.Text = message != "Ready" ? message :
            modifying ? "Applying settings in the background…" : scans.Count > 0 ? "Scanning…" : "Ready";
    }

    private async Task<T?> Execute<T>(Func<CancellationToken, Task<T>> action, bool mutation = false) where T : class
    {
        if (mutation && modifying)
        {
            RenderStatus("A settings change is already running.");
            return null;
        }
        int revision = pageRevision;
        using var cancel = new CancellationTokenSource(mutation ? Timeout.InfiniteTimeSpan : TimeSpan.FromSeconds(155));
        if (mutation) modifying = true;
        else scans.Add(cancel);
        RenderStatus();
        string message = "Ready";
        try
        {
            T data = await action(cancel.Token);
            if (revision == pageRevision && !cancel.IsCancellationRequested) return data;
            if (mutation) message = "Settings operation finished. Open Restore for the report.";
        }
        catch (OperationCanceledException)
        {
            message = "Scan cancelled or timed out.";
        }
        catch (Exception error)
        {
            message = error.Message;
        }
        finally
        {
            if (mutation) modifying = false;
            else scans.Remove(cancel);
            if (mutation || revision == pageRevision) RenderStatus(message);
        }
        return null;
    }

    private Task<JsonArray> Call(JsonObject request, CancellationToken token, bool mutation = false) =>
        EngineClient.InvokeAsync(request, text =>
        {
            if (mutation) Dispatcher.BeginInvoke(() => { if (modifying) RenderStatus(text); });
        }, token);

    private async Task<JsonArray?> Run(JsonObject request, bool mutation = false, bool remember = true)
    {
        var result = await Execute(token => Call(request, token, mutation), mutation);
        if (result is not null && remember) latestResult = result;
        return result;
    }

    private static JsonObject Request(string action) => new() { ["action"] = action };
    private static string Value(JsonNode? node) => node switch
    {
        null => "Unavailable",
        JsonValue => node.ToString(),
        _ => node.ToJsonString(Pretty)
    };
    private static string StringValue(JsonNode? node) => node?.ToString() ?? "";
    private static TextBlock Text(string content, string color = "Text", double size = 13)
    {
        var text = new TextBlock { Text = content, FontSize = size };
        text.SetResourceReference(TextBlock.ForegroundProperty, color);
        return text;
    }
    private static StackPanel Card(Panel parent, string title)
    {
        var stack = new StackPanel();
        var border = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 0, 10),
            Padding = new Thickness(16, 13, 16, 14), Child = stack
        };
        border.SetResourceReference(Border.BackgroundProperty, "Panel");
        border.SetResourceReference(Border.BorderBrushProperty, "Stroke");
        parent.Children.Add(border);
        var heading = Text(title, size: 15);
        heading.FontWeight = FontWeights.SemiBold;
        heading.Margin = new Thickness(0, 0, 0, 8);
        stack.Children.Add(heading);
        return stack;
    }
    private static Button ButtonFor(string label, Func<Task> action, bool primary = false, bool keepEnabled = false)
    {
        var button = new Button { Content = label };
        if (primary)
        {
            button.SetResourceReference(BackgroundProperty, "Accent");
            button.SetResourceReference(BorderBrushProperty, "Accent");
            button.SetResourceReference(ForegroundProperty, "OnAccent");
        }
        button.Click += async (_, _) =>
        {
            if (!keepEnabled) button.IsEnabled = false;
            try { await action(); }
            catch (Exception error)
            {
                if (button.Window() is MainWindow parent) parent.ShowDialog(label, error.Message, false);
            }
            finally { if (!keepEnabled) button.IsEnabled = true; }
        };
        return button;
    }
    private static WrapPanel Row(Panel parent)
    {
        var row = new WrapPanel { Margin = new Thickness(0, 2, 0, 3) };
        parent.Children.Add(row);
        return row;
    }
    private static TextBox Input(Panel parent, string label, string value = "", double width = 200)
    {
        var field = Field(parent, label, width);
        var input = new TextBox { Text = value };
        AutomationProperties.SetName(input, label);
        field.Children.Add(input);
        return input;
    }
    private static StackPanel Field(Panel parent, string label, double width)
    {
        var field = new StackPanel { Width = width, Margin = new Thickness(0, 0, 10, 10) };
        void Fit(double available) => field.MaxWidth = available > 10 ? available - 10 : width;
        Fit(parent.ActualWidth);
        parent.SizeChanged += (_, args) => Fit(args.NewSize.Width);
        var caption = Text(label, "Muted");
        caption.Margin = new Thickness(0, 0, 0, 5);
        field.Children.Add(caption);
        parent.Children.Add(field);
        return field;
    }
    private static ComboBox Select(Panel parent, string label, IEnumerable<string> items, string? selected = null, double width = 200)
    {
        var combo = new ComboBox { ItemsSource = items.ToArray() };
        combo.SelectedItem = selected;
        if (combo.SelectedIndex < 0 && combo.Items.Count > 0) combo.SelectedIndex = 0;
        AutomationProperties.SetName(combo, label);
        Field(parent, label, width).Children.Add(combo);
        return combo;
    }
    private static string Selected(ComboBox combo) => combo.SelectedItem as string ?? "";
    private static void Note(Panel parent, string message)
    {
        var note = Text(message, "Muted");
        note.Margin = new Thickness(0, 3, 0, 9);
        parent.Children.Add(note);
    }
    private static void Line(Panel parent, string name, string value)
    {
        var text = Text(name + "   " + value);
        text.Margin = new Thickness(0, 1, 0, 4);
        parent.Children.Add(text);
    }
    private void ShowResult(string name, JsonNode? node)
    {
        Results.Children.Clear();
        var card = Card(Results, name);
        if (node is JsonArray array && array.Count == 0) { Note(card, "No records returned."); return; }
        var details = new TextBox
        {
            Text = Format(node), IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 620,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0)
        };
        AutomationProperties.SetName(details, name);
        card.Children.Add(details);
    }

    private static string Humanize(string key) => Regex.Replace(key, "(?<=[a-z])(?=[A-Z])", " ");
    private static string Format(JsonNode? value, string indent = "")
    {
        if (value is JsonObject obj)
            return string.Join("\n", obj.Select(pair => pair.Value is JsonObject or JsonArray
                ? $"{indent}{Humanize(pair.Key)}\n{Format(pair.Value, indent + "  ")}"
                : $"{indent}{Humanize(pair.Key)}   {Value(pair.Value)}"));
        if (value is JsonArray array)
            return array.Count == 0 ? indent + "None reported" :
                string.Join(array.Any(item => item is JsonObject) ? "\n\n" : "\n", array.Select(item => Format(item, indent)));
        return indent + Value(value);
    }

    private bool ShowDialog(string title, string message, bool confirm)
    {
        var view = new Window
        {
            Owner = this, Title = title, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Width = 635, Height = 430, MinWidth = 420, MinHeight = 240,
            Background = Background, Foreground = Foreground, FontFamily = FontFamily, ShowInTaskbar = false
        };
        var content = new DockPanel { Margin = new Thickness(22) };
        UseDarkCaption(view);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(actions, Dock.Bottom);
        content.Children.Add(actions);
        var close = new Button { Content = confirm ? "Cancel" : "Close", IsCancel = true };
        actions.Children.Add(close);
        if (confirm)
        {
            Button agree = ButtonFor("Confirm", () => { view.DialogResult = true; return Task.CompletedTask; }, true);
            actions.Children.Add(agree);
        }
        content.Children.Add(new TextBox
        {
            Text = message, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 0, 0, 12)
        });
        view.Content = content;
        return view.ShowDialog() == true;
    }

    private void UseDarkCaption(Window window)
    {
        window.SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(window).Handle;
            SetCaptionTheme(handle, Dark);
        };
    }

    private static void SetCaptionTheme(nint handle, bool dark)
    {
        int enabled = dark ? 1 : 0;
        if (DwmSetWindowAttribute(handle, 20, ref enabled, sizeof(int)) != 0)
            _ = DwmSetWindowAttribute(handle, 19, ref enabled, sizeof(int));
    }

    [DllImport("dwmapi.dll", ExactSpelling = true)]
    private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);

    private bool RequireAdmin()
    {
        if (admin) return true;
        ShowDialog("Administrator required", "Close this window and open the trusted LARP Optimizer executable using Run as administrator. Use the same Windows account to access the same backups.", false);
        return false;
    }

    private static IEnumerable<JsonNode> Items(JsonNode? node) => node is JsonArray list ? list.OfType<JsonNode>() : [];
    private static string Bytes(JsonNode? node) => double.TryParse(StringValue(node), NumberStyles.Float, CultureInfo.InvariantCulture, out double bytes)
        ? $"{bytes / 1073741824:0.##} GiB" : "Unavailable";
    private static string Percent(JsonNode? node) => node is null ? "Unavailable" : $"{Value(node)}%";
    private static string OptionalUnit(JsonNode? node, string unit) => node is null ? "Unavailable" : $"{Value(node)} {unit}";

    private async Task Dashboard()
    {
        Subtitle.Text = "Live pressure, recommended changes and recent activity.";
        var buttons = Row(Controls);
        buttons.Children.Add(ButtonFor("Optimize this PC", async () => await Navigate("Optimize"), true));
        buttons.Children.Add(ButtonFor("Refresh inventory", async () =>
        {
            dashboardCache = null;
            await Navigate("Dashboard");
        }));
        liveMetrics = new StackPanel();
        Results.Children.Add(liveMetrics);
        var opportunity = Card(Results, "Recommended for this PC");
        Note(opportunity, "Checking the active power plan…");
        var recentActivity = Card(Results, "Recent activity");
        Note(recentActivity, "Reading the local journal…");
        var inventory = new StackPanel();
        Results.Children.Add(inventory);
        var pending = Card(inventory, "System inventory");
        Note(pending, "Reading hardware and network details…");

        if (samples.TryPeek(out _)) RenderMetrics(liveMetrics, samples.Last());
        var quick = await Execute(QuickMetrics.ReadAsync);
        if (quick is null) return;
        if (quick.Count > 1) UpdateMetrics(liveMetrics, quick);
        await Task.WhenAll(InspectInventory(), InspectRecommendations(), InspectRecent());

        async Task InspectInventory()
        {
            if (dashboardCache is not null && DateTime.UtcNow - dashboardCachedAt < TimeSpan.FromSeconds(45))
            {
                RenderInventory(dashboardCache, inventory);
                return;
            }
            var result = await Run(Request("dashboard"), remember: false);
            if (result?.FirstOrDefault() is not JsonNode info)
            {
                if (pending.IsLoaded) Note(pending, "Inventory unavailable. Use Refresh inventory to retry.");
                return;
            }
            dashboardCache = info;
            dashboardCachedAt = DateTime.UtcNow;
            if (info["Metrics"] is JsonObject metrics && liveMetrics is not null) UpdateMetrics(liveMetrics, metrics);
            RenderInventory(info, inventory);
        }
        async Task InspectRecommendations()
        {
            var request = Request("recommend");
            request["profile"] = "General Gaming";
            var result = await Run(request, remember: false);
            if (result?.FirstOrDefault() is not JsonNode recommendation)
            {
                if (opportunity.IsLoaded) Note(opportunity, "Analysis paused. You can run it from Optimize.");
                return;
            }
            opportunity.Children.RemoveAt(1);
            var changes = Items(recommendation["Changes"]).ToArray();
            string recommendedPreset = Value(recommendation["Preset"]);
            if (changes.Length == 0) Note(opportunity, "Performance and Competitive found no applicable CPU or power-plan change.");
            foreach (JsonNode change in changes)
            {
                Line(opportunity, Value(change["Name"]), $"{Value(change["Before"])} → {Value(change["After"])}");
                Note(opportunity, Value(change["Benefit"]));
            }
            if (changes.Length > 0) opportunity.Children.Add(ButtonFor("Review " + recommendedPreset, async () =>
            {
                activePreset = recommendedPreset;
                await Navigate("Optimize");
            }));
        }
        async Task InspectRecent()
        {
            var result = await Run(Request("history"), remember: false);
            if (result is null)
            {
                if (recentActivity.IsLoaded) Note(recentActivity, "History unavailable. Open Restore to retry.");
                return;
            }
            recentActivity.Children.RemoveAt(1);
            if (result.Count == 0) Note(recentActivity, "Verified changes and restore attempts will appear here.");
            foreach (var entry in Items(result).Take(3)) Line(recentActivity, Value(entry["Scope"]), SessionLabel(entry));
            recentActivity.Children.Add(ButtonFor("Open history", async () => await Navigate("Restore")));
        }
    }

    private void RenderInventory(JsonNode info, Panel destination)
    {
        destination.Children.Clear();
        Device.Text = $"{Value(info["Device"])}  /  {Value(info["Windows"])}";
        plans = info["Plans"]!.AsArray();
        adapters = info["Adapters"]!.AsArray();
        var hardware = Card(destination, "Hardware");
        foreach (JsonNode cpu in Items(info["CPU"]))
            Line(hardware, Value(cpu["Name"]), $"{Value(cpu["NumberOfCores"])} cores / {Value(cpu["NumberOfLogicalProcessors"])} logical processors");
        foreach (JsonNode gpu in Items(info["GPU"]))
            Line(hardware, Value(gpu["Model"]), $"driver {Value(gpu["Driver"])}   ·   dedicated VRAM {Bytes(gpu["DedicatedVRAMBytes"])}");
        Line(hardware, "Installed memory", Bytes(info["InstalledBytes"]));
        var storage = Card(destination, "Storage");
        foreach (JsonNode volume in Items(info["Volumes"]))
            Line(storage, Value(volume["DeviceID"]), $"{Bytes(volume["FreeSpace"])} free of {Bytes(volume["Size"])}");
        foreach (JsonNode drive in Items(info["PhysicalDisks"]))
            Line(storage, Value(drive["FriendlyName"]), $"{Value(drive["MediaType"])}   ·   {Value(drive["HealthStatus"])}");
        var network = Card(destination, "Network");
        foreach (JsonNode adapter in Items(adapters))
            Line(network, Value(adapter["Name"]), $"{Value(adapter["Type"])}   ·   {Value(adapter["LinkSpeed"])}   ·   IP {Joined(adapter["IP"])}   ·   Gateway {Joined(adapter["Gateway"])}   ·   DNS {Joined(adapter["DNS"])}");
        if (adapters.Count == 0) Note(network, "No connected adapters reported.");
        if (latestNetwork is JsonObject ping)
            Line(network, "Last ICMP test", $"{Value(ping["Destination"])}   ·   {OptionalUnit(ping["AverageMs"], "ms")} average   ·   {Percent(ping["LossPercent"])} loss   ·   {OptionalUnit(ping["JitterMs"], "ms")} jitter");
        else Note(network, "Run a ping test to measure latency, loss and jitter.");
        network.Children.Add(ButtonFor("Open network diagnostics", async () => await Navigate("Network")));
    }

    private static string Joined(JsonNode? node) => string.Join(", ", Items(node).Select(Value));

    private void UpdateMetrics(Panel parent, JsonObject metrics)
    {
        samples.Enqueue(metrics);
        if (samples.Count > 60) samples.Dequeue();
        RenderMetrics(parent, metrics);
    }

    private void RenderMetrics(Panel parent, JsonNode metrics)
    {
        if (paintMetrics is not null) { paintMetrics(metrics); return; }
        var card = Card(parent, "Live resource use");
        var grid = Row(card);
        var cpu = Metric("CPU");
        var memory = Metric("MEMORY");
        var gpu = Metric("GPU");
        var series = Select(card, "Trend since launch", ["CPU", "Memory", "GPU"], chartMetric, 153);
        var chart = new StackPanel();
        card.Children.Add(chart);
        series.SelectionChanged += (_, _) => { chartMetric = Selected(series); RenderTrend(chart); };
        paintMetrics = reading =>
        {
            cpu.Value.Text = Percent(reading["CpuPercent"]);
            cpu.Detail.Text = Joined(reading["ClockMHz"]) is { Length: > 0 } clock ? clock + " MHz reported" : "Processor use";
            memory.Value.Text = Percent(reading["MemoryPercent"]);
            memory.Detail.Text = $"{Bytes(reading["UsedBytes"])} used · {Bytes(reading["AvailableBytes"])} available";
            gpu.Value.Text = Percent(reading["GpuBusiestEnginePercent"]);
            gpu.Detail.Text = "Busiest reported engine";
            RenderTrend(chart);
        };
        paintMetrics(metrics);
        (TextBlock Value, TextBlock Detail) Metric(string label)
        {
            var group = new StackPanel { Width = 197, Margin = new Thickness(0, 2, 7, 4) };
            group.Children.Add(Text(label, "Muted", 11));
            var value = Text("", "Accent", 24);
            var detail = Text("", "Muted", 11);
            group.Children.Add(value);
            group.Children.Add(detail);
            grid.Children.Add(group);
            return (value, detail);
        }
    }

    private async Task Optimize()
    {
        Subtitle.Text = "Preview changes for this PC, then apply them with a backup.";
        int revision = pageRevision;
        var row = Row(Controls);
        var profile = Select(row, "Game profile", Profiles, activeProfile);
        var preset = Select(row, "Preset", Presets, activePreset, 148);
        preset.SelectionChanged += (_, _) => activePreset = Selected(preset);
        profile.SelectionChanged += async (_, _) =>
        {
            string nameAtStart = activeProfile = Selected(profile);
            var request = Request("profileSettings"); request["profile"] = activeProfile;
            var saved = await Run(request);
            if (Selected(profile) == nameAtStart && saved?.FirstOrDefault()?["Preset"] is JsonNode name)
                preset.SelectedItem = name.ToString();
        };
        var description = Text("", "Muted");
        description.Margin = new Thickness(0, 2, 0, 12);
        Controls.Children.Add(description);
        void Describe() => description.Text = Selected(preset) switch
        {
            "Safe" => "Review only.",
            "Balanced" => "Uses a moderate performance preference on supported CPUs while plugged in.",
            "Competitive" => "Reviews CPU boost, core parking and PCIe link power saving while plugged in. Check temperatures and frame times.",
            "Custom" => "Select an installed power plan or configure IPv4 DNS.",
            _ => "Favors CPU performance while plugged in. Power use and temperatures may rise."
        };
        Describe();
        var custom = new StackPanel { Visibility = activePreset == "Custom" ? Visibility.Visible : Visibility.Collapsed };
        Controls.Children.Add(custom);
        var customFields = Row(Card(custom, "Custom settings"));
        var power = Select(customFields, "Power plan", ["Keep current"], width: 200);
        var nic = Select(customFields, "Adapter", new[] { "Keep current" }.Concat(Items(adapters).Select(item => Value(item["Name"]))), width: 165);
        var provider = Select(customFields, "Provider", Providers, width: 140);
        var servers = Input(customFields, "Custom IPv4 addresses", width: 200);
        provider.IsEnabled = false;
        servers.IsEnabled = false;
        nic.SelectionChanged += (_, _) =>
        {
            provider.IsEnabled = nic.SelectedIndex > 0;
            servers.IsEnabled = nic.SelectedIndex > 0 && Selected(provider) == "Custom";
        };
        provider.SelectionChanged += (_, _) => servers.IsEnabled = nic.SelectedIndex > 0 && Selected(provider) == "Custom";
        async Task LoadCustom()
        {
            if (Selected(preset) != "Custom") return;
            var choices = await Run(Request("plans"));
            if (revision != pageRevision) return;
            if (choices is not null)
            {
                plans = choices;
                power.ItemsSource = new[] { "Keep current" }.Concat(Items(plans).Select(item => Value(item["Name"]))).ToArray();
                power.SelectedIndex = 0;
            }
            var connected = await Run(Request("adapters"));
            if (connected is null) return;
            adapters = connected;
            nic.ItemsSource = new[] { "Keep current" }.Concat(Items(adapters).Select(item => Value(item["Name"]))).ToArray();
            nic.SelectedIndex = 0;
        }
        preset.SelectionChanged += async (_, _) =>
        {
            custom.Visibility = Selected(preset) == "Custom" ? Visibility.Visible : Visibility.Collapsed;
            Describe();
            await LoadCustom();
        };
        var baseline = new CheckBox { Content = "Capture before and after resource measurements", IsChecked = activePreset == "Competitive" };
        Controls.Children.Add(baseline);
        preset.SelectionChanged += (_, _) => { if (activePreset == "Competitive") baseline.IsChecked = true; };
        var buttons = Row(Controls);
        buttons.Children.Add(ButtonFor("Optimize now", async () =>
        {
            var request = Request("plan");
            request["preset"] = Selected(preset);
            request["profile"] = Selected(profile);
            request["power"] = plans.FirstOrDefault(item => StringValue(item?["Name"]) == Selected(power))?["Id"]?.DeepClone();
            request["adapter"] = Items(adapters).FirstOrDefault(item => StringValue(item["Name"]) == Selected(nic))?["Id"]?.DeepClone();
            request["provider"] = Selected(provider);
            request["servers"] = servers.Text;
            request["baseline"] = baseline.IsChecked == true;
            await ReviewAndApply(request, false);
        }, true));
        buttons.Children.Add(ButtonFor("Edit selected profile", async () => await EditProfile(Selected(profile))));
        await LoadCustom();
    }

    private async Task ReviewAndApply(JsonObject request, bool dns, bool ethernet = false)
    {
        Results.Children.Clear();
        var analysis = Card(Results, "Analyze");
        Note(analysis, dns || ethernet ? "Reading the current adapter configuration…" : "Reading the active plan and applicable Windows settings…");
        var changes = await Run(request);
        if (changes is null)
        {
            if (analysis.IsLoaded) Note(analysis, Status.Text);
            return;
        }
        if (changes.Count == 0)
        {
            Results.Children.Clear();
            var empty = Card(Results, StringValue(request["preset"]) == "Safe" ? "Review complete" : "No applicable changes");
            Note(empty, ethernet ? "Energy Efficient Ethernet is already off." : dns ? "The adapter already uses the selected IPv4 DNS configuration."
                : StringValue(request["preset"]) == "Safe" ? "Safe is a read-only preset."
                : "The selected setting is already in place or this PC does not expose a supported change for this preset.");
            return;
        }
        Results.Children.Clear();
        var preview = Card(Results, "Review changes");
        var choices = new List<(CheckBox Box, JsonNode Change)>();
        foreach (JsonNode change in Items(changes))
        {
            bool allowed = admin || change["Administrator"]?.GetValue<bool>() != true;
            var box = new CheckBox { Content = Value(change["Name"]), IsChecked = allowed, IsEnabled = allowed };
            preview.Children.Add(box);
            choices.Add((box, change));
            Note(preview, Value(change["Scope"]));
            Line(preview, "Current → proposed", $"{Value(change["Before"])} → {Value(change["After"])}");
            Note(preview, Value(change["Benefit"]));
            Note(preview, $"Risk: {Value(change["Risk"])} · {(change["Administrator"]?.GetValue<bool>() == true ? "Administrator required" : "Uses current Windows permissions")}");
        }
        var selectedCount = Text("", "Muted");
        preview.Children.Add(selectedCount);
        var apply = ButtonFor("Apply changes", async () =>
        {
            var selected = choices.Where(item => item.Box.IsChecked == true).Select(item => item.Change).ToArray();
            if (selected.Length == 0) return;
            var progress = Text("Applying and verifying each setting…", "Muted");
            preview.Children.Add(progress);
            request["selected"] = new JsonArray(selected.Select(change => change["Id"]?.DeepClone()).ToArray());
            request["reviewed"] = new JsonArray(selected.Select(change => change.DeepClone()).ToArray());
            request["action"] = ethernet ? "eeeApply" : dns ? "dnsApply" : "apply";
            var report = await Run(request, true);
            if (report?.FirstOrDefault() is not JsonNode session)
            {
                progress.Text = Status.Text;
                return;
            }
            dashboardCache = null;
            RenderSession(session, "Optimization results");
            var follow = Row(Results);
            follow.Children.Add(ButtonFor("View history and restore", async () => await Navigate("Restore")));
            follow.Children.Add(ButtonFor("Export session", () => Export("LARP session.json", session)));
        }, true);
        Row(preview).Children.Add(apply);
        void RefreshSelection()
        {
            var powerPlan = choices.Find(item => StringValue(item.Change["Id"]) == "power.plan");
            if (powerPlan.Box is not null)
            {
                foreach (var item in choices.Where(item => StringValue(item.Change["Target"]) == StringValue(powerPlan.Change["After"])))
                {
                    item.Box.IsEnabled = powerPlan.Box.IsChecked == true;
                    if (!item.Box.IsEnabled) item.Box.IsChecked = false;
                }
            }
            int count = choices.Count(item => item.Box.IsChecked == true);
            apply.IsEnabled = count > 0;
            selectedCount.Text = $"{count} of {choices.Count} changes selected";
        }
        foreach (var item in choices) item.Box.Click += (_, _) => RefreshSelection();
        RefreshSelection();
    }

    private async Task EditProfile(string name)
    {
        var request = Request("profile"); request["profile"] = name;
        var data = await Run(request);
        if (data?.FirstOrDefault() is not JsonNode info) return;
        var settings = info["Settings"]!;
        Controls.Children.Clear();
        Heading.Text = name;
        Subtitle.Text = "Local profile preferences and running executable candidates";
        var panel = Row(Controls);
        var preset = Select(panel, "Preferred preset", Presets, StringValue(settings["Preset"]));
        var exe = Input(panel, "Executable path (optional)", StringValue(settings["Executable"]), 355);
        var hostname = Input(panel, "Game server (optional)", StringValue(settings["Host"]), 250);
        var buttons = Row(Controls);
        buttons.Children.Add(ButtonFor("Browse executable", () =>
        {
            var picker = new OpenFileDialog { Filter = "Executable files (*.exe)|*.exe", CheckFileExists = true };
            if (picker.ShowDialog(this) == true) exe.Text = picker.FileName;
            return Task.CompletedTask;
        }));
        buttons.Children.Add(ButtonFor("Save profile", async () =>
        {
            var save = Request("saveProfile");
            save["profile"] = name; save["preset"] = Selected(preset); save["executable"] = exe.Text; save["host"] = hostname.Text;
            if (await Run(save) is not null)
            {
                activeProfile = name;
                activePreset = Selected(preset);
                Status.Text = "Profile saved.";
            }
        }, true));
        buttons.Children.Add(ButtonFor("Test saved game server", async () =>
        {
            var read = await Run(request);
            if (read?.FirstOrDefault() is not JsonNode current) return;
            string host = StringValue(current["Settings"]?["Host"]);
            if (host.Length == 0) { ShowDialog("Game server", "Save a server hostname first.", false); return; }
            var ping = Request("ping"); ping["host"] = host; ping["count"] = 5; ping["timeout"] = 750;
            await NetworkResult(ping, "Game server ICMP");
        }));
        buttons.Children.Add(ButtonFor("Restore profile changes", async () => await RestoreFlow("", name, "")));
        buttons.Children.Add(ButtonFor("Back to Optimize", async () => await Navigate("Optimize")));
        ShowResult("Profile detection", info);
    }

    private async Task Cpu()
    {
        Subtitle.Text = "Processor topology, power plan and background CPU use";
        var row = Row(Controls);
        row.Children.Add(ButtonFor("Refresh CPU data", async () => await Navigate("CPU")));
        row.Children.Add(ButtonFor("Review power plans", async () => await Navigate("Optimize")));
        var data = await Run(Request("cpu"));
        if (data?.FirstOrDefault() is JsonNode cpu)
        {
            ShowResult("CPU snapshot", new JsonObject { ["Processors"] = cpu["CPU"]?.DeepClone(),
                ["ActivePowerPlan"] = cpu["Power"]?.DeepClone(), ["PluggedInPerformancePreference"] = cpu["PerformancePreferenceAC"]?.DeepClone(),
                ["PluggedInBoostPolicy"] = cpu["BoostPolicyAC"]?.DeepClone(), ["PluggedInPcieLinkSaving"] = cpu["PcieLinkSavingAC"]?.DeepClone() });
            ProcessTable("Highest CPU usage", cpu["Processes"], "CpuPercent", "%");
        }
        Note(Controls, "Windows does not provide a reliable general-purpose thermal or power throttling reading for this view.");
    }

    private async Task Gpu()
    {
        Subtitle.Text = "Display adapters, drivers and reported refresh rates";
        var row = Row(Controls);
        row.Children.Add(ButtonFor("Graphics settings", () => OpenSettings("display-advancedgraphics")));
        row.Children.Add(ButtonFor("Refresh rate settings", () => OpenSettings("display-advanced")));
        foreach (string vendor in new[] { "NVIDIA", "AMD", "Intel" })
            row.Children.Add(ButtonFor(vendor + " control panel", async () =>
            {
                var request = Request("gpuPanel"); request["vendor"] = vendor;
                await Run(request);
            }));
        var data = await Run(Request("gpu"));
        if (data is null) return;
        ShowResult("Detected display adapters", data);
        foreach (var item in Items(data).Reverse())
        {
            var gpu = Card(Results, Value(item["Model"]));
            TableRow(gpu, "Driver", "Dedicated VRAM", "Refresh");
            TableRow(gpu, Value(item["Driver"]), Bytes(item["DedicatedVRAMBytes"]), OptionalUnit(item["RefreshHz"], "Hz"));
            if (Number(item["DeviceErrorCode"]) is > 0) Note(gpu, $"Windows device error code {Value(item["DeviceErrorCode"])}.");
            BringLastResultForward();
        }
    }

    private async Task Memory()
    {
        Subtitle.Text = "Physical memory pressure, process working sets and startup review";
        var row = Row(Controls);
        row.Children.Add(ButtonFor("Refresh memory data", async () => await Navigate("Memory")));
        row.Children.Add(ButtonFor("Review Startup Apps", () => OpenSettings("startupapps")));
        var data = await Run(Request("memory"));
        if (data?.FirstOrDefault() is JsonNode memory)
        {
            var metrics = memory["Metrics"];
            ShowResult("Memory snapshot", new JsonObject { ["Used"] = Bytes(metrics?["UsedBytes"]),
                ["Available"] = Bytes(metrics?["AvailableBytes"]), ["Utilization"] = Percent(metrics?["MemoryPercent"]),
                ["StartupEntries"] = memory["Startup"]?.DeepClone() });
            ProcessTable("Largest private working sets", memory["Processes"], "PrivateWorkingSetMiB", " MiB");
        }
    }

}
internal static class VisualExtensions
{
    internal static Window? Window(this DependencyObject element) => System.Windows.Window.GetWindow(element);
}

