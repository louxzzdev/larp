param([string]$Batch,[switch]$NetworkTuning)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
if (!$Batch) { $Batch = Join-Path (Split-Path $PSScriptRoot -Parent) 'release\LARP Optimizer.bat' }
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
$start.Arguments = '/d /s /c ""' + $Batch + '""'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.Encoding]::UTF8
$start.StandardErrorEncoding = [Text.Encoding]::UTF8
$process = [Diagnostics.Process]::Start($start)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $inputLines = @('1','','2','','Safe','','6','1','127.0.0.1','2','500','')
    if ($NetworkTuning) { $inputLines += @('6','9','127.0.0.1','::1','2','500','') }
    foreach ($line in ($inputLines + '0')) {
        $process.StandardInput.WriteLine($line)
    }
    $process.StandardInput.Close()
    if (!$process.WaitForExit(45000)) { throw 'BAT smoke test timed out.' }
    $log = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or $errors) { throw "BAT failed: $errors $log" }
    foreach ($expected in @('LARP OPTIMIZER','"NumberOfLogicalProcessors"','No applicable changes','"Destination":  "127.0.0.1"','"LossPercent":  0')) {
        if (!$log.Contains($expected)) {
            throw "Missing BAT result $expected. Output: $log"
        }
    }
    Write-Host 'PASS: standalone BAT from CMD, real dashboard, Safe review, and loopback ping'
    if ($NetworkTuning) {
        if (!$log.Contains('"LowerMedianWithoutLoss"') -or !$log.Contains('"Destination":  "::1"')) { throw "BAT endpoint comparison missing. $log" }
        Write-Host 'PASS: standalone BAT compares IPv4 and IPv6 loopback endpoints'
    }
} finally {
    if (!$process.HasExited) { $process.Kill() }
    $process.Dispose()
}

