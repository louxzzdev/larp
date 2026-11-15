using System.Diagnostics;
using System.IO;
using System.Windows.Automation;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace LarpOptimizer;

public partial class MainWindow
{
    private async Task Network()
    {
        int revision = pageRevision;
        Subtitle.Text = "Run bounded connectivity tests and inspect the selected network adapter.";
        var ping = Card(Controls, "Connectivity and routes");
        var pingFields = Row(ping);
        var host = Input(pingFields, "Target: Gateway, Cloudflare, Google or host", "Gateway", 285);
        var samples = Input(pingFields, "Samples", "5", 78);
        var timeout = Input(pingFields, "Timeout (ms)", "750", 95);
        var buttons = Row(ping);
        JsonObject Probe(string action)
        {
            var request = Request(action);
            request["host"] = host.Text.Trim();
            if (action == "compare" && new[] { "Gateway", "Google", "Cloudflare" }.Contains(host.Text.Trim(), StringComparer.OrdinalIgnoreCase))
                request["host"] = "";
            if (action is "ping" or "compare" or "endpoints")
            {
                if (!int.TryParse(samples.Text, out int count) || count is < 2 or > 15 ||
                    !int.TryParse(timeout.Text, out int limit) || limit is < 100 or > 2000)
                    throw new ArgumentException("Enter 2–15 samples and a timeout of 100–2000 ms.");
                request["count"] = count;
                request["timeout"] = limit;
            }
            return request;
        }
        buttons.Children.Add(ButtonFor("Ping target", async () => await NetworkResult(Probe("ping"), "ICMP measurements"), true));
        buttons.Children.Add(ButtonFor("Compare loss", async () =>
        {
            var request = Probe("compare");
            string extra = StringValue(request["host"]);
            if (ShowDialog("Test destinations", "ICMP probes will contact the default gateway, Cloudflare (1.1.1.1) and Google (8.8.8.8)." +
                (extra.Length > 0 ? "\nAdditional destination: " + extra : ""), true))
                await NetworkResult(request, "Multi-destination comparison");
        }));
        buttons.Children.Add(ButtonFor("Active routes", async () => await NetworkResult(Request("routes"), "Active routes")));
        buttons.Children.Add(ButtonFor("Route to host", async () => await NetworkResult(Probe("route"), "Route and source interface")));
        buttons.Children.Add(ButtonFor("Traceroute", async () => await NetworkResult(Probe("trace"), "Traceroute · up to 20 hops")));
        Note(ping, "ICMP measurements can differ from game traffic. Jitter is the mean absolute difference between successive successful replies.");
        var regions = Card(Controls, "Compare game servers");
        var hosts = Row(regions);
        var primaryHost = Input(hosts, "Game server or region A");
        var alternateHost = Input(hosts, "Game server or region B");
        regions.Children.Add(ButtonFor("Compare latency", async () =>
        {
            var req = Probe("endpoints");
            req["host"] = primaryHost.Text.Trim();
            req["alternate"] = alternateHost.Text.Trim();
            await NetworkResult(req, "Server comparison");
        }));
        Note(regions, "Enter two selectable server hostnames or IPs. The test uses the sample count and timeout above.");

        var dns = Card(Controls, "Adapter and IPv4 DNS");
        var dnsFields = Row(dns);
        var adapter = Select(dnsFields, "Connected adapter", Items(adapters).Select(item => Value(item["Name"])), width: 160);
        var provider = Select(dnsFields, "IPv4 provider", Providers, width: 150);
        var servers = Input(dnsFields, "Custom IPv4 addresses", width: 205);
        servers.IsEnabled = false;
        provider.SelectionChanged += (_, _) => servers.IsEnabled = Selected(provider) == "Custom";
        string AdapterId() => StringValue(adapters.FirstOrDefault(x => StringValue(x?["Name"]) == Selected(adapter))?["Id"]) is { Length: > 0 } id
            ? id : throw new InvalidOperationException("Select a connected adapter.");
        var adapterButtons = Row(dns);
        adapterButtons.Children.Add(ButtonFor("Inspect adapter", async () =>
        {
            var req = Request("adapter"); req["adapter"] = AdapterId();
            await NetworkResult(req, "Driver and supported adapter settings");
        }));
        adapterButtons.Children.Add(ButtonFor("Review DNS change", async () =>
        {
            var req = Request("dnsPlan");
            req["adapter"] = AdapterId(); req["provider"] = Selected(provider); req["servers"] = servers.Text; req["baseline"] = false;
            await ReviewAndApply(req, true);
        }));
        adapterButtons.Children.Add(ButtonFor("Review Ethernet latency setting", async () =>
        {
            var req = Request("eeePlan"); req["adapter"] = AdapterId(); req["baseline"] = false;
            await ReviewAndApply(req, false, true);
        }));
        Note(dns, "Energy Efficient Ethernet is available on some wired adapters. Applying the change can briefly disconnect the link.");
        adapterButtons.Children.Add(ButtonFor("Recheck configuration", async () => await Navigate("Network")));
        adapterButtons.Children.Add(ButtonFor("Flush DNS cache", async () =>
        {
            if (RequireAdmin() && ShowDialog("Flush DNS cache", "Clear cached Windows DNS answers. Subsequent requests resolve again.", true))
                await NetworkResult(Request("flush"), "DNS cache flush", true);
        }));
        Note(dns, "Default restores automatic IPv4 DNS and requires a source that provides DNS. IPv6 uses its existing configuration. DNS usually has no effect on established game latency.");

        var query = Card(Controls, "DNS query timing");
        var queryFields = Row(query);
        var domain = Input(queryFields, "Fully qualified hostname", width: 235);
        var server = Input(queryFields, "Resolver IPv4 (optional)", width: 200);
        query.Children.Add(ButtonFor("Time query", async () =>
        {
            var req = Request("dnsTest"); req["host"] = domain.Text; req["server"] = server.Text.Trim();
            await NetworkResult(req, "DNS query");
        }));
        var data = await Run(Request("adapters"));
        if (data is not null && pageRevision == revision)
        {
            adapters = data;
            adapter.ItemsSource = Items(data).Select(item => Value(item["Name"])).ToArray();
            adapter.SelectedIndex = data.Count > 0 ? 0 : -1;
            if (Results.Children.Count == 0) ShowResult("Connected interfaces", data);
        }
    }

    private async Task NetworkResult(JsonObject request, string title, bool mutation = false)
    {
        var data = await Run(request, mutation);
        if (data is null) return;
        if (StringValue(request["action"]) == "ping") latestNetwork = data.FirstOrDefault();
        ShowResult(title, data);
        if (StringValue(request["action"]) == "ping" && latestNetwork is JsonNode ping)
        {
            var summary = Card(Results, "Connection snapshot");
            Line(summary, Value(ping["Destination"]), Value(ping["Address"]));
            TableRow(summary, "Average", "Jitter", "Loss");
            TableRow(summary, OptionalUnit(ping["AverageMs"], "ms"), OptionalUnit(ping["JitterMs"], "ms"), Percent(ping["LossPercent"]));
            BringLastResultForward();
        }
        if (StringValue(request["action"]) == "endpoints" && data.FirstOrDefault() is JsonNode comparison)
        {
            var table = Card(Results, "Sampled server latency");
            TableRow(table, "Server", "Median", "P95", "Loss");
            foreach (var test in Items(comparison["Tests"]))
                TableRow(table, Value(test["Destination"]), OptionalUnit(test["MedianMs"], "ms"), OptionalUnit(test["P95Ms"], "ms"), Percent(test["LossPercent"]));
            if (comparison["LowerMedianWithoutLoss"] is JsonNode winner) Line(table, "Lower sampled median with zero loss", Value(winner));
            BringLastResultForward();
        }
    }

    private void Diagnostics()
    {
        Subtitle.Text = "Capture repeatable resource and connectivity measurements and export the results.";
        var card = Card(Controls, "Before and after");
        var fields = Row(card);
        var target = Input(fields, "Optional ICMP target", width: 200);
        var dns = Input(fields, "Optional DNS hostname", width: 200);
        Note(card, "Use the same game load, power source, network and signal conditions. These measurements do not estimate FPS.");
        var buttons = Row(card);
        buttons.Children.Add(ButtonFor("Capture baseline", async () =>
        {
            var req = Request("benchmark");
            req["host"] = target.Text.Trim(); req["dnsHost"] = dns.Text.Trim(); req["count"] = 5; req["timeout"] = 750;
            var result = await Run(req);
            if (result is null) return;
            baselineRequest = req; baselineResult = result; followUp = null;
            ShowComparison();
        }, true));
        buttons.Children.Add(ButtonFor("Capture follow-up", async () =>
        {
            if (baselineRequest is null) { ShowDialog("Diagnostics", "Capture a baseline first.", false); return; }
            if (!ShowDialog("Repeat baseline tests", "Repeat the same measurements and destinations?\n" + Format(baselineRequest), true)) return;
            var result = await Run(baselineRequest);
            if (result is null) return;
            followUp = result;
            ShowComparison();
        }));
        buttons.Children.Add(ButtonFor("Export comparison", () => Export("LARP diagnostics.json", baselineResult is null ? null : Comparison())));
        buttons.Children.Add(ButtonFor("Export latest result", () => Export("LARP result.json", latestResult)));
        if (baselineResult is not null) ShowComparison();
    }

    private void ShowComparison()
    {
        ShowResult("Measurement details", Comparison());
        var summary = Card(Results, "Before and after");
        BringLastResultForward();
        MeasurementRows(summary, Items(baselineResult).FirstOrDefault(), Items(followUp).FirstOrDefault(), true);
        Note(summary, "Differences describe the samples taken. Compare with the same workload and connection.");
    }

    private void BringLastResultForward()
    {
        var frame = Results.Children[^1];
        Results.Children.Remove(frame);
        Results.Children.Insert(0, frame);
    }

    private JsonObject Comparison() => new()
    {
        ["Request"] = baselineRequest?.DeepClone(), ["Baseline"] = baselineResult?.DeepClone(), ["FollowUp"] = followUp?.DeepClone()
    };

    private async Task Export(string filename, JsonNode? payload)
    {
        if (payload is null) { ShowDialog("Export", "Run a measurement or load history first.", false); return; }
        var picker = new SaveFileDialog { Filter = "JSON reports (*.json)|*.json|Plain text (*.txt)|*.txt",
            FileName = Path.GetFileNameWithoutExtension(filename), AddExtension = true };
        if (picker.ShowDialog(this) != true) return;
        await File.WriteAllTextAsync(picker.FileName, picker.FilterIndex == 2 ? Format(payload) : payload.ToJsonString(Pretty));
        Status.Text = "Exported to " + picker.FileName;
    }

    private async Task Restore()
    {
        Subtitle.Text = "Find previous sessions, inspect verification and recover original settings.";
        JsonArray? history = null;
        var historyCard = Card(Controls, "Sessions");
        var fields = Row(historyCard);
        var search = Input(fields, "Search session, profile or setting", width: 235);
        var period = Select(fields, "Period", ["Any time", "Last 7 days", "Last 30 days"], width: 122);
        var status = Select(fields, "Status", ["All statuses", "Applied", "Restored", "Needs attention"], width: 132);
        var module = Select(fields, "Optimization", ["All modules", "cpu.epp.ac", "cpu.parking.ac", "cpu.boost.ac", "power.plan", "power.pcie.ac", "network.dns.ipv4", "network.ethernet.eee"], width: 185);
        var list = new ListBox { MaxHeight = 215, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(0, 0, 0, 10) };
        list.SetResourceReference(BackgroundProperty, "Canvas");
        list.SetResourceReference(ForegroundProperty, "Text");
        list.SetResourceReference(BorderBrushProperty, "Stroke");
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        AutomationProperties.SetName(list, "Optimization sessions");
        historyCard.Children.Add(list);
        var count = Text("Reading local journal…", "Muted");
        historyCard.Children.Add(count);
        void Filter()
        {
            if (history is null) return;
            string query = search.Text.Trim();
            int days = period.SelectedIndex == 1 ? 7 : period.SelectedIndex == 2 ? 30 : 0;
            var previous = (list.SelectedItem as SessionRow)?.Session;
            var matches = Items(history).Where(item =>
            {
                if (days > 0 && (Timestamp(item["At"]) is not DateTimeOffset date || date < DateTimeOffset.Now.AddDays(-days))) return false;
                var changes = Items(item["Changes"]).ToArray();
                string[] states = changes.Select(change => StringValue(change["Status"])).ToArray();
                if (status.SelectedIndex is 1 or 2 && !states.Contains(Selected(status))) return false;
                if (status.SelectedIndex == 3 && !states.Any(state => state is "Apply failed" or "Restore failed" or "Conflict" or "Applying" or "Restoring")) return false;
                if (module.SelectedIndex > 0 && !changes.Any(change => StringValue(change["Id"]) == Selected(module))) return false;
                return query.Length == 0 || new[] { Value(item["Id"]), Value(item["Scope"]), SessionLabel(item) }
                    .Concat(changes.Select(change => Value(change["Id"]) + " " + Value(change["Name"])))
                    .Any(field => field.Contains(query, StringComparison.OrdinalIgnoreCase));
            }).Select(item => new SessionRow(item, $"{Value(item["Scope"])}   ·   {SessionLabel(item)}")).ToArray();
            list.ItemsSource = matches;
            list.SelectedItem = matches.FirstOrDefault(row => ReferenceEquals(row.Session, previous));
            count.Text = matches.Length == 0 ? "No sessions match these filters." : $"{matches.Length} of {history.Count} sessions";
        }
        search.TextChanged += (_, _) => Filter();
        period.SelectionChanged += (_, _) => Filter();
        status.SelectionChanged += (_, _) => Filter();
        module.SelectionChanged += (_, _) => Filter();
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is SessionRow row) RenderSession(row.Session, "Session details");
            else Results.Children.Clear();
        };
        var buttons = Row(historyCard);
        buttons.Children.Add(ButtonFor("Restore selected", async () => await RestoreFlow(
            list.SelectedItem is SessionRow row ? Value(row.Session["Id"]) : throw new InvalidOperationException("Select a session first."),
            "", module.SelectedIndex > 0 ? Selected(module) : ""), true));
        buttons.Children.Add(ButtonFor("Restore all", async () => await RestoreFlow("", "", "")));
        buttons.Children.Add(ButtonFor("Refresh history", async () => await Navigate("Restore")));
        buttons.Children.Add(ButtonFor("Export history", () => Export("LARP modification history.json", history)));
        buttons.Children.Add(ButtonFor("Create Windows restore point", async () =>
        {
            if (RequireAdmin() && ShowDialog("Windows restore point", "Ask System Protection to create a restore point. Availability depends on system settings and Windows creation intervals.", true))
            {
                var result = await Run(Request("restorePoint"), true);
                if (result is not null) ShowResult("Verified restore point", result);
            }
        }));
        buttons.Children.Add(ButtonFor("Export selected session", () => Export("LARP session.json", (list.SelectedItem as SessionRow)?.Session)));
        history = await Run(Request("history"), remember: false);
        Filter();
    }

    private sealed record SessionRow(JsonNode Session, string Label)
    {
        public override string ToString() => Label;
    }

    private void RenderSession(JsonNode session, string title)
    {
        Results.Children.Clear();
        var details = Card(Results, title);
        Note(details, $"{Value(session["Scope"])} · {SessionLabel(session)} · {Duration(session)}");
        TableRow(details, "Setting", "Before", "Requested", "Status");
        foreach (var change in Items(session["Changes"]))
        {
            TableRow(details, StringValue(change["Name"]) is { Length: > 0 } name ? name : Value(change["Id"]),
                Value(change["Before"]), Value(change["After"]), Value(change["Status"]));
            if (Items(change["Events"]).LastOrDefault() is JsonNode last) Note(details, Value(last["Detail"]));
        }
        if (session["Baseline"] is not null || session["After"] is not null)
        {
            var comparison = Card(Results, "Resource comparison");
            MeasurementRows(comparison, session["Baseline"], session["After"]);
            Note(comparison, "Values are sampled CPU, memory and GPU usage. Workload affects the comparison.");
        }
        var raw = new Expander { Header = "Verification and restore events", Content = Text(Format(session), "Muted") };
        raw.SetResourceReference(ForegroundProperty, "Text");
        details.Children.Add(raw);
    }

    private async Task RestoreFlow(string operation, string profile, string module)
    {
        var req = Request("restore");
        req["operation"] = operation; req["profile"] = profile; req["module"] = module; req["overrides"] = new JsonArray();
        if (!ShowDialog("Restore settings", "Restore matching journal entries newest first. External changes require separate confirmation.\n\n" +
            $"Operation: {(operation.Length == 0 ? "All" : operation)}\nScope: {(profile.Length == 0 ? "All" : profile)}\nModule: {(module.Length == 0 ? "All" : module)}", true)) return;
        var result = await Run(req, true);
        if (result is null) return;
        ShowResult("Restore results", result);
        var conflicts = Items(result).Where(item => StringValue(item["Status"]) == "Conflict").ToArray();
        if (conflicts.Length == 0) return;
        var overrides = new JsonArray(conflicts.Select(item => item.DeepClone()).ToArray());
        if (!ShowDialog("Confirm external changes", "Overwrite these external values with the recorded originals?\n\n" + Format(overrides), true)) return;
        req["overrides"] = overrides;
        var retry = await Run(req, true);
        if (retry is not null) ShowResult("Restore results after conflict review", retry);
    }

    private void Tools()
    {
        Subtitle.Text = "Open Windows tools for investigating bottlenecks and reviewing apps.";
        var monitoring = Card(Controls, "Process investigation");
        Note(monitoring, "Inspect per-process CPU, memory, disk and network activity while reproducing the issue.");
        var processTools = Row(monitoring);
        processTools.Children.Add(ButtonFor("Task Manager", () => OpenSystemTool("Taskmgr.exe"), true));
        processTools.Children.Add(ButtonFor("Resource Monitor", () => OpenSystemTool("resmon.exe")));

        var cleanup = Card(Controls, "Apps and storage");
        Note(cleanup, "Review startup entries, installed apps and temporary files in Windows Settings.");
        var cleanupTools = Row(cleanup);
        cleanupTools.Children.Add(ButtonFor("Startup Apps", () => OpenSettings("startupapps")));
        cleanupTools.Children.Add(ButtonFor("Installed Apps", () => OpenSettings("appsfeatures")));
        cleanupTools.Children.Add(ButtonFor("Storage settings", () => OpenSettings("storagesense")));

        var gaming = Card(Controls, "Gaming and display");
        var gamingTools = Row(gaming);
        gamingTools.Children.Add(ButtonFor("Game Mode", () => OpenSettings("gaming-gamemode")));
        gamingTools.Children.Add(ButtonFor("Graphics preferences", () => OpenSettings("display-advancedgraphics")));
        gamingTools.Children.Add(ButtonFor("Display refresh rate", () => OpenSettings("display-advanced")));
    }

    private void About()
    {
        Subtitle.Text = "Meet the community behind LARP Optimizer.";
        var community = Card(Controls, "LARP community");
        Note(community, "LARP is a community focused on making scripts and tools that help others.");
        Note(community, "LARP Optimizer is one of those tools, built to help Windows gamers monitor their systems and tune settings they can restore later.");
        Row(community).Children.Add(ButtonFor("Join the LARP community on Discord", () =>
        {
            Process.Start(new ProcessStartInfo("https://discord.gg/wCB5U6RxDf") { UseShellExecute = true });
            return Task.CompletedTask;
        }, true));
    }

    private static Task OpenSystemTool(string filename)
    {
        Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, filename)) { UseShellExecute = true });
        return Task.CompletedTask;
    }

    private async Task Settings()
    {
        Subtitle.Text = "Review Windows settings and local application data.";
        var settingsQuery = Input(Controls, "Search settings", width: 270);
        var appearance = Card(Controls, "Appearance");
        var appearanceFields = Row(appearance);
        var themes = new Dictionary<string, Button>();
        void MarkTheme()
        {
            foreach (var (name, button) in themes)
            {
                bool selected = preferences.Theme == name;
                button.SetResourceReference(BackgroundProperty, selected ? "Accent" : "Panel");
                button.SetResourceReference(ForegroundProperty, selected ? "OnAccent" : "Text");
                AutomationProperties.SetItemStatus(button, selected ? "Selected" : "Available");
            }
        }
        foreach (string name in new[] { "Dark", "Light" })
        {
            var theme = ButtonFor(name + " theme", async () =>
            {
                await ChangePreferences(preferences with { Theme = name });
                MarkTheme();
            });
            themes[name] = theme;
            appearanceFields.Children.Add(theme);
        }
        MarkTheme();
        var compactSidebar = new CheckBox { Content = "Compact sidebar", IsChecked = preferences.CompactSidebar };
        var reducedMotion = new CheckBox { Content = "Reduce motion", IsChecked = preferences.ReducedMotion };
        appearance.Children.Add(compactSidebar);
        appearance.Children.Add(reducedMotion);
        Note(appearance, "Ctrl+K opens search. Ctrl+B toggles the sidebar. Ctrl+1, 2 and 3 open the workspace pages.");
        var monitoring = Card(Controls, "Monitoring");
        string RefreshLabel() => preferences.RefreshSeconds == 0 ? "Off" : $"{preferences.RefreshSeconds} seconds";
        var refresh = Select(monitoring, "Dashboard refresh", ["Off", "12 seconds", "30 seconds", "60 seconds"], RefreshLabel(), 175);
        Note(monitoring, "Live sampling runs on the foreground dashboard. The other screens collect readings on demand.");
        bool syncing = false;
        async Task SaveControls()
        {
            if (syncing) return;
            await ChangePreferences(new Preferences(preferences.Theme, reducedMotion.IsChecked == true, compactSidebar.IsChecked == true,
                refresh.SelectedIndex switch { 0 => 0, 2 => 30, 3 => 60, _ => 12 }));
        }
        refresh.SelectionChanged += async (_, _) => await SaveControls();
        compactSidebar.Click += async (_, _) => await SaveControls();
        reducedMotion.Click += async (_, _) => await SaveControls();
        var windowsSettings = Card(Controls, "Windows integration");
        var buttons = Row(windowsSettings);
        buttons.Children.Add(ButtonFor("Game Mode", () => OpenSettings("gaming-gamemode")));
        buttons.Children.Add(ButtonFor("Startup Apps", () => OpenSettings("startupapps")));
        buttons.Children.Add(ButtonFor("Windows power settings", () => OpenSettings("powersleep")));
        buttons.Children.Add(ButtonFor("Open local data folder", () =>
        {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LARP Optimizer");
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { ArgumentList = { path } });
            return Task.CompletedTask;
        }));
        Note(windowsSettings, "Use the same Windows account when opening the app as administrator to access the same journal.");
        var localSettings = Card(Controls, "Local preferences");
        localSettings.Children.Add(ButtonFor("Reset interface preferences", async () =>
        {
            if (!ShowDialog("Reset interface preferences", "Reset theme, sidebar, motion and dashboard refresh to their defaults?", true)) return;
            syncing = true;
            await ChangePreferences(new());
            MarkTheme();
            refresh.SelectedItem = RefreshLabel();
            compactSidebar.IsChecked = preferences.CompactSidebar;
            reducedMotion.IsChecked = preferences.ReducedMotion;
            syncing = false;
        }));
        var searchable = new[] { (appearance, "appearance theme light dark motion animation sidebar shortcut keyboard"),
            (monitoring, "monitoring refresh polling performance"), (windowsSettings, "windows game startup power folder administrator"),
            (localSettings, "preferences reset defaults") };
        var noMatches = Text("No matching settings.", "Muted");
        noMatches.Visibility = Visibility.Collapsed;
        Controls.Children.Add(noMatches);
        settingsQuery.TextChanged += (_, _) =>
        {
            string[] terms = settingsQuery.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            int matches = 0;
            foreach (var (section, keywords) in searchable)
            {
                bool match = terms.All(term => keywords.Contains(term, StringComparison.OrdinalIgnoreCase));
                if (section.Parent is FrameworkElement frame) frame.Visibility = match ? Visibility.Visible : Visibility.Collapsed;
                if (match) matches++;
            }
            Results.Visibility = terms.All(term => searchable[2].Item2.Contains(term, StringComparison.OrdinalIgnoreCase))
                ? Visibility.Visible : Visibility.Collapsed;
            noMatches.Visibility = matches == 0 ? Visibility.Visible : Visibility.Collapsed;
        };
        var data = await Run(Request("windows"));
        if (data is not null) ShowResult("Windows review", data);
    }

    private static Task OpenSettings(string page)
    {
        Process.Start(new ProcessStartInfo("ms-settings:" + page) { UseShellExecute = true });
        return Task.CompletedTask;
    }
}

