# Renews the stored Claude sign-in by briefly starting the real Claude Code CLI, the same thing
# you do by hand when you run `claude` and exit. No model prompt is ever sent.
#
# Rules (see docs/TRAY.md):
#  - Only when the stored sign-in has already expired. Never while it is valid.
#  - Automatic: also needs Claude activity AFTER the expiry. Manual (Refresh now): expiry alone.
#  - One attempt at a time. Failure cooldown. Three failures in a row stop automatic attempts
#    for this tray session (no permanent flag).
#  - Reads only the expiresAt number from .credentials.json; never logs or outputs a token.
#  - ~/.claude.json is only checked for valid JSON before and after. It is never edited or repaired.

function New-ClaudeRefreshContext {
    param(
        [string]$ProjectRoot,
        [string]$ClaudeHome,
        [string]$ConfigFile,
        [string]$Exe,
        [string[]]$ExeArgs = @(),
        [string]$MutexName = 'Local\AIUsageTrackerClaudeRefresh',
        [int]$TimeoutSec = 30,
        [int]$ExitDelaySec = 6,
        [int]$CooldownSec = 1800,
        [int]$MaxFailures = 3,
        [string]$LogFile,
        [string]$Version
    )
    if (-not $ClaudeHome) { $ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' } }
    if (-not $ConfigFile) {
        # Same lookup as the tracker (server/claude/paths.ts).
        $inDir = Join-Path $ClaudeHome '.claude.json'
        $home_ = Join-Path $env:USERPROFILE '.claude.json'
        $ConfigFile = if ($env:CLAUDE_CONFIG_DIR -and (Test-Path $inDir)) { $inDir } elseif (Test-Path $home_) { $home_ } else { $inDir }
    }
    if (-not $LogFile -and $ProjectRoot) { $LogFile = Join-Path $ProjectRoot 'logs\ai-usage-tray.log' }
    [pscustomobject]@{
        ProjectRoot = $ProjectRoot
        ClaudeHome  = $ClaudeHome
        Credentials = Join-Path $ClaudeHome '.credentials.json'
        ConfigFile  = $ConfigFile
        Exe         = $Exe
        ExeArgs     = $ExeArgs
        MutexName   = $MutexName
        TimeoutSec  = $TimeoutSec
        ExitDelaySec = $ExitDelaySec
        CooldownSec = $CooldownSec
        MaxFailures = $MaxFailures
        LogFile     = $LogFile
        # Mutable session state. Not persisted: a tray restart starts fresh.
        State       = @{ Running = $false; Failures = 0; CooldownUntil = 0; Disabled = $false; Note = $null; Version = $Version }
    }
}

function Write-RefreshLog {
    param($Ctx, [string]$Message)
    if (-not $Ctx.LogFile) { return }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $Ctx.LogFile) | Out-Null
        Add-Content -Path $Ctx.LogFile -Value ("{0} claude-refresh: {1}" -f (Get-Date -Format 's'), $Message)
    } catch { }
}

# Unix seconds of the stored sign-in's expiry, or $null. Only the number is extracted.
function Get-ClaudeCredentialExpiry {
    param($Ctx)
    if (-not (Test-Path $Ctx.Credentials)) { return $null }
    try {
        $m = [regex]::Match((Get-Content $Ctx.Credentials -Raw), '"expiresAt"\s*:\s*(\d+)')
        if (-not $m.Success) { return $null }
        $v = [double]$m.Groups[1].Value
        if ($v -gt 10000000000) { $v = [math]::Round($v / 1000) }
        return $v
    } catch { return $null }
}

# Read-only check that Claude's config file exists and parses. Nothing is written or repaired.
function Test-ClaudeConfigJson {
    param($Ctx)
    if (-not (Test-Path $Ctx.ConfigFile)) { return $false }
    try { $null = Get-Content $Ctx.ConfigFile -Raw | ConvertFrom-Json; return $true } catch { return $false }
}

# Any Claude thread (from the tracker's own index) updated after the expiry?
function Test-ClaudeActivityAfter {
    param($Overview, [double]$Expiry)
    if ($null -eq $Overview -or $null -eq $Overview.threads) { return $false }
    foreach ($t in @($Overview.threads)) {
        if ($null -ne $t.updatedAt -and [double]$t.updatedAt -gt $Expiry) { return $true }
    }
    return $false
}

# Should a refresh run now? Pure decision; starts nothing.
function Get-ClaudeRefreshDecision {
    param($Ctx, $Overview, [double]$Now, [switch]$Manual)
    $expiry = Get-ClaudeCredentialExpiry $Ctx
    if ($null -eq $expiry) { return [pscustomobject]@{ Go = $false; Reason = 'no-credentials' } }
    if ($expiry -gt $Now) { return [pscustomobject]@{ Go = $false; Reason = 'valid' } }
    if ($Ctx.State.Running) { return [pscustomobject]@{ Go = $false; Reason = 'busy' } }
    if ($Manual) { return [pscustomobject]@{ Go = $true; Reason = 'manual' } }
    if ($Ctx.State.Disabled) { return [pscustomobject]@{ Go = $false; Reason = 'disabled' } }
    if ($Now -lt $Ctx.State.CooldownUntil) { return [pscustomobject]@{ Go = $false; Reason = 'cooldown' } }
    if (-not (Test-ClaudeActivityAfter $Overview $expiry)) { return [pscustomobject]@{ Go = $false; Reason = 'no-activity' } }
    [pscustomobject]@{ Go = $true; Reason = 'auto' }
}

function Get-ClaudeVersion {
    param($Ctx)
    if ($Ctx.State.Version) { return $Ctx.State.Version }
    $v = 'unknown'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo $Ctx.Exe, '--version'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
        $pr = [System.Diagnostics.Process]::Start($psi)
        if ($pr.WaitForExit(5000)) { $v = $pr.StandardOutput.ReadToEnd().Trim() } else { $pr.Kill() }
    } catch { }
    $Ctx.State.Version = $v
    $v
}

function Set-RefreshFailure {
    param($Ctx, [string]$Reason, [double]$Now)
    $Ctx.State.Failures++
    $Ctx.State.CooldownUntil = $Now + $Ctx.CooldownSec
    if ($Ctx.State.Failures -ge $Ctx.MaxFailures) {
        $Ctx.State.Disabled = $true
        $Ctx.State.Note = "Sign-in refresh failed $($Ctx.State.Failures) times ($Reason). Automatic refresh is paused until the tray restarts."
    } else {
        $retry = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Ctx.State.CooldownUntil).LocalDateTime.ToString('HH:mm')
        $Ctx.State.Note = "Sign-in refresh failed ($Reason). Next automatic try after $retry."
    }
}

# Types "/exit" + Enter into the console of the process we started, via a short-lived hidden helper
# (so this long-running process never detaches from its own console). Returns $null on success or an error text.
function Send-ClaudeExit {
    param([int]$ProcessId, [scriptblock]$Pump)
    $helper = Join-Path $PSScriptRoot 'send-keys.ps1'
    $h = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helper`"", '-ProcessId', $ProcessId, '-Text', '/exit')
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not $h.HasExited -and $deadline.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200; if ($Pump) { & $Pump } }
    if (-not $h.HasExited) { & taskkill /T /F /PID $h.Id 2>&1 | Out-Null; return 'key helper timed out' }
    if ($h.ExitCode -ne 0) { return "key helper failed ($($h.ExitCode))" }
    $null
}
# Runs one refresh attempt. Returns { Attempted, Success, Reason, ... }.
# $Pump (optional scriptblock) is called while waiting so a UI stays responsive.
function Invoke-ClaudeRefresh {
    param($Ctx, [string]$Trigger = 'auto', [scriptblock]$Pump)
    $nowUnix = { [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    $result = [ordered]@{ Attempted = $false; Success = $false; Reason = ''; OldExpiry = $null; NewExpiry = $null; ExitCode = $null; Seconds = 0 }

    # Single flight: this tray (flag) and any other process (named mutex).
    if ($Ctx.State.Running) { $result.Reason = 'busy'; return [pscustomobject]$result }
    $mutex = New-Object System.Threading.Mutex($false, $Ctx.MutexName)
    $held = $false
    try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { $mutex.Dispose(); $result.Reason = 'busy'; return [pscustomobject]$result }
    $Ctx.State.Running = $true

    $started = $null
    try {
        $old = Get-ClaudeCredentialExpiry $Ctx
        $result.OldExpiry = $old
        # Never refresh a sign-in that is still valid, whoever asked.
        if ($null -eq $old) { $result.Reason = 'no-credentials'; return [pscustomobject]$result }
        if ($old -gt (& $nowUnix)) { $result.Reason = 'valid'; return [pscustomobject]$result }

        $result.Attempted = $true
        $Ctx.State.Note = 'Refreshing Claude sign-in...'
        $clock = [Diagnostics.Stopwatch]::StartNew()

        # Fail closed: Claude's config must exist and parse before we start the CLI.
        if (-not (Test-ClaudeConfigJson $Ctx)) {
            $result.Reason = 'config-invalid-before'
        } elseif (-not $Ctx.Exe -or -not (Test-Path $Ctx.Exe)) {
            $result.Reason = 'claude-not-found'
        } else {
            $version = Get-ClaudeVersion $Ctx
            # The child must use the stored sign-in (no host-session variables) and skip prompt history.
            # Both changes are made only around the launch and then undone; the tray's own environment is unchanged.
            $savedEnv = @{}
            Get-ChildItem Env: | Where-Object { $_.Name -match '^(CLAUDE|ANTHROPIC)' } | ForEach-Object { $savedEnv[$_.Name] = $_.Value }
            $savedEnv['CLAUDE_CODE_SKIP_PROMPT_HISTORY'] = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_SKIP_PROMPT_HISTORY', 'Process')
            try {
                foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
                [Environment]::SetEnvironmentVariable('CLAUDE_CODE_SKIP_PROMPT_HISTORY', '1', 'Process')
                $startArgs = @{ FilePath = $Ctx.Exe; WorkingDirectory = $Ctx.ProjectRoot; WindowStyle = 'Hidden'; PassThru = $true }
                if ($Ctx.ExeArgs.Count -gt 0) { $startArgs.ArgumentList = $Ctx.ExeArgs }
                $started = Start-Process @startArgs
            } finally {
                foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process') }
            }

            $wait = {
                param([double]$Seconds)
                $until = $clock.Elapsed.TotalSeconds + $Seconds
                while ($clock.Elapsed.TotalSeconds -lt $until -and -not $started.HasExited) { Start-Sleep -Milliseconds 200; if ($Pump) { & $Pump } }
            }
            & $wait $Ctx.ExitDelaySec
            if ($started.HasExited) {
                $result.Reason = 'exited-early'
            } else {
                $typeError = Send-ClaudeExit -ProcessId $started.Id -Pump $Pump
                if ($typeError) { $result.Reason = 'keys-failed' }
                else {
                    & $wait ([math]::Max(0, $Ctx.TimeoutSec - $clock.Elapsed.TotalSeconds))
                    if (-not $started.HasExited) { $result.Reason = 'timeout' }
                }
            }
            if ($result.Reason -eq 'timeout' -or $result.Reason -eq 'keys-failed') {
                # Only the process (tree) this function started.
                & taskkill /T /F /PID $started.Id 2>&1 | Out-Null
            }
            $started.Refresh()
            if ($started.HasExited) { $result.ExitCode = $started.ExitCode }
        }
        $clock.Stop(); $result.Seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)

        $new = Get-ClaudeCredentialExpiry $Ctx
        $result.NewExpiry = $new
        if (-not $result.Reason) {
            if (-not (Test-ClaudeConfigJson $Ctx)) { $result.Reason = 'config-invalid-after' }
            elseif ($null -ne $new -and $new -gt $old -and $new -gt (& $nowUnix)) { $result.Success = $true; $result.Reason = 'ok' }
            else { $result.Reason = 'no-extension' }
        } elseif ($result.Reason -ne 'config-invalid-before' -and -not (Test-ClaudeConfigJson $Ctx)) {
            $result.Reason = $result.Reason + '+config-invalid-after'
        }

        $fmt = { param($v) if ($null -eq $v) { 'n/a' } else { [DateTimeOffset]::FromUnixTimeSeconds([int64]$v).LocalDateTime.ToString('s') } }
        Write-RefreshLog $Ctx ("trigger=$Trigger success=$($result.Success) reason=$($result.Reason) exit=$($result.ExitCode) seconds=$($result.Seconds) oldExpiry=$(& $fmt $old) newExpiry=$(& $fmt $new) claude=$($Ctx.State.Version)")

        if ($result.Success) {
            $Ctx.State.Failures = 0; $Ctx.State.CooldownUntil = 0; $Ctx.State.Disabled = $false; $Ctx.State.Note = $null
        } else {
            Set-RefreshFailure $Ctx $result.Reason (& $nowUnix)
        }
        return [pscustomobject]$result
    } finally {
        $Ctx.State.Running = $false
        if ($Ctx.State.Note -eq 'Refreshing Claude sign-in...') { $Ctx.State.Note = $null }
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
        # Last line of defence: never leave a process this function started behind.
        if ($started -and -not $started.HasExited) { & taskkill /T /F /PID $started.Id 2>&1 | Out-Null }
    }
}

# Decide, refresh if warranted, then ask the tracker to re-fetch Claude usage right away.
# Returns the refresh result, or $null when nothing was attempted (see Decision on the object).
function Invoke-ClaudeRefreshFlow {
    param($Ctx, [string]$ApiBase, $Overview, [double]$Now, [switch]$Manual, [scriptblock]$Pump)
    $decision = Get-ClaudeRefreshDecision -Ctx $Ctx -Overview $Overview -Now $Now -Manual:$Manual
    if (-not $decision.Go) { return $null }
    $result = Invoke-ClaudeRefresh -Ctx $Ctx -Trigger $decision.Reason -Pump $Pump
    if ($result.Success -and $ApiBase) {
        try { Invoke-RestMethod -Method Post -Uri "$ApiBase/api/refresh?provider=claude" -TimeoutSec 60 -ErrorAction Stop | Out-Null } catch { Write-RefreshLog $Ctx "usage refresh after sign-in failed: $($_.Exception.Message)" }
    }
    $result
}
