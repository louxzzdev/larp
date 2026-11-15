@echo off
setlocal DisableDelayedExpansion
set "LARP_BATCH_FILE=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$lines=[IO.File]::ReadAllLines($env:LARP_BATCH_FILE,[Text.Encoding]::UTF8); $marker=[Array]::IndexOf($lines,'# LARP_POWERSHELL_PAYLOAD'); if ($marker -lt 0) { exit 2 }; & ([scriptblock]::Create(($lines[($marker+1)..($lines.Length-1)] -join [Environment]::NewLine)))"
exit /b %errorlevel%
# LARP_POWERSHELL_PAYLOAD
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$system = [Environment]::SystemDirectory
$store = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LARP Optimizer'
$journal = Join-Path $store 'history.json'
$highPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$idPattern = '[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}'
$presets = @('Performance','Safe','Balanced','Competitive','Custom')
$providers = [ordered]@{ Default=@(); Cloudflare=@('1.1.1.1','1.0.0.1'); Google=@('8.8.8.8','8.8.4.4'); Quad9=@('9.9.9.9','149.112.112.112') }
$games = [ordered]@{
    Valorant='VALORANT-Win64-Shipping'; 'Counter-Strike 2'='cs2'; Fortnite='FortniteClient-Win64-Shipping'
    Minecraft='Minecraft.Windows,javaw'; Roblox='RobloxPlayerBeta'; 'Call of Duty'='cod,ModernWarfare'
    'General Gaming'=''
}
$profileTips = @{
    Valorant='Review refresh rate and compare route and jitter to your selected region or game server.'
    'Counter-Strike 2'='Compare loss and jitter on the connection you use for matches and look for background CPU contention.'
    Fortnite='Review the reported graphics driver and compare memory and GPU load during a representative match.'
    Minecraft='Check the executable path because javaw can belong to another Java application. Compare memory under the same world and mod setup.'
    Roblox='Check the Roblox player candidate and test the connection under the same experience and region.'
    'Call of Duty'='Confirm the executable for your edition and compare memory and GPU load during similar matches.'
    'General Gaming'='Start with Safe and compare under similar workloads before testing an installed performance power plan.'
}

function Is-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}
function Native([string]$Name, [string[]]$Arguments) {
    $output = & (Join-Path $system $Name) @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name exited with code ${LASTEXITCODE}. $output" }
    $output
}
function Optional([scriptblock]$Action) {
    try { & $Action } catch { Write-Verbose $_.Exception.Message }
}
function Progress-Line([string]$Message) {
    if ($script:terminal) { Write-Host $Message }
    else { [Console]::Error.WriteLine($Message) }
}
function Guid-Text([string]$Value) { ([guid]::Parse($Value)).ToString() }
function Power-State {
    $match = [regex]::Match((Native 'powercfg.exe' @('/getactivescheme') | Out-String), $idPattern, 'IgnoreCase')
    if (!$match.Success) { throw 'Windows did not return an active power scheme GUID.' }
    Guid-Text $match.Value
}
function Power-Plans {
    foreach ($line in (Native 'powercfg.exe' @('/list'))) {
        $match = [regex]::Match($line, "($idPattern)\s+\((.*)\)", 'IgnoreCase')
        if ($match.Success) {
            [pscustomobject]@{ Id=(Guid-Text $match.Groups[1].Value); Name=$match.Groups[2].Value }
        }
    }
}
function Read-ACIndex([string]$PlanId,[string]$Setting,[int]$Maximum,[string]$Subgroup = 'SUB_PROCESSOR') {
    $guid = Guid-Text $PlanId
    $output = Native 'powercfg.exe' @('/qh',$guid,$Subgroup,$Setting)
    $indices = @($output | ForEach-Object {
        if ($_ -match '^\s+[^:]+:\s*0x([0-9a-f]{8})\s*$') { [Convert]::ToInt32($Matches[1],16) }
    })
    # Powercfg ends each individual setting with its AC and DC indices.
    if ($indices.Count -lt 2 -or $indices[-2] -gt $Maximum -or $indices[-2] -lt 0) {
        throw "Windows did not return a valid AC index for $Setting."
    }
    [string]$indices[-2]
}
function Read-Epp([string]$PlanId) { Read-ACIndex $PlanId 'PERFEPP' 100 }
function Set-Epp([string]$PlanId,[string]$Value) {
    Set-CpuACIndex $PlanId 'PERFEPP' $Value
}
function Set-CpuACIndex([string]$PlanId,[string]$Setting,[string]$Value) {
    Set-PlanACIndex $PlanId $Setting $Value
}
function Set-PlanACIndex([string]$PlanId,[string]$Setting,[string]$Value) {
    $guid = Guid-Text $PlanId
    $maximum = switch -Exact ($Setting) {
        PERFEPP { 100 }
        CPMINCORES { 100 }
        PERFBOOSTMODE { 6 }
        ASPM { 2 }
        default { throw 'Unsupported power setting.' }
    }
    if ($Value -notmatch '^(?:0|[1-9][0-9]?|100)$' -or [int]$Value -gt $maximum) { throw 'Invalid power setting value.' }
    $subgroup = if ($Setting -eq 'ASPM') { 'SUB_PCIEXPRESS' } else { 'SUB_PROCESSOR' }
    $null = Native 'powercfg.exe' @('/setacvalueindex',$guid,$subgroup,$Setting,$Value)
    if ((Power-State) -eq $guid) { $null = Native 'powercfg.exe' @('/setactive',$guid) }
}
function IPv4([string]$Value) {
    $parsed = $null
    if ($Value -notmatch '^(\d{1,3}\.){3}\d{1,3}$' -or
        ![Net.IPAddress]::TryParse($Value,[ref]$parsed) -or $parsed.ToString() -ne $Value -or
        $parsed.GetAddressBytes()[0] -eq 0 -or $parsed.GetAddressBytes()[0] -ge 224) {
        throw "Invalid IPv4 DNS server: $Value"
    }
    $parsed.ToString()
}
function DNS-Addresses([string[]]$Values) {
    if ($Values.Count -gt 16) { throw 'Use at most 16 DNS server addresses.' }
    $validated = @($Values | ForEach-Object { IPv4 $_ })
    if (@($validated | Select-Object -Unique).Count -ne $validated.Count) { throw 'DNS addresses must be unique.' }
    $validated
}
function Adapter([string]$Id) {
    $guid = Guid-Text $Id
    $found = @(NetAdapter -IncludeHidden | Where-Object { $_.InterfaceGuid -and (Guid-Text $_.InterfaceGuid) -eq $guid })
    if ($found.Count -ne 1) { throw 'The original network interface is unavailable.' }
    $found[0]
}
function NetAdapter { Get-NetAdapter -IncludeHidden }
function DNS-State([string]$Id) {
    $null = Adapter $Id
    $key = Get-Item -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{$Id}"
    DNS-ConfigValue ([string]$key.GetValue('NameServer',''))
}
function DNS-ConfigValue([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'Default' }
    $servers = @(DNS-Addresses @($raw.Trim() -split '[\s,]+'))
    $servers -join ','
}
function Assert-DNSPolicy {
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name NameServer -ErrorAction SilentlyContinue
    if ($policy -and $policy.NameServer) { throw 'Windows policy manages DNS servers on this computer.' }
}
function Set-DNS([string]$Id, [string]$State) {
    Assert-DNSPolicy
    $adapter = Adapter $Id
    $index = [int]$adapter.ifIndex
    $client = Get-DnsClient -InterfaceIndex $index
    $register = if (!$client.RegisterThisConnectionsAddress) { 'none' }
                elseif ($client.UseSuffixWhenRegistering) { 'both' } else { 'primary' }
    $base = @('interface','ipv4','set','dnsservers',"name=$index","register=$register")
    if ($State -eq 'Default') {
        $null = Native 'netsh.exe' ($base + 'source=dhcp')
        return
    }
    $servers = @(DNS-Addresses ($State -split ','))
    $null = Native 'netsh.exe' ($base + @('source=static',"address=$($servers[0])",'validate=no'))
    for ($i = 1; $i -lt $servers.Count; $i++) {
        $null = Native 'netsh.exe' @('interface','ipv4','add','dnsservers',"name=$index","address=$($servers[$i])","index=$($i+1)",'validate=no')
    }
    $effective = @(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 | ForEach-Object ServerAddresses)
    if (($effective -join ',') -ne $State) { throw 'The effective IPv4 DNS list differs from the reviewed configuration.' }
}
function Ethernet-EEE([string]$Id) {
    $adapter = Adapter $Id
    if (!$adapter.HardwareInterface -or [int]$adapter.NdisPhysicalMedium -ne 14) { throw 'Select a physical Ethernet adapter.' }
    $name = [System.Management.Automation.WildcardPattern]::Escape([string]$adapter.Name)
    $properties = @(Get-NetAdapterAdvancedProperty -Name $name -AllProperties |
        Where-Object RegistryKeyword -CEQ '*EEE')
    if ($properties.Count -ne 1) { throw 'This driver does not expose the standardized Energy Efficient Ethernet setting.' }
    $property = $properties[0]
    $value = @($property.RegistryValue)
    $allowed = @($property.ValidRegistryValues)
    if ($value.Count -ne 1 -or $value[0] -notin @('0','1') -or '0' -notin $allowed -or '1' -notin $allowed) {
        throw 'The Ethernet driver did not expose verified on/off values.'
    }
    $property
}
function EEE-Plan($Request) {
    $target = Guid-Text $Request.adapter
    $adapter = Adapter $target
    if ($adapter.Status -ne 'Up') { throw 'Select a connected Ethernet adapter.' }
    New-Change 'network.ethernet.eee' $target '0' $adapter.Name
}
$modules = [ordered]@{
    'cpu.epp.ac' = @{
        Name='CPU performance preference (plugged in)'; Description='Adjusts the processor energy performance preference of the named power plan.'
        Benefit='On compatible hardware, a lower value biases the CPU toward performance and can raise power use and temperatures.'
        Windows='Windows 10 and 11'; Risk='Low to moderate'; Admin=$false
        Read={ param($Target) Read-Epp $Target }
        Write={ param($Target,$Value) Set-Epp $Target $Value }
    }
    'cpu.parking.ac' = @{
        Name='Minimum unparked CPU cores (plugged in)'; Description='Keeps the configured share of logical processors unparked on AC power.'
        Benefit='Can avoid core unpark delays. Higher heat and power draw can offset the benefit.'
        Windows='Windows 10 and 11'; Risk='Moderate'; Admin=$false
        Read={ param($Target) Read-ACIndex $Target 'CPMINCORES' 100 }
        Write={ param($Target,$Value) Set-CpuACIndex $Target 'CPMINCORES' $Value }
    }
    'cpu.boost.ac' = @{
        Name='CPU boost policy (plugged in)'; Description='Enables the Windows boost policy if the reviewed power plan disables it.'
        Benefit='Allows supported processors to boost within their existing hardware limits. Higher power use and temperatures are possible.'
        Windows='Windows 10 and 11'; Risk='Moderate'; Admin=$false
        Read={ param($Target) Read-ACIndex $Target 'PERFBOOSTMODE' 6 }
        Write={ param($Target,$Value) Set-PlanACIndex $Target 'PERFBOOSTMODE' $Value }
    }
    'power.pcie.ac' = @{
        Name='PCIe link power saving (plugged in)'; Description='Selects Off (0) for Windows PCI Express link power saving.'
        Benefit='May avoid link wake delays on supported devices. Can increase idle power and heat; effective behavior depends on firmware and hardware.'
        Windows='Windows 10 and 11'; Risk='Moderate'; Admin=$false
        Read={ param($Target) Read-ACIndex $Target 'ASPM' 2 'SUB_PCIEXPRESS' }
        Write={ param($Target,$Value) Set-PlanACIndex $Target 'ASPM' $Value }
    }
    'power.plan' = @{
        Name='Windows power plan'; Description='Selects an installed Windows power plan.'
        Benefit='May reduce power-state transition latency under load. Higher power use and heat are possible.'
        Windows='Windows 10 and 11'; Risk='Low to moderate'; Admin=$false
        Read={ param($Target) Power-State }
        Write={ param($Target,$Value)
            $guid = Guid-Text $Value
            if ($guid -notin @(Power-Plans | ForEach-Object Id)) { throw 'That power scheme is no longer installed.' }
            $null = Native 'powercfg.exe' @('/setactive',$guid)
        }
    }
    'network.dns.ipv4' = @{
        Name='Adapter IPv4 DNS'; Description='Changes the selected adapter IPv4 DNS source or server list.'
        Benefit='May change lookup latency or reliability. Established game connections usually see no ping benefit.'
        Windows='Windows 10 and 11'; Risk='Moderate'; Admin=$true
        Read={ param($Target) DNS-State $Target }
        Write={ param($Target,$Value) Set-DNS $Target $Value }
    }
    'network.ethernet.eee' = @{
        Name='Energy Efficient Ethernet'; Description='Turns off Low Power Idle on a supported wired link. 1 = enabled, 0 = disabled.'
        Benefit='May reduce local link wake delays on affected wired connections. Applying or restoring can briefly interrupt the connection.'
        Windows='Windows 10 and 11'; Risk='Moderate'; Admin=$true
        Read={ param($Target) [string](Ethernet-EEE $Target).RegistryValue[0] }
        Write={ param($Target,$Value)
            if ($Value -notin @('0','1')) { throw 'Invalid Ethernet power setting.' }
            $property = Ethernet-EEE $Target
            $null = Set-NetAdapterAdvancedProperty -InputObject $property -RegistryValue @($Value) -Confirm:$false
        }
    }
}
function Module([string]$Id) {
    if (!$modules.Contains($Id)) { throw 'Unknown optimization module.' }
    $modules[$Id]
}
function State([string]$Id,[string]$Target) {
    $module = Module $Id
    & $module.Read $Target
}
function New-Change([string]$Id,[string]$Target,[string]$After,[string]$Label) {
    $module = Module $Id
    $before = State $Id $Target
    if ($before -eq $After) { return }
    [pscustomobject]@{
        Id=$Id; Name=$module.Name; Target=$Target; Before=$before; After=$After; Scope=$Label
        Description=$module.Description; Benefit=$module.Benefit; Risk=$module.Risk
        Administrator=$module.Admin; Windows=$module.Windows
    }
}
function Profile([string]$Name) {
    if (!$games.Contains($Name)) { throw 'Unknown game profile.' }
    $file = Join-Path $store ('profile-' + [array]::IndexOf(@($games.Keys),$Name) + '.json')
    if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }
    [pscustomobject]@{ Name=$Name; Preset='Performance'; Executable=''; Host='' }
}
function Plan($Request) {
    $preset = [string]$Request.preset
    if ($preset -notin $presets) { throw 'Unknown preset.' }
    $null = Profile ([string]$Request.profile)
    if ($preset -eq 'Safe') { return }
    $plans = @(Power-Plans)
    if ($preset -in @('Performance','Balanced','Competitive')) {
        $current = Power-State
        $target = $current
        if ($preset -eq 'Competitive' -and $highPerformance -in @($plans | ForEach-Object Id)) { $target = $highPerformance }
        $name = $plans | Where-Object Id -EQ $target | Select-Object -ExpandProperty Name
        $autonomous = Optional { Read-ACIndex $target 'PERFAUTONOMOUS' 1 }
        $before = Optional { Read-Epp $target }
        if ($target -ne $current) { New-Change 'power.plan' 'machine' $target $name }
        if ($autonomous -eq '1' -and $null -ne $before) {
            $after = if ($preset -eq 'Balanced') { '25' } else { '0' }
            if ([int]$before -gt [int]$after) { New-Change 'cpu.epp.ac' $target $after $name }
        } elseif ($preset -eq 'Performance' -and $target -eq $current -and $current -ne $highPerformance -and $highPerformance -in @($plans | ForEach-Object Id)) {
            $fallback = $plans | Where-Object Id -EQ $highPerformance | Select-Object -ExpandProperty Name
            New-Change 'power.plan' 'machine' $highPerformance $fallback
        }
        if ($preset -eq 'Competitive') {
            $maximum = Optional { Read-ACIndex $target 'CPMAXCORES' 100 }
            $minimum = Optional { Read-ACIndex $target 'CPMINCORES' 100 }
            if ($maximum -eq '100' -and $null -ne $minimum -and [int]$minimum -lt 100) {
                New-Change 'cpu.parking.ac' $target '100' $name
            }
            $boost = Optional { Read-ACIndex $target 'PERFBOOSTMODE' 6 }
            if ($boost -eq '0') {
                $cpuLimit = Optional { Read-ACIndex $target 'PROCTHROTTLEMAX' 100 }
                if ($cpuLimit -eq '100') { New-Change 'cpu.boost.ac' $target '1' $name }
            }
            $pcie = Optional { Read-ACIndex $target 'ASPM' 2 'SUB_PCIEXPRESS' }
            if ($pcie -in @('1','2')) { New-Change 'power.pcie.ac' $target '0' $name }
        }
        return
    }
    $power = switch ($preset) {
        Custom { if ($Request.power) { Guid-Text $Request.power } }
    }
    if ($power -and $power -in @($plans | ForEach-Object Id)) {
        New-Change 'power.plan' 'machine' $power ($plans | Where-Object Id -EQ $power | Select-Object -ExpandProperty Name)
    } elseif ($preset -eq 'Custom' -and $power) { throw 'Select an installed power plan.' }
    if ($preset -eq 'Custom' -and $Request.adapter) { DNS-Plan $Request }
}
function Recommend($Request) {
    foreach ($preset in @('Performance','Competitive')) {
        $changes = @(Plan @{preset=$preset;profile=[string]$Request.profile})
        if ($changes.Count) { return [pscustomobject]@{ Preset=$preset; Changes=$changes } }
    }
    [pscustomobject]@{ Preset='Performance'; Changes=@() }
}
function DNS-Plan($Request) {
    Assert-DNSPolicy
    $target = Guid-Text $Request.adapter
    $adapter = Adapter $target
    if ($adapter.Status -ne 'Up') { throw 'Select a connected adapter.' }
    $provider = [string]$Request.provider
    if ($provider -eq 'Custom') {
        $servers = @(DNS-Addresses @(([string]$Request.servers).Trim() -split '[\s,]+'))
        if (!$servers.Count) { throw 'Enter at least one IPv4 address.' }
    } elseif ($providers.Contains($provider)) { $servers = @($providers[$provider]) }
    else { throw 'Unknown DNS provider.' }
    $state = if ($servers.Count) { $servers -join ',' } else { 'Default' }
    New-Change 'network.dns.ipv4' $target $state $adapter.Name
}
function Write-JSON([string]$Path,$Value) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([guid]::NewGuid().ToString() + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 16), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Get-LarpHistory {
    if ([IO.File]::Exists($journal)) {
        $data = Get-Content -LiteralPath $journal -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data.Version -ne 1) { throw 'Unsupported journal format.' }
        $data.Operations
    }
}
function Save-History($Records) { Write-JSON $journal @{ Version=1; Operations=@($Records) } }
function Locked([scriptblock]$Action) {
    $mutex = New-Object Threading.Mutex($false, 'Global\LarpOptimizer-Settings-v1')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (!$locked) { throw 'Another LARP window is changing settings. Try again shortly.' }
        & $Action
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
function Record-Event($Entry,[string]$Status,[string]$Detail) {
    $Entry.Status = $Status
    $Entry.Events = @($Entry.Events) + @([pscustomobject]@{ At=[DateTime]::UtcNow.ToString('o'); Status=$Status; Detail=$Detail })
}
function Test-Conflict($Entry,[string]$Current) {
    $Current -ne $Entry.After -and $Current -ne $Entry.Before
}
function Invoke-Change($Request,[bool]$Dns,[bool]$Ethernet = $false) {
    Locked {
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $changes = if ($Ethernet) { @(EEE-Plan $Request) } elseif ($Dns) { @(DNS-Plan $Request) } else { @(Plan $Request) }
        $changes = @($changes | Where-Object { $_ })
        $hasSelection = if ($Request -is [System.Collections.IDictionary]) { $Request.Contains('selected') }
                        else { $null -ne $Request.PSObject.Properties['selected'] }
        if ($hasSelection) {
            $ids = @($Request.selected)
            $changes = @($changes | Where-Object { $_.Id -cin $ids })
            if (!$ids.Count -or @($ids | Where-Object { $_ -isnot [string] -or !$_ }).Count -or
                $ids.Count -ne $changes.Count -or @($ids | Select-Object -Unique).Count -ne $ids.Count) {
                throw 'One or more selected changes are no longer available. Review the plan again.'
            }
            $switch = $changes | Where-Object Id -EQ 'power.plan' | Select-Object -First 1
            foreach ($change in $changes | Where-Object { $_.Id -like 'cpu.*.ac' -or $_.Id -eq 'power.pcie.ac' }) {
                if (!$switch -and (Power-State) -ne $change.Target) { throw 'Select the power plan change required by the chosen power setting.' }
            }
        }
        if (!$changes.Count) { throw 'There are no applicable changes. Review the current plan again.' }
        if (@($changes | Where-Object Administrator).Count -and !(Is-Admin)) {
            throw 'Open LARP Optimizer as administrator to apply the reviewed adapter change.'
        }
        $expected = ConvertTo-Json -InputObject @($Request.reviewed | ForEach-Object { "$($_.Id)|$($_.Target)|$($_.Before)|$($_.After)" }) -Compress
        $actual = ConvertTo-Json -InputObject @($changes | ForEach-Object { "$($_.Id)|$($_.Target)|$($_.Before)|$($_.After)" }) -Compress
        if ($expected -cne $actual) { throw 'Settings changed since review. Review the updated plan before applying.' }
        $records = @(Get-LarpHistory)
        $operation = [pscustomobject]@{
            Id=[guid]::NewGuid().ToString(); At=[DateTime]::UtcNow.ToString('o')
            Scope=if ($Dns -or $Ethernet) { 'Network' } else { $Request.profile }
            Baseline=if ($Request.baseline) { Optional { Metrics } } else { $null }; After=$null; DurationMs=$null
            Changes=@($changes | ForEach-Object {
                $_ | Add-Member NoteProperty Status 'Prepared'
                $_ | Add-Member NoteProperty Events @()
                Record-Event $_ 'Prepared' 'Original and intended settings recorded.'
                $_
            })
        }
        $records = @($operation) + $records
        Save-History $records
        foreach ($entry in $operation.Changes) {
            Progress-Line "Applying $($entry.Id) for $($entry.Scope)"
            try {
                if ((State $entry.Id $entry.Target) -ne $entry.Before) {
                    Record-Event $entry 'Skipped' 'The setting changed after backup.'
                    continue
                }
                if (($entry.Id -like 'cpu.*.ac' -or $entry.Id -eq 'power.pcie.ac') -and (Power-State) -ne $entry.Target) {
                    Record-Event $entry 'Skipped' 'The reviewed power plan is no longer active.'
                    continue
                }
                Record-Event $entry 'Applying' 'Starting Windows configuration change.'
                Save-History $records
                $module = Module $entry.Id
                & $module.Write $entry.Target $entry.After
                if ((State $entry.Id $entry.Target) -ne $entry.After) { throw 'Verification did not match the intended setting.' }
                Record-Event $entry 'Applied' 'Read-back verification matched.'
            } catch {
                Record-Event $entry 'Apply failed' $_.Exception.Message
            } finally { Save-History $records }
        }
        if ($Request.baseline) { $operation.After = Optional { Metrics } }
        $operation.DurationMs = $elapsed.ElapsedMilliseconds
        Save-History $records
        $operation
    }
}
function Restore-Operation($Request) {
    Locked {
        $records = @(Get-LarpHistory)
        $operationId = [string]$Request.operation
        $scope = [string]$Request.profile
        if ($operationId) { $operationId = Guid-Text $operationId }
        $results = @()
        $seen = @{}
        foreach ($operation in $records) {
            foreach ($entry in $operation.Changes) {
                if ($entry.Status -in @('Skipped','Restored','Prepared')) { continue }
                $key = "$($entry.Id)/$($entry.Target)"
                $matches = (!$operationId -or $operation.Id -eq $operationId) -and
                           (!$scope -or $operation.Scope -eq $scope) -and
                           (!$Request.module -or $entry.Id -eq $Request.module)
                if (!$matches) { $seen[$key] = $true; continue }
                Progress-Line "Checking $($entry.Id) from $($operation.At)"
                try {
                    if ($seen.ContainsKey($key)) { throw 'A newer active record for this setting must be restored first.' }
                    $current = State $entry.Id $entry.Target
                    if (Test-Conflict $entry $current) {
                        $review = @($Request.overrides | Where-Object { $_.Operation -eq $operation.Id -and $_.Module -eq $entry.Id -and $_.Target -eq $entry.Target -and $_.Current -ceq $current })
                        if (!$review.Count) {
                            $results += [pscustomobject]@{ Operation=$operation.Id; Module=$entry.Id; Target=$entry.Target; Current=$current; RestoreTo=$entry.Before; Status='Conflict'; Detail='Current setting differs from the recorded states.' }
                            $seen[$key] = $true
                            Record-Event $entry 'Conflict' "Current value: $current"
                            continue
                        }
                    }
                    if ($current -ne $entry.Before) {
                        $module = Module $entry.Id
                        if ($module.Admin -and !(Is-Admin)) { throw 'Open LARP Optimizer as administrator to restore network settings.' }
                        Record-Event $entry 'Restoring' "Starting restore from $current."
                        Save-History $records
                        & $module.Write $entry.Target $entry.Before
                    }
                    if ((State $entry.Id $entry.Target) -ne $entry.Before) { throw 'Restore verification did not match the backup.' }
                    Record-Event $entry 'Restored' 'Original setting verified.'
                } catch {
                    Record-Event $entry 'Restore failed' $_.Exception.Message
                    $seen[$key] = $true
                } finally { Save-History $records }
                $results += [pscustomobject]@{ Operation=$operation.Id; Module=$entry.Id; Target=$entry.Target; Status=$entry.Status; Detail=$entry.Events[-1].Detail }
            }
        }
        $results
    }
}

function Metrics {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Optional { Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" }
    $cpuDetails = @(Optional { Get-CimInstance Win32_Processor })
    $gpuCounters = @(Optional { Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine })
    $busyEngines = @($gpuCounters | Where-Object { $_.Name -match '^pid_\d+_luid_' } |
        Group-Object { $_.Name -replace '^pid_\d+_','' } | ForEach-Object {
            [math]::Min(100,($_.Group | Measure-Object UtilizationPercentage -Sum).Sum)
        })
    $available = [long]$os.FreePhysicalMemory * 1KB
    $usable = [long]$os.TotalVisibleMemorySize * 1KB
    [pscustomobject]@{
        At=[DateTime]::UtcNow.ToString('o')
        CpuPercent=if ($cpu) { [int]$cpu.PercentProcessorTime } else { $null }
        ClockMHz=@($cpuDetails | Where-Object CurrentClockSpeed | ForEach-Object CurrentClockSpeed)
        AvailableBytes=$available; UsedBytes=$usable-$available
        MemoryPercent=if ($usable -gt 0) { [math]::Round(100*($usable-$available)/$usable,1) } else { $null }
        GpuBusiestEnginePercent=if ($busyEngines.Count) { ($busyEngines | Measure-Object -Maximum).Maximum } else { $null }
    }
}
function Processes {
    $logical = [Environment]::ProcessorCount
    @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
        Where-Object { $_.IDProcess -gt 0 -and $_.Name -ne '_Total' } |
        Select-Object Name,IDProcess,@{n='CpuPercent';e={[math]::Round($_.PercentProcessorTime/$logical,1)}},
        @{n='PrivateWorkingSetMiB';e={[math]::Round($_.WorkingSetPrivate/1MB,1)}})
}
function GPU {
    foreach ($device in Get-CimInstance Win32_VideoController) {
        $devicePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.PNPDeviceID)"
        $driver = Optional { (Get-Item -LiteralPath $devicePath).GetValue('Driver') }
        $memory = if ($driver -match '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$') {
            Optional { (Get-Item -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driver").GetValue('HardwareInformation.qwMemorySize') }
        }
        [pscustomobject]@{
            Model=$device.Name; Driver=$device.DriverVersion; Status=$device.Status
            DedicatedVRAMBytes=if ($memory -is [long] -and $memory -gt 0) { $memory } else { $null }
            RefreshHz=if ($device.CurrentRefreshRate -gt 1) { $device.CurrentRefreshRate } else { $null }
            DeviceErrorCode=$device.ConfigManagerErrorCode
        }
    }
}
function Active-Adapters {
    $configs = @(Get-NetIPConfiguration -All)
    foreach ($adapter in Get-NetAdapter | Where-Object Status -EQ 'Up') {
        $config = $configs | Where-Object InterfaceIndex -EQ $adapter.ifIndex | Select-Object -First 1
        $dns = @(Optional { Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex | ForEach-Object ServerAddresses } | Where-Object { $_ })
        [pscustomobject]@{
            Id=Guid-Text $adapter.InterfaceGuid; Index=$adapter.ifIndex; Name=$adapter.Name
            Model=$adapter.InterfaceDescription; Type=[string]$adapter.NdisPhysicalMedium
            LinkSpeed=$adapter.LinkSpeed; Driver=$adapter.DriverVersion
            IP=if ($config) { @(@($config.IPv4Address)+@($config.IPv6Address) | Where-Object { $_ } | ForEach-Object IPAddress) } else { @() }
            Gateway=if ($config) { @(@($config.IPv4DefaultGateway)+@($config.IPv6DefaultGateway) | Where-Object { $_ } | ForEach-Object NextHop) } else { @() }
            DNS=$dns; IPv4DnsSource=Optional { DNS-State (Guid-Text $adapter.InterfaceGuid) }
        }
    }
}
function Adapter-Details($Request) {
    $adapter = Adapter $Request.adapter
    [pscustomobject]@{
        Name=$adapter.Name; Model=$adapter.InterfaceDescription; Index=$adapter.ifIndex
        LinkSpeed=$adapter.LinkSpeed; Type=[string]$adapter.NdisPhysicalMedium; Driver=$adapter.DriverVersion
        PowerManagement=Optional {
            Get-NetAdapterPowerManagement -InterfaceDescription $adapter.InterfaceDescription |
                Select-Object AllowComputerToTurnOffDevice,WakeOnMagicPacket,WakeOnPattern,SelectiveSuspend
        }
        AdvancedSettings=@(Optional {
            Get-NetAdapterAdvancedProperty -InterfaceDescription $adapter.InterfaceDescription |
                Select-Object DisplayName,DisplayValue
        })
    }
}
function Dashboard {
    $os = Get-CimInstance Win32_OperatingSystem
    $memory = @(Optional { Get-CimInstance Win32_PhysicalMemory | ForEach-Object Capacity })
    $physical = @(Optional { Get-PhysicalDisk | Select-Object FriendlyName,MediaType,HealthStatus,Size })
    [pscustomobject]@{
        Device=$env:COMPUTERNAME; Windows="$($os.Caption) ($($os.BuildNumber))"; Administrator=Is-Admin
        CPU=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
        GPU=@(GPU)
        InstalledBytes=if ($memory.Count) { ($memory | Measure-Object -Sum).Sum } else { $null }
        Metrics=Metrics
        Volumes=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID,VolumeName,Size,FreeSpace)
        PhysicalDisks=$physical
        Power=Power-State; Plans=@(Power-Plans)
        Adapters=@(Optional { Active-Adapters })
    }
}
function Review-Windows {
    $gameConfig = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -ErrorAction SilentlyContinue
    [pscustomobject]@{
        GameMode=if ($gameConfig -and $gameConfig.AutoGameModeEnabled -in @(0,1)) { if ($gameConfig.AutoGameModeEnabled) { 'On' } else { 'Off' } } else { 'Check Windows Gaming settings' }
        RestartIndicators=@(
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { 'Component servicing' }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { 'Windows Update' }
            if (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue) { 'Pending file operations' }
        )
        Startup=@(Optional { Get-CimInstance Win32_StartupCommand | Select-Object Name,Command,Location,User })
    }
}
function Host-Name([string]$Value) {
    $hostName = $Value.Trim()
    $ip = $null
    if ([Net.IPAddress]::TryParse($hostName,[ref]$ip)) { return $ip.ToString() }
    if ($hostName.Length -gt 253 -or $hostName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$') {
        throw 'Enter an IP address or DNS hostname. For a game server, omit its port.'
    }
    $hostName
}
function Gateway {
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object NextHop -NE '0.0.0.0' | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
        Select-Object -First 1
    if (!$route) { throw 'No IPv4 default route with a gateway was found.' }
    $route.NextHop
}
function Probe-Target([string]$Value) {
    switch ($Value) {
        'Gateway' { Gateway }
        'Cloudflare' { '1.1.1.1' }
        'Google' { '8.8.8.8' }
        default { Host-Name $Value }
    }
}
function Percentile($Values,[double]$Fraction) {
    $ordered = @($Values | Sort-Object)
    if ($ordered.Count) { $ordered[[int][math]::Ceiling($ordered.Count * $Fraction) - 1] }
}
function Ping-Test([string]$Destination,[int]$Count,[int]$Timeout) {
    if ($Count -lt 2 -or $Count -gt 15 -or $Timeout -lt 100 -or $Timeout -gt 2000) {
        throw 'Use 2–15 samples and a timeout of 100–2000 ms.'
    }
    $ping = New-Object Net.NetworkInformation.Ping
    $times = @()
    $samples = @()
    $failed = 0
    $lastError = $null
    try {
        $addresses = [Net.Dns]::GetHostAddresses($Destination)
        if (!$addresses.Length) { throw 'The hostname has no IP addresses.' }
        for ($i = 0; $i -lt $Count; $i++) {
            try {
                $reply = $ping.Send($addresses[0],$Timeout)
                if ($reply.Status -eq 'Success') {
                    $times += [long]$reply.RoundtripTime
                    $samples += [long]$reply.RoundtripTime
                } else { $failed++; $samples += $null; $lastError = [string]$reply.Status }
            } catch { $failed++; $samples += $null; $lastError = $_.Exception.GetBaseException().Message }
            if ($i+1 -lt $Count) { Start-Sleep -Milliseconds 200 }
        }
    } finally { $ping.Dispose() }
    $stats = $times | Measure-Object -Minimum -Maximum -Average
    $deltas = @(for ($i = 1; $i -lt $times.Count; $i++) { [math]::Abs($times[$i]-$times[$i-1]) })
    [pscustomobject]@{
        At=[DateTime]::UtcNow.ToString('o'); Destination=$Destination; Address=$addresses[0].ToString()
        Count=$Count; Failed=$failed
        LossPercent=[math]::Round(100*$failed/$Count,1); SamplesMs=$samples
        MinimumMs=$stats.Minimum; AverageMs=if ($times.Count) { [math]::Round($stats.Average,2) } else { $null }
        MaximumMs=$stats.Maximum
        MedianMs=Percentile $times 0.5
        P95Ms=Percentile $times 0.95
        JitterMs=if ($deltas.Count) { [math]::Round(($deltas | Measure-Object -Average).Average,2) } else { $null }
        LastError=$lastError
    }
}
function Compare-Endpoints($Request) {
    $first = Host-Name $Request.host
    $second = Host-Name $Request.alternate
    if ($first -eq $second) { throw 'Enter two different game hosts or IP addresses.' }
    $results = @(foreach ($target in @($first,$second)) {
        try { Ping-Test $target $Request.count $Request.timeout }
        catch { [pscustomobject]@{ Destination=$target; Error=$_.Exception.Message } }
    })
    $available = @($results | Where-Object { $_.PSObject.Properties['Failed'] })
    $clean = @($available | Where-Object Failed -EQ 0 | Sort-Object MedianMs,P95Ms)
    $lowest = if ($clean.Count -eq 2 -and $clean[0].Address -ne $clean[1].Address -and $clean[0].MedianMs -lt $clean[1].MedianMs) {
        $clean[0].Destination
    } else { $null }
    [pscustomobject]@{
        Tests=$results; LowerMedianWithoutLoss=$lowest
        Note='Compare regions or servers you can select in the game. These small ICMP samples measure the current path and can differ from game traffic.'
    }
}
function Compare-Network($Request) {
    $targets = @('Gateway','Cloudflare','Google')
    if ($Request.host) { $targets += Host-Name $Request.host }
    $tests = @(foreach ($target in $targets) {
        try { Ping-Test (Probe-Target $target) $Request.count $Request.timeout }
        catch { [pscustomobject]@{ Destination=$target; Error=$_.Exception.Message } }
    })
    $notes = @('ICMP can be filtered or deprioritized. These samples cannot establish how game traffic is treated.')
    $goodExternal = @($tests | Select-Object -Skip 1 | Where-Object { $_.PSObject.Properties['Failed'] -and $_.Failed -eq 0 })
    $badExternal = @($tests | Select-Object -Skip 1 | Where-Object { $_.PSObject.Properties['Failed'] -and $_.Failed -gt 0 })
    $local = $tests[0]
    if ($local.PSObject.Properties['Failed'] -and $local.Failed -gt 0) {
        $notes += if ($goodExternal.Count) { 'Gateway loss with clean external replies can reflect gateway ICMP handling.' }
                  else { 'Gateway loss alongside external problems warrants checking Wi-Fi signal, cabling and router reachability.' }
    } elseif ($local.PSObject.Properties['Failed'] -and $badExternal.Count -ge 2) {
        $notes += 'A clean gateway with loss to multiple remote destinations suggests checking upstream connectivity and shared paths.'
    }
    if ($goodExternal.Count -and $badExternal.Count) { $notes += 'Mixed external results warrant comparing destination-specific routes and ICMP handling.' }
    [pscustomobject]@{ Tests=$tests; Interpretation=$notes }
}
function DNS-Test($Request) {
    $hostName = Host-Name $Request.host
    if ($hostName -notmatch '\.' -or $hostName -match '^[\d.]+$') { throw 'Enter a fully qualified DNS hostname.' }
    $query = @{Name=$hostName.TrimEnd('.')+'.'; Type='A'; DnsOnly=$true; NoHostsFile=$true; QuickTimeout=$true}
    if ($Request.server) { $query.Server = IPv4 $Request.server }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $answers = @(Resolve-DnsName @query | Where-Object Type -EQ 'A' | ForEach-Object IPAddress)
    $timer.Stop()
    [pscustomobject]@{
        Host=$hostName; Resolver=if ($Request.server) { $query.Server } else { 'System resolver' }
        Milliseconds=[math]::Round($timer.Elapsed.TotalMilliseconds,1)
        Answers=$answers; HasARecord=($answers.Count -gt 0)
        Note='Elapsed query time includes Windows overhead and may include cached results.'
    }
}
function Routes {
    Get-NetRoute | Sort-Object AddressFamily,DestinationPrefix,RouteMetric |
        Select-Object AddressFamily,DestinationPrefix,NextHop,InterfaceIndex,InterfaceAlias,RouteMetric,InterfaceMetric
}
function Route-To($Request) {
    $destination = Probe-Target $Request.host
    $ip = [Net.Dns]::GetHostAddresses($destination) | Select-Object -First 1
    if (!$ip) { throw 'The destination has no IP addresses.' }
    $objects = @(Find-NetRoute -RemoteIPAddress $ip.ToString())
    $source = $objects | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetIPAddress' } | Select-Object -First 1
    $route = $objects | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
    if (!$route) { throw 'Windows did not return a selected route.' }
    [pscustomobject]@{
        Destination=$destination; RemoteAddress=$ip.ToString()
        SourceAddress=if ($source) { $source.IPAddress } else { $null }
        Interface=$route.InterfaceAlias; InterfaceIndex=$route.InterfaceIndex
        Prefix=$route.DestinationPrefix; NextHop=$route.NextHop
        RouteMetric=$route.RouteMetric; InterfaceMetric=$route.InterfaceMetric
    }
}
function Trace-To($Request) {
    $destination = Probe-Target $Request.host
    Native 'tracert.exe' @('-d','-h','20','-w','600',$destination)
}
function Profile-Info($Request) {
    $data = Profile $Request.profile
    $names = @($games[$data.Name] -split ',' | Where-Object { $_ })
    if ($data.Executable) { $names = @([IO.Path]::GetFileNameWithoutExtension($data.Executable)) }
    $candidates = @(Get-Process | Where-Object ProcessName -In $names | Select-Object ProcessName,Id,
        @{n='Path';e={$_.Path}},@{n='WorkingSetMiB';e={[math]::Round($_.WorkingSet64/1MB,1)}})
    [pscustomobject]@{
        Settings=$data; RecognizedNames=$names; RunningCandidates=$candidates
        Metrics=Metrics
        Suggestion=$profileTips[$data.Name]
    }
}
function Save-Profile($Request) {
    $null = Profile $Request.profile
    if ($Request.preset -notin $presets) { throw 'Unknown preset.' }
    $file = [string]$Request.executable
    if ($file -and (![IO.Path]::IsPathRooted($file) -or $file.StartsWith('\\') -or
         [IO.Path]::GetExtension($file) -ne '.exe' -or !(Test-Path -LiteralPath $file -PathType Leaf))) {
        throw 'Select an existing local .exe file.'
    }
    $destination = if ($Request.host) { Host-Name $Request.host } else { '' }
    $data = [pscustomobject]@{ Name=$Request.profile; Preset=$Request.preset; Executable=$file; Host=$destination }
    Write-JSON (Join-Path $store ('profile-' + [array]::IndexOf(@($games.Keys),$Request.profile) + '.json')) $data
    $data
}
function Benchmark($Request) {
    $measure = [ordered]@{
        Metrics=Metrics
        Processes=@(Processes | Sort-Object CpuPercent -Descending | Select-Object -First 8)
        GPU=@(GPU)
    }
    if ($Request.host) { $measure.Ping=Ping-Test (Probe-Target $Request.host) $Request.count $Request.timeout }
    if ($Request.dnsHost) { $measure.DNS=DNS-Test ([pscustomobject]@{host=$Request.dnsHost;server=''}) }
    [pscustomobject]$measure
}
function Run-Request($Request) {
    switch -Exact ($Request.action) {
        dashboard { Dashboard }
        metrics { Metrics }
        cpu {
            $active = Power-State
            [pscustomobject]@{
                CPU=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
                Power=$active; PerformancePreferenceAC=Optional { Read-Epp $active }
                BoostPolicyAC=Optional { Read-ACIndex $active 'PERFBOOSTMODE' 6 }
                PcieLinkSavingAC=Optional { Read-ACIndex $active 'ASPM' 2 'SUB_PCIEXPRESS' }
                Processes=@(Processes | Sort-Object CpuPercent -Descending | Select-Object -First 12)
            }
        }
        memory {
            [pscustomobject]@{
                Metrics=Metrics
                Processes=@(Processes | Sort-Object PrivateWorkingSetMiB -Descending | Select-Object -First 12)
                Startup=(Review-Windows).Startup
            }
        }
        processes { Processes }
        gpu { GPU }
        gpuPanel {
            $choice = switch ($Request.vendor) { NVIDIA { '3' } AMD { '4' } Intel { '5' } default { throw 'Unknown GPU vendor.' } }
            Open-GPU $choice
        }
        windows { Review-Windows }
        adapters { Active-Adapters }
        adapter { Adapter-Details $Request }
        plans { Power-Plans }
        plan { Plan $Request }
        recommend { Recommend $Request }
        apply { Invoke-Change $Request $false }
        dnsPlan { DNS-Plan $Request }
        dnsApply { Invoke-Change $Request $true }
        eeePlan { EEE-Plan $Request }
        eeeApply { Invoke-Change $Request $false $true }
        dnsTest { DNS-Test $Request }
        ping { Ping-Test (Probe-Target $Request.host) $Request.count $Request.timeout }
        compare { Compare-Network $Request }
        endpoints { Compare-Endpoints $Request }
        routes { Routes }
        route { Route-To $Request }
        trace { Trace-To $Request }
        history { Get-LarpHistory }
        restore { Restore-Operation $Request }
        profile { Profile-Info $Request }
        profileSettings { Profile ([string]$Request.profile) }
        saveProfile { Save-Profile $Request }
        benchmark { Benchmark $Request }
        flush {
            if (!(Is-Admin)) { throw 'Open LARP Optimizer as administrator to flush the DNS cache.' }
            $output = Native 'ipconfig.exe' @('/flushdns')
            [pscustomobject]@{ Status='Command completed'; Output=@($output) }
        }
        restorePoint {
            if (!(Is-Admin)) { throw 'Open LARP Optimizer as administrator to create a restore point.' }
            $before = @(Get-ComputerRestorePoint | ForEach-Object SequenceNumber)
            $label = 'LARP Optimizer ' + [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
            Checkpoint-Computer -Description $label -RestorePointType MODIFY_SETTINGS
            $created = @(Get-ComputerRestorePoint | Where-Object { $_.Description -eq $label -and $_.SequenceNumber -notin $before })
            if (!$created.Count) { throw 'Windows did not report a new restore point. Check System Protection and its creation interval.' }
            $created | Select-Object Description,SequenceNumber,CreationTime
        }
        default { throw 'Unknown engine operation.' }
    }
}



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


Terminal
