param([string]$Dotnet = 'dotnet',[switch]$BatchOnly,[string]$ReleaseDirectory)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$release = if ($ReleaseDirectory) { [IO.Path]::GetFullPath($ReleaseDirectory) } else { Join-Path $root 'release' }
$null = New-Item -ItemType Directory -Path $release -Force
$utf8 = New-Object Text.UTF8Encoding($false)
$header = @'
@echo off
setlocal DisableDelayedExpansion
set "LARP_BATCH_FILE=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$lines=[IO.File]::ReadAllLines($env:LARP_BATCH_FILE,[Text.Encoding]::UTF8); $marker=[Array]::IndexOf($lines,'# LARP_POWERSHELL_PAYLOAD'); if ($marker -lt 0) { exit 2 }; & ([scriptblock]::Create(($lines[($marker+1)..($lines.Length-1)] -join [Environment]::NewLine)))"
exit /b %errorlevel%
# LARP_POWERSHELL_PAYLOAD
'@
$engine = [IO.File]::ReadAllText((Join-Path $root 'src\LarpOptimizer.Engine\Engine.ps1'),$utf8)
$terminal = [IO.File]::ReadAllText((Join-Path $root 'src\LarpOptimizer.Engine\Terminal.ps1'),$utf8)
$nl = [Environment]::NewLine
$batch = @($header,$engine,$terminal,'Terminal','') -join $nl
$batch = $batch -replace '\r?\n',$nl
$batchFile = Join-Path $root 'batch\LARP Optimizer.bat'
[IO.File]::WriteAllText($batchFile,$batch,$utf8)
Copy-Item -LiteralPath $batchFile -Destination $release -Force
if (!$BatchOnly) {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    $project = Join-Path $root 'src\LarpOptimizer.App\LarpOptimizer.App.csproj'
    $stage = Join-Path $root 'artifacts\publish-win-x64'
    $options = @('-p:PublishSingleFile=true','-p:IncludeNativeLibrariesForSelfExtract=true','-p:EnableCompressionInSingleFile=true','-p:PublishTrimmed=false','-p:DebugType=None','-p:DebugSymbols=false')
    & $Dotnet publish $project -c Release -r win-x64 --self-contained -o $stage @options
    if ($LASTEXITCODE -ne 0) { throw ".NET publish failed ($LASTEXITCODE)." }
    $exe = Join-Path $stage 'LARP Optimizer.exe'
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Publish did not create the expected EXE.' }
    Copy-Item -LiteralPath $exe -Destination $release -Force
    $checksums = foreach ($name in @('LARP Optimizer.exe','LARP Optimizer.bat')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $release $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [IO.File]::WriteAllLines((Join-Path $release 'SHA256SUMS.txt'),[string[]]$checksums,$utf8)
}
