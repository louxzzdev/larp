using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;

namespace LarpOptimizer;

internal static class EngineClient
{
    private static readonly string Engine = ReadResource("Engine.ps1");
    private static readonly string Terminal = ReadResource("Terminal.ps1");

    private static string ReadResource(string name)
    {
        using var reader = new StreamReader(Assembly.GetExecutingAssembly().GetManifestResourceStream(name)!);
        return reader.ReadToEnd();
    }

    internal static async Task<JsonArray> InvokeAsync(JsonObject request, Action<string> progress, CancellationToken token)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (string value in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
            "[Console]::InputEncoding=[Text.Encoding]::UTF8; & ([scriptblock]::Create([Console]::In.ReadToEnd()))" })
            start.ArgumentList.Add(value);

        string data = Convert.ToBase64String(Encoding.UTF8.GetBytes(request.ToJsonString()));
        string entry = """
            $script:terminal=$false
            try {
                $request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REQUEST__')) | ConvertFrom-Json
                $items=@(Run-Request $request)
                [Console]::WriteLine((ConvertTo-Json -InputObject @{ok=$true;data=$items} -Depth 16 -Compress))
            } catch {
                [Console]::WriteLine((ConvertTo-Json -InputObject @{ok=$false;error=$_.Exception.Message} -Compress))
            }
            """.Replace("__REQUEST__", data, StringComparison.Ordinal);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start Windows PowerShell.");
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = ReadErrorsAsync(process.StandardError, progress);
        using var stop = token.Register(() =>
        {
            try { process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        });
        try
        {
            await process.StandardInput.WriteAsync(Engine + "\n" + Terminal + "\n" + entry).ConfigureAwait(false);
            process.StandardInput.Close();
            await process.WaitForExitAsync().ConfigureAwait(false);
        }
        catch (IOException) when (token.IsCancellationRequested)
        {
            throw new OperationCanceledException(token);
        }
        string text = await output.ConfigureAwait(false);
        string stderr = await errors.ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        string? envelope = text.Split('\n').LastOrDefault(line => line.TrimStart().StartsWith("{", StringComparison.Ordinal));
        if (envelope is null)
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(stderr) ? "The Windows engine returned no result." : stderr.Trim());
        var result = JsonNode.Parse(envelope)!;
        if (!(result["ok"]?.GetValue<bool>() ?? false))
            throw new InvalidOperationException(result["error"]?.GetValue<string>() ?? "The Windows operation failed.");
        return result["data"]!.AsArray();
    }

    private static async Task<string> ReadErrorsAsync(StreamReader reader, Action<string> progress)
    {
        var lines = new StringBuilder();
        while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            lines.AppendLine(line);
            progress(line);
        }
        return lines.ToString();
    }
}
