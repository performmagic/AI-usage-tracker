param([switch]$NoTray)

$ErrorActionPreference = "Stop"

$projectPath = Split-Path -Parent $PSScriptRoot
Set-Location $projectPath

$logDirectory = Join-Path $projectPath "logs"
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

$stdoutLog = Join-Path $logDirectory "ai-usage-tracker.log"
$stderrLog = Join-Path $logDirectory "ai-usage-tracker-error.log"

$port = 8893
$configuredCodex = $env:CODEX_BIN
$envFile = Join-Path $projectPath ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*PORT\s*=\s*(\d+)\s*$') { $port = [int]$Matches[1] }
        if ($line -match '^\s*CODEX_BIN\s*=\s*(.+?)\s*$' -and -not $configuredCodex) { $configuredCodex = $Matches[1].Trim('"') }
    }
}

# True when the file exists and `--version` exits cleanly within a few seconds.
function Test-CodexExecutable([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo $path, "--version"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $probe = [System.Diagnostics.Process]::Start($psi)
        if (-not $probe.WaitForExit(15000)) { $probe.Kill(); return $false }
        return ($probe.ExitCode -eq 0)
    } catch { return $false }
}

# Find a working Codex CLI. The Codex desktop app keeps it in a version-named
# folder that changes on update and is not on PATH, so look there as a fallback.
# Order: CODEX_BIN (environment or .env), PATH, the desktop app's bin folder.
function Resolve-CodexBinary {
    if ($configuredCodex -and (Test-CodexExecutable $configuredCodex)) { return $null }  # already valid; leave it alone
    $candidates = @()
    foreach ($name in "codex.exe", "codex.cmd") {
        $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $candidates += $found.Source }
    }
    $appBin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    if (Test-Path $appBin) {
        $candidates += Get-ChildItem -Path $appBin -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName "codex.exe") -ErrorAction SilentlyContinue } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $_.FullName }
    }
    foreach ($candidate in $candidates) {
        if (Test-CodexExecutable $candidate) { return $candidate }
    }
    Add-Content -Path (Join-Path $logDirectory "ai-usage-tracker-error.log") -Value ("{0} Codex CLI not found: CODEX_BIN is not set to a working executable, and none was found on PATH or in the Codex desktop app folder. Codex quota will show as disconnected." -f (Get-Date -Format s))
    return $null
}

$resolvedCodex = Resolve-CodexBinary
if ($resolvedCodex) {
    # Quoted so a path with spaces survives the shell the tracker launches it through.
    $env:CODEX_BIN = if ($resolvedCodex -match '\s') { "`"$resolvedCodex`"" } else { $resolvedCodex }
}

# Replace any tracker already serving this port. An instance started from an
# agent's sandboxed shell keeps the port but cannot launch codex app-server, so
# running this script (or the scheduled task) must take over rather than bail.
$listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
foreach ($processId in @($listeners | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique)) {
    $existing = Get-CimInstance Win32_Process -Filter "ProcessId=$processId"
    if ($existing -and $existing.CommandLine -match 'dist-server[\\/]index\.js') {
        Stop-Process -Id $processId -Force
        Wait-Process -Id $processId -Timeout 10 -ErrorAction SilentlyContinue
    }
}

Start-Process `
    -FilePath "node.exe" `
    -ArgumentList "dist-server/index.js" `
    -WorkingDirectory $projectPath `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog

# The tray reads this tracker's local API. It keeps running across tracker
# restarts and exits on its own if one is already running.
if (-not $NoTray) {
    $trayScript = Join-Path $projectPath "scripts\tray\ai-usage-tray.ps1"
    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-Sta", "-File", "`"$trayScript`"" `
        -WindowStyle Hidden
}
