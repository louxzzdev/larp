function Terminal-Result($Items) {
    foreach ($item in @($Items | Where-Object { $null -ne $_ })) {
        if ($item -is [string]) { Write-Host $item }
        else { Write-Host (ConvertTo-Json -InputObject $item -Depth 12) }
    }
}
function Open-Settings([string]$Page) { Start-Process "ms-settings:$Page" }
function Terminal-Apply($request,[bool]$Dns,[bool]$Ethernet = $false) {
    $request.action = if ($Ethernet) { 'eeePlan' } elseif ($Dns) { 'dnsPlan' } else { 'plan' }
    $review = @(Run-Request $request)
    if (!$review.Count) { Write-Host 'No applicable changes for this selection.'; Terminal-Result (Metrics); return }
    Terminal-Result $review
    if ($review.Count -gt 1) {
        $selection = Read-Host 'Enter module IDs separated by commas, or press Enter for all'
        if ($selection) {
            $ids = @($selection -split '\s*,\s*' | ForEach-Object { $_.Trim() })
            $review = @($review | Where-Object { $_.Id -cin $ids })
            if ($ids.Count -ne $review.Count) { throw 'Use distinct IDs from the reviewed list.' }
            $request.selected = $ids
            Terminal-Result $review
        }
    }
    if (@($review | Where-Object Administrator).Count -and !(Is-Admin)) {
        throw 'Reopen this BAT from an administrator CMD to apply the reviewed adapter change.'
    }
    if ((Read-Host 'Apply the reviewed changes? Type YES') -cne 'YES') { return }
    $request.reviewed = $review
    $answer = Read-Host ('Capture before/after resource measurements? ' + $(if ($request.preset -eq 'Competitive') { '[Y/n]' } else { '[y/N]' }))
    $request.baseline = $answer -eq 'Y' -or (!$answer -and $request.preset -eq 'Competitive')
    $request.action = if ($Ethernet) { 'eeeApply' } elseif ($Dns) { 'dnsApply' } else { 'apply' }
    Terminal-Result (Run-Request $request)
}
function Terminal-Restore($request) {
    Terminal-Result (Get-LarpHistory)
    $request.operation = Read-Host 'Operation GUID (blank for all matching operations)'
    $request.module = Read-Host 'Module ID (blank for all modules)'
    $request.profile = Read-Host 'Exact game profile or Network (blank for all scopes)'
    $request.overrides = @()
    if ((Read-Host 'Restore matching records newest first? Type YES') -cne 'YES') { return }
    $results = @(Run-Request $request)
    Terminal-Result $results
    $conflicts = @($results | Where-Object Status -EQ 'Conflict')
    if ($conflicts.Count -and (Read-Host 'Overwrite the external values listed above? Type YES to confirm') -ceq 'YES') {
        $request.overrides = $conflicts
        Terminal-Result (Run-Request $request)
    }
}
function Terminal-Diagnostics($request) {
    $file = Join-Path $store 'diagnostics.json'
    $output = switch (Read-Host '[1] Capture comparison baseline [2] Capture comparison follow-up [3] Export history [4] Create restore point') {
        1 { $label = 'Baseline' }
        2 { $label = 'FollowUp' }
        3 { Write-JSON (Join-Path $store 'history-export.json') @{ Operations=@(Get-LarpHistory) }; Write-Host "Exported to $store\history-export.json" }
        4 {
            if ((Read-Host 'Ask Windows System Protection to create a restore point? Type YES') -ceq 'YES') {
                $request.action = 'restorePoint'; Run-Request $request
            }
        }
    }
    if ($output) { Terminal-Result $output }
    if (!(Get-Variable label -Scope Local -ErrorAction SilentlyContinue)) { return }
    $previous = $null
    if ($label -eq 'FollowUp') {
        if (!(Test-Path -LiteralPath $file)) { throw 'Capture a baseline first.' }
        $previous = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('host','dnsHost','count','timeout')) { $request[$key] = $previous.Request.$key }
        Write-Host "Repeating the explicit baseline destinations: $($request.host) $($request.dnsHost)"
        if ((Read-Host 'Run these tests again? Type YES') -cne 'YES') { return }
    } else {
        $request.host = Read-Host 'Optional ICMP target (Gateway, Cloudflare, Google, or hostname)'
        $request.dnsHost = Read-Host 'Optional DNS query hostname using the system resolver'
    }
    $request.action = 'benchmark'
    $result = Run-Request $request
    if ($label -eq 'Baseline') { Write-JSON $file @{ Request=$request; Baseline=$result } }
    else {
        $file = Join-Path $store 'comparison.json'
        Write-JSON $file @{ Request=$request; Baseline=$previous.Baseline; FollowUp=$result }
    }
    Terminal-Result $result
    Write-Host "Saved to $file. Compare under similar workload, power, signal and network conditions."
}
function Terminal {
    $script:terminal = $true
    while ($true) {
        Clear-Host
        $adminLabel = if (Is-Admin) { 'Administrator' } else { 'Standard access' }
        Write-Host @"

  LARP OPTIMIZER   /   $env:COMPUTERNAME   /   $adminLabel
  ------------------------------------------------------
  [1] Dashboard         [6] Network
  [2] Optimize Windows  [7] IPv4 DNS
  [3] CPU               [8] Diagnostics
  [4] GPU               [9] Restore Changes
  [5] Memory            [P] Game Profiles
  [S] Windows Settings  [0] Exit

"@
        $selection = ([string](Read-Host 'Select')).Trim()
        if ($selection -in @('0',$null,'')) { break }
        $request = @{count=5;timeout=750;host='';server='';dnsHost='';power='';profile='General Gaming';preset='Performance';baseline=$false}
        try {
            switch ($selection) {
                1 { Terminal-Result (Dashboard) }
                2 {
                    Write-Host 'Performance favors the CPU on AC power. Safe is review-only. Competitive also reviews core parking, CPU boost and PCIe power saving.'
                    $name = Read-Host ('Profile (blank for General Gaming): ' + ($games.Keys -join ', '))
                    if ($name) { $request.profile = $name }
                    $profile = Profile $request.profile
                    $choice = Read-Host ('Preset (blank for ' + $profile.Preset + '): ' + ($presets -join ', '))
                    $request.preset = if ($choice) { $choice } else { $profile.Preset }
                    if ($request.preset -eq 'Custom') {
                        Terminal-Result (Power-Plans)
                        $request.power = Read-Host 'Installed plan GUID (blank keeps current plan)'
                        Terminal-Result (Active-Adapters)
                        $request.adapter = Read-Host 'Adapter GUID (blank keeps current DNS)'
                        if ($request.adapter) {
                            $request.provider = Read-Host 'Default, Cloudflare, Google, Quad9, or Custom'
                            if ($request.provider -eq 'Custom') { $request.servers = Read-Host 'IPv4 addresses, separated by spaces or commas' }
                        }
                    }
                    Terminal-Apply $request $false
                }
                3 {
                    Terminal-Result (Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,CurrentClockSpeed)
                    Write-Host "Active power scheme: $(Power-State)"
                    Terminal-Result (Processes | Sort-Object CpuPercent -Descending | Select-Object -First 12)
                }
                4 {
                    Terminal-Result (GPU)
                    Write-Host '1 Graphics settings   2 Display refresh settings   3 NVIDIA Control Panel (if installed)   4 AMD Software (if installed)   5 Intel Graphics Command Center (if installed)'
                    $page = Read-Host 'Select a shortcut or leave blank'
                    if ($page -eq '1') { Open-Settings 'display-advancedgraphics' }
                    if ($page -eq '2') { Open-Settings 'display-advanced' }
                    if ($page -in @('3','4','5')) { Open-GPU $page }
                }
                5 {
                    Terminal-Result (Metrics)
                    Terminal-Result (Processes | Sort-Object PrivateWorkingSetMiB -Descending | Select-Object -First 12)
                    Terminal-Result (Review-Windows)
                    if ((Read-Host 'Open Windows Startup Apps? [Y/N]') -eq 'Y') { Open-Settings 'startupapps' }
                }
                6 {
                    Write-Host 'ICMP can differ from game traffic. Compare probes the default gateway, 1.1.1.1 and 8.8.8.8, plus your optional host.'
                    $selection = Read-Host '[1] Ping [2] Compare [3] Active routes [4] Route selection [5] Traceroute [6] Adapters [7] Adapter details [8] Flush DNS cache [9] Compare game servers [E] Ethernet latency'
                    switch ($selection) {
                        1 { $request.action='ping'; $request.host=Read-Host 'Gateway, Cloudflare, Google, or custom host' }
                        2 { $request.action='compare'; $request.host=Read-Host 'Optional host' }
                        3 { $request.action='routes' }
                        4 { $request.action='route'; $request.host=Read-Host 'Destination host' }
                        5 { $request.action='trace'; $request.host=Read-Host 'Destination host' }
                        6 { $request.action='adapters' }
                        7 { $request.action='adapter'; Terminal-Result (Active-Adapters); $request.adapter=Read-Host 'Adapter GUID' }
                        8 { if ((Read-Host 'Clear the Windows DNS resolver cache? Type YES') -ceq 'YES') { $request.action='flush' } }
                        9 {
                            $request.action='endpoints'; $request.host=Read-Host 'Game server or region A hostname or IP'
                            $request.alternate=Read-Host 'Game server or region B hostname or IP'
                        }
                        E {
                            Terminal-Result (Active-Adapters)
                            $request.adapter=Read-Host 'Wired adapter GUID'
                            Terminal-Apply $request $false $true
                            $request.Remove('action')
                        }
                    }
                    if ($request.ContainsKey('action')) {
                        if ($request.action -in @('ping','compare','endpoints')) {
                            $count = Read-Host 'Samples (2-15, blank for 5)'
                            $timeout = Read-Host 'Per-probe timeout (100-2000 ms, blank for 750)'
                            if ($count) { $request.count = [int]$count }
                            if ($timeout) { $request.timeout = [int]$timeout }
                        }
                        Terminal-Result (Run-Request $request)
                    }
                }
                7 {
                    Write-Host 'DNS changes affect IPv4 on one adapter. They usually have no effect on established game latency.'
                    $choice = Read-Host '[1] Inspect or change DNS [2] Time a DNS query'
                    if ($choice -eq '1') {
                        Terminal-Result (Active-Adapters)
                        $request.adapter = Read-Host 'Adapter GUID'
                        $request.provider = Read-Host 'Default, Cloudflare, Google, Quad9, or Custom'
                        if ($request.provider -eq 'Custom') { $request.servers = Read-Host 'IPv4 addresses, separated by spaces or commas' }
                        Terminal-Apply $request $true
                    }
                    if ($choice -eq '2') {
                        $request.action='dnsTest'; $request.host=Read-Host 'DNS hostname'
                        $request.server=Read-Host 'Resolver IPv4 (blank for system resolver)'
                        Terminal-Result (Run-Request $request)
                    }
                }
                8 { Terminal-Diagnostics $request }
                9 { $request.action='restore'; Terminal-Restore $request }
                P {
                    $request.profile = Read-Host ($games.Keys -join ', ')
                    $request.action = 'profile'
                    Terminal-Result (Run-Request $request)
                    if ((Read-Host 'Replace profile settings? [Y/N]') -eq 'Y') {
                        $request.action='saveProfile'
                        $request.preset=Read-Host ($presets -join ', ')
                        $request.executable=Read-Host 'Optional full executable path'
                        $request.host=Read-Host 'Optional game server hostname'
                        Terminal-Result (Run-Request $request)
                    }
                }
                S {
                    Terminal-Result (Review-Windows)
                    $settings = Read-Host '[1] Game Mode [2] Startup Apps [3] Power [4] Installed Apps [5] Storage [6] Task Manager [7] Resource Monitor'
                    switch ($settings) {
                        1 { Open-Settings 'gaming-gamemode' }
                        2 { Open-Settings 'startupapps' }
                        3 { Open-Settings 'powersleep' }
                        4 { Open-Settings 'appsfeatures' }
                        5 { Open-Settings 'storagesense' }
                        6 { Start-Process -FilePath (Join-Path $system 'Taskmgr.exe') }
                        7 { Start-Process -FilePath (Join-Path $system 'resmon.exe') }
                    }
                }
                default { Write-Host 'Choose an option shown in the menu.' }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        [void](Read-Host 'Press Enter to return')
    }
}
function Open-GPU([string]$Choice) {
    $app = switch ($Choice) {
        3 { 'NVIDIACorp.NVIDIAControlPanel_' }
        4 { 'AdvancedMicroDevicesInc-2.AMDRadeonSoftware_' }
        5 { 'AppUp.IntelGraphicsExperience_' }
        default { throw 'Unknown GPU control panel.' }
    }
    $entry = Optional { Get-StartApps | Where-Object { $_.AppID.StartsWith($app,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
    if ($entry) { Start-Process (Join-Path $env:WINDIR 'explorer.exe') "shell:AppsFolder\$($entry.AppID)"; return }
    $relative = switch ($Choice) {
        3 { 'NVIDIA Corporation\Control Panel Client\nvcplui.exe' }
        4 { 'AMD\CNext\CNext\RadeonSoftware.exe' }
    }
    if ($relative) {
        $path = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { Start-Process -FilePath $path; return }
    }
    throw 'The selected vendor control panel was not found on this PC.'
}

