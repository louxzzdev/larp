# Operations and release verification

## Shared engine

The WPF host embeds the same readable PowerShell source that the build appends to the BAT launcher. The EXE sends structured requests through standard input and reads structured results. The BAT gathers inputs interactively and calls the same request handler. The engine uses bounded ICMP sample counts, strict hostname and IPv4 validation, full paths for Windows native executables, and structured command arguments.

| ID | Target and effect | Verification and restoration |
| --- | --- | --- |
| `cpu.epp.ac` | Lowers the CPU energy performance preference while plugged in, when Windows exposes autonomous performance mode. Lower values bias compatible processors toward performance and can raise power use and temperatures. Windows permissions and policy apply. | Backs up the exact AC index by power plan ID, writes with `powercfg /setacvalueindex`, reloads the active plan and verifies the stored index. Restore writes and verifies the original index. Hardware response and FPS vary by workload. |
| `cpu.parking.ac` | Competitive can raise the minimum unparked CPU cores on AC to 100% if the plan allows all cores to unpark. This can eliminate core unpark delays for the targeted efficiency class at the cost of higher power and potentially higher temperatures. | Writes and reads back the AC `CPMINCORES` index for the reviewed plan. Restore reinstates the original index. |
| `cpu.boost.ac` | Competitive can enable a disabled boost policy on AC when the plan's maximum processor state is 100%. Temperature and power limits still determine realized clocks. | Writes and reads back the AC `PERFBOOSTMODE` index. Restore reinstates the original index. |
| `power.pcie.ac` | Competitive can turn off Windows PCIe link power saving on AC when the plan uses a power-saving index. Hardware and firmware determine actual link behavior. Idle consumption can rise. | Writes and reads back the AC `ASPM` index for the reviewed plan. Restore reinstates the original index. |
| `network.ethernet.eee` | Disables Energy Efficient Ethernet on a physical wired adapter when the driver exposes the standardized `*EEE` setting with valid on/off values. Requires administrator. Applying or restoring may restart the link briefly. | Records the original value by adapter GUID and reads back the exact driver property. Measure the same endpoint before and after to evaluate any latency or jitter difference. |
| `power.plan` | Switches to an installed Windows power plan. High performance may reduce some power-state transition delays and can increase heat and power consumption. Low to moderate risk. Windows permissions and policy apply. | Reads the current scheme GUID before and after `powercfg /setactive`. Restore selects the original GUID if the plan remains installed. |
| `network.dns.ipv4` | Sets automatic DNS or an ordered static list on one connected network adapter. Moderate risk. Requires Administrator. Custom accepts canonical IPv4 unicast addresses. | Backs up mode and static order by adapter GUID. Writes using Windows netsh and compares the effective static IPv4 address list and stored state. Restoring Default re-enables automatic IPv4 configuration, which can provide different addresses later as the network changes. |

Both modules target Windows 10 and 11. IPv4 DNS can affect lookup reliability and latency. Established traffic generally keeps its existing path and endpoint. The Windows DNS Client can also use an IPv6 resolver, VPN policies, per-namespace DNS, application-resolved DNS, or cached answers. IPv6 DNS is outside the scope of this change. Review enterprise, VPN and split-DNS requirements before selecting a public resolver.

The before/after configuration journal is `%LOCALAPPDATA%\LARP Optimizer\history.json`. It records original and intended values before writes, statuses, timestamps, verification and failures. Writes by LARP instances are serialized. Restore walks newer records first and checks the live setting against the original and intended states. Confirmed external values are checked again before an override. If a multi-address DNS operation is interrupted, its prepared record survives and the Restore view may request confirmation for the partially written list. Preserve the journal until changes you care about have been restored.

Profiles and BAT diagnostic comparisons are also stored under that directory. The GUI holds diagnostics comparisons in memory until exported. Reports may contain local addresses, interface names and application paths. They stay local unless you share them.

The desktop app stores interface preferences in `interface.json`. Dashboard trends retain up to 60 measured samples in the current application session. The first reading uses Windows timing and memory counters, followed by the richer engine snapshot for clock and GPU data. Recommendations inspect supported Windows settings locally. Periodic activity is limited to the foreground dashboard refresh.

## Measurement limits

- ICMP measures successful echo replies and failed probes. Routers and servers may filter or deprioritize ICMP. Jitter is the mean absolute round-trip change between successive successful replies in the sample. Ping, jitter and loss can differ from in-game traffic. Multi-target comparisons indicate patterns to investigate.
- Server comparison uses two user-selected destinations. Median and P95 use nearest-rank estimates from successful replies. The lowest median is highlighted only for distinct resolved IPs with zero loss in both samples and different medians. Measurements use the Windows-selected route and can help choose an available game region. LARP includes no relay infrastructure.
- DNS timing is Windows query elapsed time. Caching, the resolver, DNS policy, and the chosen record influence the result. Selecting an explicit resolver contacts that address to look up the entered hostname.
- GPU utilization is the busiest reported engine across adapters. Driver-reported dedicated VRAM and refresh are shown when available. Some drivers and remote or hybrid display setups omit or report incomplete data. Windows Display settings shows refresh by display.
- The CPU clock is the Windows-reported snapshot, which can differ from effective clock under load. Reliable generic thermal and power throttling information is unavailable through this implementation. Memory pressure is presented as available physical memory and utilization. Startup and reboot indicators depend on what Windows exposes.
- Game Mode is a read-only inspection of the exposed user preference when present. Configure it through Windows. Graphics and adapter pages are inspection and shortcuts, apart from the explicitly reviewed IPv4 DNS operation. Vendor control panel shortcuts require the panel to be installed and discoverable. FPS capture, HAGS detection, per-game graphics preferences and routing writes are outside this release.
- High performance may be unavailable on Modern Standby or vendor-managed systems. LARP lists and uses plans already installed. CPU preference changes target the AC index for processor efficiency class 0. The hardware must support the preference for it to take effect.
- System Protection must be enabled for restore-point creation, which Windows can also limit by interval. The operation journal handles per-setting restoration independently.

## Release verification

1. Run all three test scripts and rebuild. Compare the hashes from `Get-FileHash -Algorithm SHA256 -LiteralPath '<file>'` with SHA256SUMS.txt.
2. In clean Windows 10 and 11 x64 VMs, copy only the EXE and BAT. Start each with standard access. Verify device data, power plans, routes, a loopback ping, export and exit. Use the EXE without a separately installed .NET desktop runtime.
3. In a VM with an alternate plan installed, record `powercfg /getactivescheme`, review and apply a different installed plan, verify its GUID, restore it from the other interface and check the original GUID again. Repeat with an external power-plan change and verify that the conflict confirmation is required whenever the current value differs from both recorded values.
4. On a test adapter, record automatic/static DNS, current IPv4 and IPv6 lists, and dynamic registration. From elevated LARP apply a two-address IPv4 list. Verify order through `Get-DnsClientServerAddress`, leave IPv6 and registration intact, then restore using the other interface. Repeat starting from a static list and using Default. Test only on a disposable VM or a separately controlled adapter where connectivity can be recovered.
5. With System Protection enabled in the VM, create a restore point and verify its description and sequence number in Windows. Review security policy and code-signing requirements before publishing to the community.

## Windows references

- [Powercfg command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)
- [Windows CPU energy performance preference](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfenergypreference)
- [Windows minimum unparked CPU cores](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-core-parking-cpmincores)
- [Windows processor boost policy](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfboostmode)
- [Windows PCIe link power indices](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/power-management-for-storage-hardware-devices-nvme#pcie-aspm-and-l1-sub-states)
- [Windows standardized Ethernet power keyword](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/standardized-inf-keywords-for-power-management)
- [Power policy and administrator overrides](https://learn.microsoft.com/en-us/windows/win32/power/administrator-overrides)
- [Netsh interface commands](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-interface)
- [.NET single-file publishing](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/)

