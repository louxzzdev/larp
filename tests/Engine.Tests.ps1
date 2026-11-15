param([switch]$Integration,[switch]$PowerWrite)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$enginePath = Join-Path $root 'src\LarpOptimizer.Engine\Engine.ps1'
$engine = [scriptblock]::Create([IO.File]::ReadAllText($enginePath,[Text.Encoding]::UTF8))
. $engine
$script:terminal = $false
$checks = 0
function Assert($Condition,[string]$Name) {
    if (!$Condition) { throw "FAIL: $Name" }
    $script:checks++
    Write-Host "PASS: $Name"
}
function Reject([scriptblock]$Action,[string]$Name) {
    $threw = $false
    try { $null = & $Action } catch { $threw = $true }
    Assert $threw $Name
}
Assert ((IPv4 '1.1.1.1') -eq '1.1.1.1') 'canonical DNS accepted'
Reject { IPv4 '1.1.1.257' } 'invalid IPv4 rejected'
Reject { IPv4 '1.1.01.1' } 'noncanonical IPv4 rejected'
Reject { IPv4 '224.0.0.1' } 'multicast DNS rejected'
Reject { DNS-Addresses @('1.1.1.1','1.1.1.1') } 'duplicate servers rejected'
Reject { Host-Name 'example.org & whoami' } 'shell metacharacters rejected'
Reject { Host-Name '-n' } 'switch-like host rejected'
Reject { Ping-Test '127.0.0.1' 1 750 } 'sample limit enforced'
Assert ((Host-Name 'game.example.org') -eq 'game.example.org') 'FQDN accepted'
Assert ((Host-Name '::1') -eq '::1') 'IPv6 destination accepted'
Assert ((Host-Name '127.0.0.1') -eq '127.0.0.1') 'IPv4 destination accepted'
Assert ((DNS-ConfigValue '') -eq 'Default') 'automatic DNS is represented separately from a static list'
Assert ((Percentile @(9,1,3,7,5) 0.5) -eq 5 -and (Percentile @(9,1,3,7,5) 0.95) -eq 9) 'nearest-rank latency percentiles'
Assert ($null -eq (Percentile @() 0.95)) 'no latency percentile when all probes fail'
Assert ((DNS-ConfigValue '9.9.9.9, 149.112.112.112') -eq '9.9.9.9,149.112.112.112') 'static DNS order preserved'

# Run mocked configuration changes in a child scope so real Windows functions remain available.
& {
    $original = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $external = '00000000-0000-0000-0000-000000000001'
    $store = Join-Path ([IO.Path]::GetTempPath()) ('larp-test-' + [guid]::NewGuid())
    $journal = Join-Path $store 'history.json'
    $real = $modules['power.plan']
    $modules['power.plan'] = $real.Clone()
    $modules['power.plan'].Read = { param($Target) $script:mockState }
    $modules['power.plan'].Write = { param($Target,$Value) $script:mockState = $Value }
    $script:mockState = $original
    function Is-Admin { $true }
    function Power-Plans { [pscustomobject]@{ Id=$highPerformance; Name='High performance' } }
    try {
        $req = @{preset='Safe';profile='Valorant';power='';adapter='';baseline=$false}
        Assert (@(Plan $req).Count -eq 0) 'Safe plan is review-only'
        $req.preset = 'Custom'
        $req.power = $highPerformance
        $req.reviewed = @(Plan $req)
        Assert ($req.reviewed.Count -eq 1) 'installed performance plan offered'
        $script:mockState = $external
        Reject { Invoke-Change $req $false } 'stale review rejected before mutation'
        $script:mockState = $original
        $operation = Invoke-Change $req $false
        Assert ($operation.Changes[0].Status -eq 'Applied' -and $mockState -eq $highPerformance) 'apply verified'
        Assert ($null -ne $operation.DurationMs -and $operation.DurationMs -ge 0) 'measured session duration recorded'
        Assert (@(Get-LarpHistory)[0].Changes[0].Before -eq $original) 'original state persisted'
        $script:mockState = $external
        $restore = @{operation=$operation.Id;module='power.plan';profile='Valorant';overrides=@()}
        $conflict = @(Restore-Operation $restore)
        Assert ($conflict[0].Status -eq 'Conflict' -and $mockState -eq $external) 'external state preserved without confirmation'
        $restore.overrides = $conflict
        $script:mockState = '00000000-0000-0000-0000-000000000002'
        $fresh = @(Restore-Operation $restore)
        Assert ($fresh[0].Status -eq 'Conflict') 'stale conflict confirmation rejected'
        $restore.overrides = $fresh
        $restored = @(Restore-Operation $restore)
        Assert ($restored[0].Status -eq 'Restored' -and $mockState -eq $original) 'confirmed restore verified'
        Assert (@(Restore-Operation $restore).Count -eq 0) 'restore is idempotent'
        $profile = Save-Profile @{profile='Valorant';preset='Balanced';executable='';host='game.example.org'}
        Assert ((Profile 'Valorant').Host -eq $profile.Host) 'profile persists for the correct game'
        Assert ((Profile 'Counter-Strike 2').Host -eq '') 'profile storage is isolated'

        $realEpp = $modules['cpu.epp.ac']
        try {
            $modules['cpu.epp.ac'] = $realEpp.Clone()
            $modules['cpu.epp.ac'].Read = { param($Target) $script:mockEpp }
            $modules['cpu.epp.ac'].Write = { param($Target,$Value) $script:mockEpp = $Value }
            $script:mockEpp = '5'
            & {
                function Power-State { $highPerformance }
                function Read-ACIndex { '1' }
                function Read-Epp { $script:mockEpp }
                $request = @{preset='Performance';profile='General Gaming';baseline=$false}
                $request.reviewed = @(Plan $request)
                Assert ($request.reviewed.Count -eq 1 -and $request.reviewed[0].Id -eq 'cpu.epp.ac' -and $request.reviewed[0].After -eq '0') 'default preset plans CPU preference even when High performance is active'
                $applied = Invoke-Change $request $false
                Assert ($applied.Changes[0].Status -eq 'Applied' -and $mockEpp -eq '0') 'CPU preference applied and verified'
                $restoreEpp = @{operation=$applied.Id;module='cpu.epp.ac';profile='';overrides=@()}
                $result = @(Restore-Operation $restoreEpp)
                Assert ($result[0].Status -eq 'Restored' -and $mockEpp -eq '5') 'original CPU preference restored and verified'
                $script:mockEpp = '0'
                Assert (@(Plan $request).Count -eq 0) 'matching CPU preference requires no write'
            }
        } finally { $modules['cpu.epp.ac'] = $realEpp }
        & {
            function Power-State { $highPerformance }
            function Read-ACIndex($PlanId,$Setting) {
                switch ($Setting) {
                    PERFBOOSTMODE { '0' }
                    ASPM { '2' }
                    PROCTHROTTLEMAX { $script:cpuLimit }
                    CPMAXCORES { '100' }
                    CPMINCORES { '100' }
                    PERFAUTONOMOUS { '1' }
                    PERFEPP { '0' }
                }
            }
            $script:cpuLimit = '100'
            $request = @{preset='Competitive';profile='General Gaming'}
            $plan = @(Plan $request)
            Assert ($plan.Count -eq 2 -and $plan[0].Id -eq 'cpu.boost.ac' -and $plan[0].After -eq '1' -and
                $plan[1].Id -eq 'power.pcie.ac' -and $plan[1].After -eq '0') 'Competitive proposes disabled boost and active PCIe link saving'
            $script:cpuLimit = '99'
            Assert (@(Plan $request | Where-Object Id -eq 'cpu.boost.ac').Count -eq 0) 'Competitive respects a user processor cap'
            Reject { Set-PlanACIndex $highPerformance 'ASPM' '3' } 'invalid PCIe index rejected before any write'
        }

        $realDns = $modules['network.dns.ipv4']
        try {
            $modules['network.dns.ipv4'] = $realDns.Clone()
            $modules['network.dns.ipv4'].Read = { param($Target) $script:mockDns }
            $modules['network.dns.ipv4'].Write = { param($Target,$Value) $script:mockDns = $Value }
            $script:mockDns = 'Default'
            $id = '7189bb48-89fa-402d-af07-cdb9bfab2a9c'
            function Adapter { [pscustomobject]@{ Name='Test Ethernet'; Status='Up' } }
            $custom = @{preset='Custom';profile='Valorant';power=$highPerformance;baseline=$false;adapter=$id;provider='Quad9'}
            $custom.reviewed = @(Plan $custom)
            Assert ($custom.reviewed.Count -eq 2) 'custom plan combines installed power and selected DNS'
            $combined = Invoke-Change $custom $false
            Assert (@($combined.Changes | Where-Object Status -EQ 'Applied').Count -eq 2) 'each custom optimization verified'
            $next = @{adapter=$id;provider='Cloudflare';baseline=$false}
            $next.reviewed = @(DNS-Plan $next)
            $dnsOperation = Invoke-Change $next $true
            $oneModule = @{operation=$combined.Id;module='network.dns.ipv4';profile='';overrides=@()}
            $blocked = @(Restore-Operation $oneModule)
            Assert ($blocked[0].Status -eq 'Restore failed' -and $mockDns -eq '1.1.1.1,1.0.0.1') 'newer DNS record blocks older restore'
            $oneModule.operation = $dnsOperation.Id
            $restored = @(Restore-Operation $oneModule)
            Assert ($restored[0].Status -eq 'Restored' -and $mockDns -eq '9.9.9.9,149.112.112.112') 'static DNS restored in original order'
            $oneModule.operation = $combined.Id
            $restored = @(Restore-Operation $oneModule)
            Assert ($restored[0].Status -eq 'Restored' -and $mockDns -eq 'Default') 'automatic DNS restored separately from static'
            $script:mockState = $original
            $custom.selected = @()
            Reject { Invoke-Change $custom $false } 'explicit empty selection rejected'
            $custom.selected = @('network.dns.ipv4')
            $custom.reviewed = @(Plan $custom | Where-Object Id -EQ 'network.dns.ipv4')
            $guiRequest = $custom | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $selectedOnly = Invoke-Change $guiRequest $false
            Assert ($selectedOnly.Changes.Count -eq 1 -and $mockDns -eq '9.9.9.9,149.112.112.112' -and $mockState -eq $original) 'only reviewed and selected changes are applied'
        } finally { $modules['network.dns.ipv4'] = $realDns }
        & {
            $adapterId = '7189bb48-89fa-402d-af07-cdb9bfab2a9c'
            $script:ethernetValue = '1'
            $script:physicalMedium = 9
            function Adapter { [pscustomobject]@{ Name='Test Ethernet'; Status='Up'; HardwareInterface=$true; NdisPhysicalMedium=$script:physicalMedium } }
            function Get-NetAdapterAdvancedProperty {
                [pscustomobject]@{ RegistryKeyword='*EEE'; RegistryValue=@($script:ethernetValue); ValidRegistryValues=@('0','1') }
            }
            function Set-NetAdapterAdvancedProperty { param($InputObject,$RegistryValue,$Confirm) $script:ethernetValue=$RegistryValue[0] }
            $request = @{adapter=$adapterId;baseline=$false}
            Reject { EEE-Plan $request } 'Ethernet tuning rejects a Wi-Fi adapter'
            $script:physicalMedium = 14
            $request.reviewed = @(EEE-Plan $request)
            Assert ($request.reviewed.Count -eq 1 -and $request.reviewed[0].Before -eq '1') 'Ethernet change previews the known driver value'
            $operation = Invoke-Change $request $false $true
            Assert ($operation.Changes[0].Status -eq 'Applied' -and $script:ethernetValue -eq '0') 'Ethernet change is read back and journaled'
            $options = @{operation=$operation.Id;module='network.ethernet.eee';profile='';overrides=@()}
            $record = @(Restore-Operation $options)
            Assert ($record[0].Status -eq 'Restored' -and $script:ethernetValue -eq '1') 'Ethernet restore reinstates the original value'
        }
    } finally {
        $modules['power.plan'] = $real
        if ([IO.Directory]::Exists($store)) { [IO.Directory]::Delete($store,$true) }
    }
}
if ($Integration) {
    $info = Dashboard
    Assert ($info.CPU.Count -gt 0 -and $info.Metrics.AvailableBytes -gt 0) 'real Windows hardware inspection'
    Assert ($info.Power -in @($info.Plans | ForEach-Object Id)) 'active Windows power plan appears in supported plans'
    Assert (@(Routes).Count -gt 0) 'real Windows route table'
    Assert (@(Route-To @{host='127.0.0.1'}).Count -gt 0) 'real route selection to loopback'
    Assert (@(Processes).Count -gt 0) 'real Windows process counters'
    $probe = Ping-Test '127.0.0.1' 2 500
    Assert ($probe.Count -eq 2 -and $probe.Failed -eq 0) 'loopback ICMP'
    Assert ($probe.MedianMs -ge 0 -and $probe.P95Ms -ge $probe.MedianMs) 'real loopback sample percentiles'
    $comparison = Compare-Endpoints @{host='127.0.0.1';alternate='::1';count=2;timeout=500}
    Assert ($comparison.Tests.Count -eq 2 -and !$comparison.Tests[0].Failed -and !$comparison.Tests[1].Failed) 'compares two explicitly selected loopback endpoints'
    $null = Review-Windows
    foreach ($adapter in $info.Adapters) {
        Assert ((Adapter $adapter.Id).ifIndex -eq $adapter.Index) 'stable adapter identity'
        $null = Adapter-Details @{adapter=$adapter.Id}
    }
}
if ($PowerWrite) {
    $active = Power-State
    $temporary = [guid]::NewGuid().ToString()
    $null = Native 'powercfg.exe' @('/duplicatescheme',$active,$temporary)
    try {
        $original = Read-Epp $temporary
        $target = if ($original -eq '0') { '25' } else { '0' }
        Set-Epp $temporary $target
        Assert ((Read-Epp $temporary) -eq $target) 'Windows stored the CPU preference on an inactive test plan'
        Set-Epp $temporary $original
        Assert ((Read-Epp $temporary) -eq $original) 'Windows restored the CPU preference on the test plan'
        $minimum = Read-ACIndex $temporary 'CPMINCORES' 100
        $parkingTarget = if ((Read-ACIndex $temporary 'CPMAXCORES' 100) -eq '100' -and $minimum -ne '100') { '100' } else { '0' }
        Set-CpuACIndex $temporary 'CPMINCORES' $parkingTarget
        Assert ((Read-ACIndex $temporary 'CPMINCORES' 100) -eq $parkingTarget) 'Windows stored the core-parking minimum on the test plan'
        Set-CpuACIndex $temporary 'CPMINCORES' $minimum
        Assert ((Read-ACIndex $temporary 'CPMINCORES' 100) -eq $minimum) 'Windows restored the core-parking minimum on the test plan'
        foreach ($test in @(@('PERFBOOSTMODE',6,'SUB_PROCESSOR','1'), @('ASPM',2,'SUB_PCIEXPRESS','0'))) {
            $setting,$limit,$group,$preferred = $test
            $index = Read-ACIndex $temporary $setting $limit $group
            $alternate = if ($index -eq $preferred) { if ($preferred -eq '0') { '1' } else { '0' } } else { $preferred }
            Set-PlanACIndex $temporary $setting $alternate
            Assert ((Read-ACIndex $temporary $setting $limit $group) -eq $alternate) "Windows stored $setting on the test plan"
            Set-PlanACIndex $temporary $setting $index
            Assert ((Read-ACIndex $temporary $setting $limit $group) -eq $index) "Windows restored $setting on the test plan"
        }
        Assert ((Power-State) -eq $active) 'live plan was not switched'
    } finally {
        $null = Native 'powercfg.exe' @('/delete',$temporary)
    }
    Assert ($temporary -notin @(Power-Plans | ForEach-Object Id)) 'temporary test plan removed'
}
Write-Host "$checks checks passed."
