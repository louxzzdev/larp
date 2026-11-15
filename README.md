<p align="center">
  <img src="assets/larp-logo.svg" width="112" height="112" alt="LARP Optimizer logo">
</p>

<h1 align="center">LARP Optimizer</h1>

<p align="center">
  <strong>Windows gaming diagnostics and reversible system tuning</strong><br>
  Monitor your system, compare server latency, and review settings before applying them.
</p>

<p align="center">
  <a href="#about">About</a> ·
  <a href="#editions">Editions</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#features">Features</a> ·
  <a href="#build-and-test">Build and test</a>
</p>

<p align="center">
  <code>Windows 10 / 11 x64</code> · <code>Portable EXE and standalone BAT</code> · <a href="LICENSE">MIT License</a>
</p>

## About

LARP is a community focused on making scripts and tools that help others. LARP Optimizer is one of those tools, built to help Windows gamers monitor their systems and tune settings they can restore later.

[Join the LARP community on Discord](https://discord.gg/wCB5U6RxDf)

## Editions

| Package | Experience |
| --- | --- |
| **LARP Optimizer.exe** | Portable desktop app with a dashboard and light and dark themes |
| **LARP Optimizer.bat** | Standalone command-line edition for CMD |

Follow the [build instructions](#build-and-test) to generate both packages and their SHA-256 checksums.

> Both editions use Windows PowerShell 5.1. The unsigned EXE includes its .NET runtime. Standard access covers monitoring and most power-plan operations. Adapter changes, DNS cache flushing and restore-point creation require administrator access.

## Features

### Tune Windows settings

- **Hardware-aware recommendations** show applicable Windows power-plan and processor settings.
- **Individual controls** let you choose which changes to apply from a reviewed preset. The engine checks the current values again before writing.
- **Plugged-in tuning** supports CPU energy preference, core parking, boost policy and PCIe link power saving when the selected plan exposes them.
- **Game profiles** save local preferences for Valorant, Counter-Strike 2, Fortnite, Minecraft, Roblox, Call of Duty and general gaming.

### Measure system and network performance

- Follow measured CPU, RAM and GPU usage, workload trends and top processes.
- Compare two game servers by median latency, P95 and packet loss. Inspect routes and run traceroute.
- Review IPv4 DNS and Energy Efficient Ethernet on compatible wired adapters.
- Capture before-and-after diagnostics and export JSON or text reports.

### Open Windows tools and restore settings

- Open Task Manager, Resource Monitor, Startup Apps, Installed Apps, Storage, Game Mode, graphics preferences and display refresh settings from **Tools**.
- Review the local journal in **Restore**. Restore selected operations or modules using their recorded original values.
- Create an optional Windows restore point when System Protection is available.

## Quick start

1. Open the EXE or run the BAT from CMD.
2. Use **Dashboard** to check current readings, then open **Optimize** and select a preset.
3. Select the changes you want in **Review changes** and check the before-and-after values. In the BAT, enter the module IDs when shown a multi-change plan.
4. Apply the selection. Review the verified outcome in **Restore** and measure the same workload in **Diagnostics** if you want to compare results.

| Preset | Behavior |
| --- | --- |
| **Safe** | Read-only review |
| **Balanced** | Moderate CPU performance preference where supported |
| **Performance** | Performance-oriented CPU energy preference and a supported installed-plan fallback |
| **Competitive** | Additional plugged-in CPU and PCIe settings with heat and power trade-offs |
| **Custom** | Choose an installed Windows power plan and optional IPv4 DNS |

| Shortcut | Desktop action |
| --- | --- |
| `Ctrl+K` | Search pages and actions |
| `Ctrl+B` | Toggle the sidebar |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | Open Dashboard, Optimize, or Restore |

## Troubleshooting

| What you see | What to check |
| --- | --- |
| No applicable changes | The selected values may already match or the hardware or driver may expose different settings. |
| A change is unavailable | Review its permissions and dependencies. Use the same Windows account when opening an elevated session. |
| Performance worsens or temperatures rise | Restore the affected setting and compare the same workload again. |
| Gateway and game-server tests disagree | Compare loss and latency across destinations. ICMP samples can differ from gameplay traffic. |

The app stores preferences and the rollback journal under `%LOCALAPPDATA%\LARP Optimizer`. Network tests contact the targets you select. FPS and ping depend on your workload, hardware and connection.

## Build and test

Use the .NET 8 SDK on Windows. The build produces a self-contained WPF EXE, a standalone BAT and SHA-256 checksums.

```powershell
powershell.exe -NoProfile -File .\scripts\Build.ps1 -ReleaseDirectory release/1.5.0
powershell.exe -NoProfile -File .\tests\Engine.Tests.ps1 -Integration
powershell.exe -NoProfile -File .\tests\BatchSmoke.ps1 -Batch "release/1.5.0/LARP Optimizer.bat" -NetworkTuning
```

Use `-Dotnet` if the SDK executable is outside PATH. Use `-PowerWrite` on the engine test to verify write and restore operations on an inactive temporary power plan. The optional `GuiSmoke.ps1` test opens a desktop window. See the [operations guide](docs/Operations.md) for module details and verification steps.

## Release notes

**1.5.0** adds individual selection during review and a Windows Tools page. The BAT adds optional per-module selection and quick access to Windows utilities.

## License

[MIT](LICENSE)

Interface and documentation references · [RyTuneX](https://github.com/rayenghanmi/RyTuneX) · [Exoptimizer](https://github.com/MobinMardi/Exoptimizer)


