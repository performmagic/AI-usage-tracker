# Tests for the Claude sign-in refresh (ClaudeRefresh.ps1) against a fake Claude CLI and a fake tracker API.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tray\tests-refresh.ps1
# Needs Node. Never starts the real claude, never touches your real ~/.claude or the real tracker.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeRefresh.ps1')

$script:failed = 0; $script:passed = 0
function Check([string]$name, [bool]$condition) {
    if ($condition) { $script:passed++; Write-Host "  ok   $name" }
    else { $script:failed++; Write-Host "  FAIL $name" -ForegroundColor Red }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("claude-refresh-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$env:FAKE_CLAUDE_DIR = $work
$env:CLAUDE_TEST_DUMMY = 'host-session-value'   # must NOT reach the child, and must be restored afterwards
$node = (Get-Command node).Source
$fakeScript = Join-Path $PSScriptRoot 'fake-claude.mjs'
$mutexName = 'Local\AIUsageTrackerClaudeRefreshTest-' + [guid]::NewGuid().ToString('N')
$startsLog = Join-Path $work 'starts.log'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function New-Ctx([int]$Cooldown = 1800, [int]$Timeout = 20, [int]$Delay = 1) {
    New-ClaudeRefreshContext -ProjectRoot $work -ClaudeHome $work -ConfigFile (Join-Path $work '.claude.json') `
        -Exe $node -ExeArgs @("`"$fakeScript`"") -MutexName $mutexName -TimeoutSec $Timeout -ExitDelaySec $Delay `
        -CooldownSec $Cooldown -LogFile (Join-Path $work 'log.txt') -Version 'fake-1.0'
}
function Set-Creds([double]$ExpiresInSeconds) {
    $ms = [int64](([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $ExpiresInSeconds) * 1000)
    Set-Content (Join-Path $work '.credentials.json') ('{"claudeAiOauth":{"accessToken":"FAKE-TEST-TOKEN","expiresAt":' + $ms + '}}') -Encoding ascii
}
function Set-Mode([string]$Mode) { Set-Content (Join-Path $work 'mode.txt') $Mode -Encoding ascii }
function Reset-Config { Set-Content (Join-Path $work '.claude.json') '{}' -Encoding ascii }
function Get-Starts { if (Test-Path $startsLog) { @(Get-Content $startsLog).Count } else { 0 } }
function Get-Overview([double]$ThreadUpdatedAt) { [pscustomobject]@{ threads = @([pscustomobject]@{ updatedAt = $ThreadUpdatedAt }) } }
function Get-Expiry { Get-ClaudeCredentialExpiry (New-Ctx) }

Reset-Config; Set-Mode 'refresh'

# Fake tracker API, to see the usage refresh that follows a successful sign-in refresh.
$scenarioFile = Join-Path $work 'scenario.json'
'{"health":{"ok":true,"providers":{}},"overview":{}}' | Set-Content $scenarioFile -Encoding ascii
$port = Get-Random -Minimum 20000 -Maximum 40000
$api = "http://127.0.0.1:$port"
$server = Start-Process node -ArgumentList "`"$(Join-Path $PSScriptRoot 'fake-backend.mjs')`"", $port, "`"$scenarioFile`"" -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 800

try {
    Write-Host '1. credential valid -> Claude is not started'
    Set-Creds 3600
    $ctx = New-Ctx
    $exp = Get-Expiry
    Check 'auto decision: valid' ((Get-ClaudeRefreshDecision $ctx (Get-Overview ($exp + 100)) $now).Reason -eq 'valid')
    Check 'manual decision: valid' ((Get-ClaudeRefreshDecision $ctx $null $now -Manual).Reason -eq 'valid')
    Check 'auto flow does nothing' ($null -eq (Invoke-ClaudeRefreshFlow -Ctx $ctx -ApiBase $api -Overview (Get-Overview ($exp + 100)) -Now $now))
    Check 'manual flow does nothing' ($null -eq (Invoke-ClaudeRefreshFlow -Ctx $ctx -ApiBase $api -Overview $null -Now $now -Manual))
    $direct = Invoke-ClaudeRefresh -Ctx $ctx -Trigger 'manual'
    Check 'direct call refuses a valid sign-in' (-not $direct.Attempted -and $direct.Reason -eq 'valid')
    Check 'Claude never started' ((Get-Starts) -eq 0)

    Write-Host '2. expired, no new activity -> not started'
    Set-Creds -600
    $ctx = New-Ctx
    $exp = Get-Expiry
    Check 'decision: no-activity (thread older than expiry)' ((Get-ClaudeRefreshDecision $ctx (Get-Overview ($exp - 50)) ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())).Reason -eq 'no-activity')
    Check 'decision: no-activity (no threads)' ((Get-ClaudeRefreshDecision $ctx ([pscustomobject]@{ threads = @() }) ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())).Reason -eq 'no-activity')
    Check 'flow does nothing' ($null -eq (Invoke-ClaudeRefreshFlow -Ctx $ctx -ApiBase $api -Overview (Get-Overview ($exp - 50)) -Now ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())))
    Check 'Claude never started' ((Get-Starts) -eq 0)

    Write-Host '3 + 10. expired + new activity -> refresh, then usage re-read'
    Set-Creds -600; Reset-Config; Set-Mode 'refresh'
    $ctx = New-Ctx
    $exp = Get-Expiry
    $nowU = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Check 'decision: auto go' ((Get-ClaudeRefreshDecision $ctx (Get-Overview ($exp + 30)) $nowU).Reason -eq 'auto')
    $r = Invoke-ClaudeRefreshFlow -Ctx $ctx -ApiBase $api -Overview (Get-Overview ($exp + 30)) -Now $nowU
    Check 'attempted and succeeded' ($r.Attempted -and $r.Success -and $r.Reason -eq 'ok')
    Check 'new expiry later than old and in the future' ($r.NewExpiry -gt $r.OldExpiry -and $r.NewExpiry -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Check 'exactly one Claude start' ((Get-Starts) -eq 1)
    Check 'exit code 0 recorded' ($r.ExitCode -eq 0)
    Check 'usage refresh requested right after (POST claude)' ((Test-Path "$scenarioFile.posts") -and ((Get-Content "$scenarioFile.posts") -contains '/api/refresh?provider=claude'))
    Check 'state reset after success' ($ctx.State.Failures -eq 0 -and -not $ctx.State.Note -and -not $ctx.State.Running)
    Check 'refresh log has duration/exit/expiry/version and no token' ((Get-Content (Join-Path $work 'log.txt') -Raw) -match 'seconds=.*exit=0|exit=0.*seconds=' -and (Get-Content (Join-Path $work 'log.txt') -Raw) -match 'claude=fake-1.0' -and (Get-Content (Join-Path $work 'log.txt') -Raw) -notmatch 'FAKE-TEST-TOKEN')

    Write-Host '9. child environment, working directory, and no history/transcripts'
    $line = @(Get-Content $startsLog)[-1]
    Check 'child had CLAUDE_CODE_SKIP_PROMPT_HISTORY=1' ($line -match 'skipHistory=1 ')
    Check 'child had no other CLAUDE*/ANTHROPIC* variables' ($line -match 'otherClaudeVars=0 ')
    Check 'child ran in the project directory' ($line -like "*cwd=$work*")
    Check 'tray environment unchanged: history flag not left set' (-not $env:CLAUDE_CODE_SKIP_PROMPT_HISTORY)
    Check 'tray environment unchanged: host variable restored' ($env:CLAUDE_TEST_DUMMY -eq 'host-session-value')
    Check 'no history.jsonl or projects folder created' (-not (Test-Path (Join-Path $work 'history.jsonl')) -and -not (Test-Path (Join-Path $work 'projects')))

    Write-Host '4. expired + Refresh now (no activity) -> refresh'
    Set-Creds -600; Set-Mode 'refresh'
    $ctx = New-Ctx
    $before = Get-Starts
    $r = Invoke-ClaudeRefreshFlow -Ctx $ctx -ApiBase $null -Overview $null -Now ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Manual
    Check 'manual refresh succeeded' ($r.Attempted -and $r.Success)
    Check 'one more start' ((Get-Starts) -eq $before + 1)

    Write-Host '5. concurrent triggers -> single flight'
    Set-Creds -600; Set-Mode 'slow'
    $before = Get-Starts
    $jobScript = {
        param($logic, $work, $node, $fake, $mutex)
        . $logic
        $c = New-ClaudeRefreshContext -ProjectRoot $work -ClaudeHome $work -ConfigFile (Join-Path $work '.claude.json') -Exe $node -ExeArgs @("`"$fake`"") -MutexName $mutex -TimeoutSec 25 -ExitDelaySec 1 -LogFile (Join-Path $work 'log.txt') -Version 'fake-1.0'
        $x = Invoke-ClaudeRefresh -Ctx $c -Trigger 'manual'
        "$($x.Attempted)|$($x.Success)|$($x.Reason)"
    }
    $args5 = @((Join-Path $PSScriptRoot 'ClaudeRefresh.ps1'), $work, $node, $fakeScript, $mutexName)
    $j1 = Start-Job $jobScript -ArgumentList $args5
    Start-Sleep -Milliseconds 300
    $j2 = Start-Job $jobScript -ArgumentList $args5
    $out = @($j1, $j2 | Wait-Job -Timeout 60 | Receive-Job)
    Remove-Job $j1, $j2 -Force
    Check 'two callers returned' ($out.Count -eq 2)
    Check 'exactly one actually ran and succeeded' (@($out | ? { $_ -eq 'True|True|ok' }).Count -eq 1)
    Check 'the other was turned away as busy' (@($out | ? { $_ -eq 'False|False|busy' }).Count -eq 1)
    Check 'Claude started once, not twice' ((Get-Starts) -eq $before + 1)
    $ctx = New-Ctx; $ctx.State.Running = $true
    Check 'in-process re-entry is refused too' ((Invoke-ClaudeRefresh -Ctx $ctx).Reason -eq 'busy')

    Write-Host '6. CLI timeout -> cleanup + cooldown'
    Set-Creds -600; Set-Mode 'hang'; Reset-Config
    $ctx = New-Ctx -Timeout 4 -Delay 1
    $exp = Get-Expiry
    $r = Invoke-ClaudeRefresh -Ctx $ctx -Trigger 'auto'
    $fakePid = [int](@(Get-Content $startsLog)[-1] -replace '^pid=(\d+).*', '$1')
    Check 'reported as timeout / failure' ($r.Attempted -and -not $r.Success -and $r.Reason -eq 'timeout')
    Check 'hung process was killed' (-not (Get-Process -Id $fakePid -ErrorAction SilentlyContinue))
    Check 'finished close to the hard timeout' ($r.Seconds -lt 12)
    Check 'cooldown set (~30 min)' (($ctx.State.CooldownUntil - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -gt 1700)
    Check 'auto decision is now cooldown' ((Get-ClaudeRefreshDecision $ctx (Get-Overview ($exp + 100)) ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())).Reason -eq 'cooldown')
    Check 'failure note shown' ($ctx.State.Note -match 'failed.*timeout')
    Check 'manual still allowed during cooldown' ((Get-ClaudeRefreshDecision $ctx $null ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Manual).Reason -eq 'manual')

    Write-Host '7. exit 0 but expiry not extended -> failure'
    Set-Creds -600; Set-Mode 'noextend'
    $ctx = New-Ctx
    $r = Invoke-ClaudeRefresh -Ctx $ctx -Trigger 'auto'
    Check 'exit code 0' ($r.ExitCode -eq 0)
    Check 'judged a failure: no-extension' (-not $r.Success -and $r.Reason -eq 'no-extension')

    Write-Host '   three failures in a row stop automatic attempts (this session only)'
    Set-Creds -600; Set-Mode 'exit1'
    $ctx = New-Ctx -Cooldown 0
    $exp = Get-Expiry
    1..3 | % { $null = Invoke-ClaudeRefresh -Ctx $ctx -Trigger 'auto' }
    Check 'three failures counted' ($ctx.State.Failures -eq 3)
    Check 'automatic refresh disabled with a clear note' ($ctx.State.Disabled -and $ctx.State.Note -match 'paused until the tray restarts')
    Check 'auto decision: disabled' ((Get-ClaudeRefreshDecision $ctx (Get-Overview ($exp + 100)) ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())).Reason -eq 'disabled')
    Check 'manual recovery still allowed' ((Get-ClaudeRefreshDecision $ctx $null ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Manual).Reason -eq 'manual')
    $fresh = New-Ctx
    Check 'a new tray session starts fresh (not disabled)' (-not $fresh.State.Disabled -and $fresh.State.Failures -eq 0)
    Set-Mode 'refresh'
    $r = Invoke-ClaudeRefresh -Ctx $ctx -Trigger 'manual'
    Check 'a successful manual refresh clears the disabled state' ($r.Success -and -not $ctx.State.Disabled -and $ctx.State.Failures -eq 0)

    Write-Host '8. .claude.json invalid -> fail closed'
    Set-Creds -600; Set-Mode 'refresh'
    Set-Content (Join-Path $work '.claude.json') '{bad json' -Encoding ascii
    $before = Get-Starts
    $ctx = New-Ctx
    $r = Invoke-ClaudeRefresh -Ctx $ctx -Trigger 'manual'
    Check 'before: stopped, reason config-invalid-before' (-not $r.Success -and $r.Reason -eq 'config-invalid-before')
    Check 'before: Claude not started' ((Get-Starts) -eq $before)
    Check 'before: config file untouched (not repaired)' ((Get-Content (Join-Path $work '.claude.json') -Raw).Trim() -eq '{bad json')
    Check 'before: failure noted' ($ctx.State.Failures -eq 1 -and $ctx.State.Note -match 'config-invalid-before')
    Remove-Item (Join-Path $work '.claude.json') -Force
    Check 'missing config file also fails closed' ((Invoke-ClaudeRefresh -Ctx (New-Ctx) -Trigger 'manual').Reason -eq 'config-invalid-before')
    Reset-Config; Set-Creds -600; Set-Mode 'corrupt'
    $ctx = New-Ctx
    $r = Invoke-ClaudeRefresh -Ctx $ctx -Trigger 'manual'
    Check 'after: CLI broke the config -> failure config-invalid-after' (-not $r.Success -and $r.Reason -eq 'config-invalid-after')
    Check 'after: config left as the CLI wrote it (not repaired)' ((Get-Content (Join-Path $work '.claude.json') -Raw).Trim() -eq '{broken')
}
finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Get-Process node -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like '*fake-claude.mjs*' } catch { $false } } | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_DIR, Env:CLAUDE_TEST_DUMMY -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
