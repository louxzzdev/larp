using System.Globalization;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace LarpOptimizer;

public partial class MainWindow
{
    private static DateTimeOffset? Timestamp(JsonNode? value) =>
        DateTimeOffset.TryParse(StringValue(value), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var time) ? time : null;

    private static double? Number(JsonNode? value) =>
        double.TryParse(StringValue(value), NumberStyles.Float, CultureInfo.InvariantCulture, out double number) && double.IsFinite(number) ? number : null;

    private static string SessionLabel(JsonNode session)
    {
        var date = Timestamp(session["At"])?.ToLocalTime().ToString("g") ?? "Unknown date";
        string state = string.Join(", ", Items(session["Changes"]).Select(change => Value(change["Status"])).Distinct());
        return $"{date}  ·  {(state.Length == 0 ? "No changes" : state)}";
    }

    private static string Duration(JsonNode session)
    {
        if (Number(session["DurationMs"]) is double duration && duration >= 0)
            return TimeSpan.FromMilliseconds(duration).TotalSeconds.ToString("0.0") + " s";
        var start = Timestamp(session["At"]);
        var finish = Items(session["Changes"]).SelectMany(change => Items(change["Events"]))
            .Where(entry => StringValue(entry["Status"]) is "Applied" or "Apply failed" or "Skipped")
            .Select(entry => Timestamp(entry["At"])).Max();
        return start is not null && finish is not null && finish >= start
            ? (finish.Value - start.Value).TotalSeconds.ToString("0.0") + " s (journal)"
            : "Unavailable";
    }

    private void RenderTrend(Panel destination)
    {
        destination.Children.Clear();
        string key = chartMetric switch { "Memory" => "MemoryPercent", "GPU" => "GpuBusiestEnginePercent", _ => "CpuPercent" };
        var points = samples.Select(sample => (At: Timestamp(sample["At"]), Reading: Number(sample[key])))
            .Where(point => point.At is not null && point.Reading is >= 0 and <= 100)
            .Select(point => (At: point.At!.Value, Reading: point.Reading!.Value)).OrderBy(point => point.At).ToArray();
        if (points.Length < 2) { Note(destination, "Waiting for two measured samples."); return; }
        var plot = new Canvas { Height = 70, ClipToBounds = true };
        var line = new Polyline { StrokeThickness = 1.5 };
        line.SetResourceReference(Shape.StrokeProperty, "Accent");
        plot.Children.Add(line);
        void Draw()
        {
            double span = Math.Max(1, (points[^1].At - points[0].At).TotalMilliseconds);
            line.Points = new PointCollection(points.Select(point =>
                new Point(1 + Math.Max(0, plot.ActualWidth - 2) * (point.At - points[0].At).TotalMilliseconds / span,
                    1 + (plot.Height - 2) * (100 - point.Reading) / 100)));
        }
        plot.SizeChanged += (_, _) => Draw();
        string caption = $"{points.Length} readings · {points[0].At.ToLocalTime():HH:mm:ss}–{points[^1].At.ToLocalTime():HH:mm:ss} · latest {points[^1].Reading:0.#}%";
        AutomationProperties.SetName(plot, $"{chartMetric} trend, zero to one hundred percent. {caption}");
        plot.ToolTip = $"Range {points.Min(point => point.Reading):0.#}% to {points.Max(point => point.Reading):0.#}%";
        destination.Children.Add(plot);
        Note(destination, caption);
    }

    private void ProcessTable(string title, JsonNode? data, string valueKey, string unit)
    {
        var card = Card(Results, title);
        if (!Items(data).Any()) { Note(card, "Windows returned no process readings."); return; }
        TableRow(card, "Process", "PID", "Reading");
        foreach (JsonNode item in Items(data))
            TableRow(card, Value(item["Name"]), Value(item["IDProcess"]), Number(item[valueKey]) is double number ? $"{number:0.#}{unit}" : "Unavailable");
    }

    private static void TableRow(Panel panel, params string[] cells)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 4) };
        for (int index = 0; index < cells.Length; index++)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(index == 0 ? 2 : 1, GridUnitType.Star) });
            var text = Text(cells[index], index == 0 ? "Text" : "Muted");
            text.Margin = new Thickness(0, 0, 6, 0);
            Grid.SetColumn(text, index);
            row.Children.Add(text);
        }
        panel.Children.Add(row);
    }

    private static void MeasurementRows(Panel panel, JsonNode? before, JsonNode? after, bool benchmark = false)
    {
        JsonNode? initial = benchmark ? before?["Metrics"] : before;
        JsonNode? final = benchmark ? after?["Metrics"] : after;
        if (initial is null || final is null) { Note(panel, "Capture both snapshots to see measured differences."); return; }
        TableRow(panel, "Metric", "Before", "After", "Change");
        Compare("CPU use", initial["CpuPercent"], final["CpuPercent"], "%", " pp");
        Compare("Available RAM", Scale(initial["AvailableBytes"], 1048576), Scale(final["AvailableBytes"], 1048576), " MiB", " MiB");
        Compare("GPU engine use", initial["GpuBusiestEnginePercent"], final["GpuBusiestEnginePercent"], "%", " pp");
        if (!benchmark) return;
        bool samePing = StringValue(before?["Ping"]?["Address"]) == StringValue(after?["Ping"]?["Address"]);
        if (samePing)
        {
            Compare("Latency", before?["Ping"]?["AverageMs"], after?["Ping"]?["AverageMs"], " ms", " ms");
            Compare("Packet loss", before?["Ping"]?["LossPercent"], after?["Ping"]?["LossPercent"], "%", " pp");
        }
        else Note(panel, "The hostname resolved to a different IP address. Inspect the individual probe results.");
        Compare("DNS query", before?["DNS"]?["Milliseconds"], after?["DNS"]?["Milliseconds"], " ms", " ms");

        static JsonNode? Scale(JsonNode? value, double divisor) => Number(value) is double number ? JsonValue.Create(number / divisor) : null;
        void Compare(string label, JsonNode? first, JsonNode? second, string unit, string deltaUnit)
        {
            if (Number(first) is not double oldValue || Number(second) is not double newValue) return;
            TableRow(panel, label, $"{oldValue:0.##}{unit}", $"{newValue:0.##}{unit}", $"{newValue - oldValue:+0.##;-0.##;0}{deltaUnit}");
        }
    }
}
