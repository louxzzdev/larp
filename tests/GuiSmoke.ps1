param([string]$Executable,[switch]$ExpectCpuPreview,[switch]$Overhaul,[switch]$StartupOnly,[switch]$NetworkTuning,[string]$ScreenshotPath)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
if (!$Executable) { $Executable = Join-Path (Split-Path $PSScriptRoot -Parent) 'release\LARP Optimizer.exe' }
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Element-WithName($Root,[string]$Name,$Type) {
    $byName = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,$Name)
    $byType = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,$Type)
    $condition = New-Object Windows.Automation.AndCondition($byName,$byType)
    $Root.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
}
function Await([scriptblock]$Check,[string]$Description) {
    $until = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $until) {
        if ($process.HasExited) { throw "EXE exited during $Description with $($process.ExitCode)." }
        $result = & $Check
        if ($result) { return $result }
        Start-Sleep -Milliseconds 200
    }
    $detail = ''
    if (Get-Variable window -Scope Script -ErrorAction SilentlyContinue) {
        $byId = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,'Status')
        $status = $window.FindFirst([Windows.Automation.TreeScope]::Descendants,$byId)
        if ($status) { $detail = " Status: $($status.Current.Name)" }
    }
    throw "Timed out: $Description.$detail"
}

$button = [Windows.Automation.ControlType]::Button
$text = [Windows.Automation.ControlType]::Text
$edit = [Windows.Automation.ControlType]::Edit
$prefsPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LARP Optimizer\interface.json'
$hadPreferences = $Overhaul -and [IO.File]::Exists($prefsPath)
$oldPreferences = if ($hadPreferences) { [IO.File]::ReadAllBytes($prefsPath) }
$prefsTestStarted = $false
$expectedChanges = @(if ($ExpectCpuPreview) {
    & {
        $enginePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\LarpOptimizer.Engine\Engine.ps1'
        . ([scriptblock]::Create([IO.File]::ReadAllText($enginePath,[Text.Encoding]::UTF8)))
        Plan @{preset='Performance';profile='General Gaming';baseline=$false}
    }
})
$startupTimer = [Diagnostics.Stopwatch]::StartNew()
$process = Start-Process -FilePath $Executable -PassThru
try {
    $window = Await {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        }
    } 'opening published EXE'
    Write-Host "TIME: window $($startupTimer.ElapsedMilliseconds) ms"
    $null = Await { Element-WithName $window 'Live resource use' $text } 'rendering measured dashboard'
    Write-Host "TIME: dashboard $($startupTimer.ElapsedMilliseconds) ms"
    Write-Host 'PASS: published EXE displays measured dashboard'
    if ($ScreenshotPath) {
        $null = Await { Element-WithName $window 'Hardware' $text } 'inventory before screenshot'
        Add-Type -AssemblyName System.Drawing
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TestWindowCapture {
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr window, IntPtr context, uint flags);
}
'@
        $rectangle = $window.Current.BoundingRectangle
        $bitmap = New-Object Drawing.Bitmap([int]$rectangle.Width,[int]$rectangle.Height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $dc = $graphics.GetHdc()
            try {
                if (![TestWindowCapture]::PrintWindow($process.MainWindowHandle,$dc,2)) { throw 'Could not capture test window.' }
            } finally { $graphics.ReleaseHdc($dc) }
            $bitmap.Save($ScreenshotPath,[Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    if ($StartupOnly) { return }
    $pages = [ordered]@{
        Optimize=@('Optimize now',$button); CPU=@('CPU snapshot',$edit); GPU=@('Detected display adapters',$edit)
        Memory=@('Memory snapshot',$edit); Network=@('Ping target',$button); Diagnostics=@('Capture baseline',$button)
        Restore=@('Restore selected',$button); Settings=@('Windows review',$edit)
    }
    foreach ($name in $pages.Keys) {
        $link = Await {
            $found = Element-WithName $window $name $button
            if ($found -and $found.Current.IsEnabled) { $found }
        } "navigation to $name"
        $navigationTimer = [Diagnostics.Stopwatch]::StartNew()
        $link.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        $expected = $pages[$name]
        $null = Await { Element-WithName $window $expected[0] $expected[1] } "$name content"
        Write-Host "PASS: $name ($($navigationTimer.ElapsedMilliseconds) ms)"
        if ($name -eq 'Optimize' -and $ExpectCpuPreview) {
            $scan = Element-WithName $window 'Optimize now' $button
            $scan.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            if ($expectedChanges.Count -eq 0) {
                $null = Await { Element-WithName $window 'No applicable changes' $text } 'correct no-change outcome'
                Write-Host 'PASS: correctly reports no applicable change on the active configuration'
            } else {
                $null = Await { Element-WithName $window 'Apply changes' $button } 'real optimization preview'
                $arrow = [char]0x2192
                foreach ($change in $expectedChanges) {
                    $label = "Current $arrow proposed   $($change.Before) $arrow $($change.After)"
                    $null = Await { Element-WithName $window $label $text } 'verified Windows values in review'
                }
                Write-Host 'PASS: real optimization preview without applying it'
            }
        }
        if ($name -eq 'Network') {
            $probe = Await {
                $found = Element-WithName $window 'Ping target' $button
                if ($found -and $found.Current.IsEnabled) { $found }
            } 'network controls enabled'
            $field = Element-WithName $window 'Target: Gateway, Cloudflare, Google or host' $edit
            $field.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('127.0.0.1')
            $probe.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            $metrics = Await { Element-WithName $window 'ICMP measurements' $edit } 'loopback ping output'
            $report = $metrics.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
            if ($report -notmatch 'Loss Percent\s+0\b') { throw 'GUI loopback test did not report zero loss.' }
            Write-Host 'PASS: GUI loopback ping'
            if ($NetworkTuning) {
                $a = Element-WithName $window 'Game server or region A' $edit
                $b = Element-WithName $window 'Game server or region B' $edit
                $a.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('127.0.0.1')
                $b.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('::1')
                $compare = Element-WithName $window 'Compare latency' $button
                $compare.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                $null = Await { Element-WithName $window 'Sampled server latency' $text } 'game endpoint comparison'
                Write-Host 'PASS: GUI compares two explicitly selected loopback destinations'
            }
            $samples = Element-WithName $window 'Samples' $edit
            $samples.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('15')
            $probe.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            $null = Await { Element-WithName $window 'Cancel scans' $button } 'in-progress network scan'
            $destination = Element-WithName $window 'Diagnostics' $button
            if (!$destination.Current.IsEnabled) { throw 'Navigation was disabled during scan.' }
            $destination.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            $null = Await { Element-WithName $window 'Capture baseline' $button } 'navigation while scan is running'
            if (Element-WithName $window 'ICMP measurements' $edit) { throw 'Previous page scan leaked into diagnostics.' }
            Write-Host 'PASS: can leave a page while a scan is running'
        }
    }
    if ($Overhaul) {
        $settings = Element-WithName $window 'Search settings' $edit
        $field = $settings.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $field.SetValue('no-such-setting')
        $null = Await { Element-WithName $window 'No matching settings.' $text } 'settings empty search state'
        $field.SetValue('theme')
        $dark = Await { Element-WithName $window 'Dark theme' $button } 'searchable theme setting'
        $target = if ($dark.Current.ItemStatus -eq 'Selected') { 'Light' } else { 'Dark' }
        $choice = Element-WithName $window "$target theme" $button
        $prefsTestStarted = $true
        $choice.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        $null = Await {
            if ([IO.File]::Exists($prefsPath)) { ([IO.File]::ReadAllText($prefsPath) | ConvertFrom-Json).Theme -eq $target }
        } 'theme preference saved to disk'
        Write-Host 'PASS: searchable settings and theme persistence'

        $palette = Element-WithName $window 'Search commands' $button
        $palette.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        $search = Await { Element-WithName $window 'Search pages and actions' $edit } 'palette search'
        $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('dns')
        $open = Await {
            $found = Element-WithName $window 'Open selected' $button
            if ($found -and $found.Current.IsEnabled) { $found }
        } 'palette resolves network alias'
        $open.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        $null = Await { Element-WithName $window 'Ping target' $button } 'palette opens network page'
        Write-Host 'PASS: searchable command palette'

        $window.GetCurrentPattern([Windows.Automation.TransformPattern]::Pattern).Resize(600,520)
        $history = Await { Element-WithName $window 'Restore' $button } 'compact sidebar navigation'
        $history.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        $search = Await { Element-WithName $window 'Search session, profile or setting' $edit } 'history filters'
        $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('no-matching-session-id-23432')
        $null = Await { Element-WithName $window 'No sessions match these filters.' $text } 'history empty filter state'
        Write-Host 'PASS: history search and compact desktop layout'

        $process.Refresh()
        $memoryStart = $process.PrivateMemorySize64
        for ($cycle = 0; $cycle -lt 8; $cycle++) {
            foreach ($page in @('Optimize','Diagnostics')) {
                $action = Element-WithName $window $page $button
                $action.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                $name = if ($page -eq 'Optimize') { 'Optimize now' } else { 'Capture baseline' }
                $null = Await { Element-WithName $window $name $button } "$page repeat navigation"
            }
        }
        $process.Refresh()
        Write-Host "MEMORY: private bytes $memoryStart to $($process.PrivateMemorySize64) after 16 additional page loads"
    }
} finally {
    if (!$process.HasExited) {
        $null = $process.CloseMainWindow()
        if (!$process.WaitForExit(5000)) { $process.Kill() }
    }
    $process.Dispose()
    if ($prefsTestStarted) {
        if ($hadPreferences) { [IO.File]::WriteAllBytes($prefsPath,$oldPreferences) }
        elseif ([IO.File]::Exists($prefsPath)) { [IO.File]::Delete($prefsPath) }
    }
}

