using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace LarpOptimizer;

internal static class QuickMetrics
{
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        internal uint Length, Load;
        internal ulong Total, Available, TotalPage, AvailablePage, TotalVirtual, AvailableVirtual, ExtendedVirtual;
    }

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

    [DllImport("kernel32.dll")]
    private static extern ushort GetActiveProcessorGroupCount();

    internal static async Task<JsonObject> ReadAsync(CancellationToken token)
    {
        var output = new JsonObject();
        if (GetActiveProcessorGroupCount() == 1 && GetSystemTimes(out long idle, out long kernel, out long user))
        {
            await Task.Delay(180, token);
            if (GetSystemTimes(out long nextIdle, out long nextKernel, out long nextUser))
            {
                long total = nextKernel - kernel + nextUser - user;
                if (total > 0) output["CpuPercent"] = Math.Round(Math.Clamp(100d * (total - (nextIdle - idle)) / total, 0, 100), 1);
            }
        }
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        if (GlobalMemoryStatusEx(ref memory) && memory.Total > 0 && memory.Total >= memory.Available)
        {
            output["AvailableBytes"] = memory.Available;
            output["UsedBytes"] = memory.Total - memory.Available;
            output["MemoryPercent"] = Math.Round(100d * (memory.Total - memory.Available) / memory.Total, 1);
        }
        output["At"] = DateTime.UtcNow.ToString("O");
        return output;
    }
}
