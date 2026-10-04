# Tests for the tray's presentation logic against a fake tracker API.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tray\tests.ps1
# Needs Node (already required by the project). Does not touch the real tracker.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TrayLogic.ps1')

$script:failed = 0
$script:passed = 0
function Check([string]$name, [bool]$condition) {
    if ($condition) { $script:passed++; Write-Host "  ok   $name" }
    else { $script:failed++; Write-Host "  FAIL $name" -ForegroundColor Red }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("tray-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$scenarioFile = Join-Path $work 'scenario.json'
$port = Get-Random -Minimum 20000 -Maximum 40000
$api = "http://127.0.0.1:$port"
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function Window($used, $resetsInSeconds, $observedAgoSeconds = 30) {
    @{ usedPercent = $used; resetsAt = $now + $resetsInSeconds; observedAt = $now - $observedAgoSeconds }
}
function Overview($five, $seven) { @{ limits = @{ fiveHour = $five; sevenDay = $seven; other = @() } } }
function Health($codexOk, $claudeOk, $claudeError = $null, $codexError = $null) {
    @{ ok = $true; providers = @{
        codex  = @{ enabled = $true; connected = $codexOk; error = $codexError }
        claude = @{ enabled = $true; connected = $claudeOk; error = $claudeError } } }
}
function Set-Scenario($scenario) { $scenario | ConvertTo-Json -Depth 8 | Set-Content $scenarioFile -Encoding ascii }
function Get-View { Get-TrayView -Data (Get-TrayData -ApiBase $api -TimeoutSec 3) -Now ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -LastValid $script:lastValid }
function Provider($view, $name) { $view.Providers | Where-Object Name -eq $name }

$healthy = @{
    health   = Health $true $true
    overview = @{ codex = Overview (Window 0 18000) (Window 7 500000); claude = Overview (Window 19 15000) (Window 32 480000) }
}
Set-Scenario $healthy
$script:lastValid = @{}
$server = Start-Process node -ArgumentList "`"$(Join-Path $PSScriptRoot 'fake-backend.mjs')`"", $port, "`"$scenarioFile`"" -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 800

try {
    Write-Host 'Formatting'
    Check 'countdown days+hours' ((Format-Countdown (2 * 86400 + 4 * 3600 + 120)) -eq '2d 4h')
    Check 'countdown hours+minutes' ((Format-Countdown (3600 + 32 * 60)) -eq '1h 32m')
    Check 'countdown minutes' ((Format-Countdown 720) -eq '12m')
    Check 'countdown under a minute' ((Format-Countdown 20) -eq '<1m')
    Check 'level normal above 30' ((Get-Level 31) -eq 'normal')
    Check 'level warning at 30' ((Get-Level 30) -eq 'warning')
    Check 'level warning at 10' ((Get-Level 10) -eq 'warning')
    Check 'level critical below 10' ((Get-Level 9) -eq 'critical')
    Check 'level unknown without data' ((Get-Level $null) -eq 'unknown')

    Write-Host 'Codex and Claude both have data'
    $v = Get-View
    $codex = Provider $v 'codex'; $claude = Provider $v 'claude'
    Check 'reachable' $v.Reachable
    Check 'codex 5-hour remaining 100' ($codex.Rows[0].State -eq 'Ok' -and $codex.Rows[0].Remaining -eq 100)
    Check 'codex 7-day remaining 93' ($codex.Rows[1].Remaining -eq 93)
    Check 'claude 5-hour remaining 81' ($claude.Rows[0].Remaining -eq 81)
    Check 'claude 7-day remaining 68' ($claude.Rows[1].Remaining -eq 68)
    Check 'reset text present' ($claude.Rows[0].ResetsIn -match '^\d+h \d+m$' -and $claude.Rows[1].ResetsIn -match '^\d+d \d+h$')
    Check 'level uses lowest remaining (68 -> normal)' ($v.Level -eq 'normal' -and $v.Minimum -eq 68)
    Check 'no auth hint when healthy' (-not $claude.AuthHint)
    Check 'text shows all four rows' (([regex]::Matches($v.Text, 'remaining')).Count -eq 4)

    Write-Host 'Codex unavailable'
    Set-Scenario @{ health = Health $false $true $null 'codex app-server exited (1)'; overview = @{ codex = Overview $null $null; claude = $healthy.overview.claude } }
    $v = Get-View
    $codex = Provider $v 'codex'; $claude = Provider $v 'claude'
    Check 'codex rows Unavailable' (@($codex.Rows | Where-Object State -eq 'Unavailable').Count -eq 2)
    Check 'codex shows no fake 0%' ($null -eq $codex.Rows[0].Remaining -and $v.Text -notmatch 'Codex\s+5-hour\s+0%')
    Check 'claude still Ok' ($claude.Rows[0].State -eq 'Ok')
    Check 'level from claude only' ($v.Minimum -eq 68)

    Write-Host 'Claude unavailable (expired sign-in, old data)'
    $stale = Overview (Window 19 15000 90000) (Window 32 480000 90000)
    Set-Scenario @{ health = Health $true $false 'Claude Code sign-in token has expired. Open Claude Code to refresh it.'; overview = @{ codex = $healthy.overview.codex; claude = $stale } }
    $v = Get-View
    $claude = Provider $v 'claude'
    Check 'claude rows Stale, not Ok' (@($claude.Rows | Where-Object State -eq 'Stale').Count -eq 2)
    Check 'stale rows carry no remaining number' ($null -eq $claude.Rows[0].Remaining)
    Check 'stale rows show last valid update' ($v.Text -match 'Stale\s+.\s+last valid update \d\d-\d\d \d\d:\d\d')
    Check 'auth hint shown' ($claude.AuthHint -eq 'Run Claude CLI once to refresh authentication.' -and $v.Text -match 'Run Claude CLI once')
    Check 'level ignores stale claude (codex 93 -> normal)' ($v.Minimum -eq 93)

    Write-Host 'Stale rules while connected'
    Set-Scenario @{ health = Health $true $true; overview = @{ codex = Overview (Window 0 18000 3600) (Window 7 500000); claude = Overview (Window 19 -60) (Window 32 480000) } }
    $v = Get-View
    Check 'observedAt too old -> Stale' ((Provider $v 'codex').Rows[0].State -eq 'Stale')
    Check 'window already reset -> Stale' ((Provider $v 'claude').Rows[0].State -eq 'Stale')
    Check 'fresh sibling window still Ok' ((Provider $v 'codex').Rows[1].State -eq 'Ok')
    Check 'no auth hint for non-auth staleness' (-not (Provider $v 'claude').AuthHint)

    Write-Host 'Critical and warning levels'
    Set-Scenario @{ health = Health $true $true; overview = @{ codex = Overview (Window 95 18000) (Window 7 500000); claude = Overview (Window 19 15000) (Window 32 480000) } }
    $v = Get-View
    Check 'critical when a window has <10% left' ($v.Level -eq 'critical' -and $v.Minimum -eq 5)
    Set-Scenario @{ health = Health $true $true; overview = @{ codex = Overview (Window 80 18000) (Window 7 500000); claude = Overview (Window 19 15000) (Window 32 480000) } }
    Check 'warning at 20% left' ((Get-View).Level -eq 'warning')

    Write-Host 'Manual refresh'
    Set-Scenario $healthy
    Invoke-TrayRefresh -ApiBase $api
    $posts = Get-Content "$scenarioFile.posts"
    Check 'refresh calls POST for codex' ($posts -contains '/api/refresh?provider=codex')
    Check 'refresh calls POST for claude' ($posts -contains '/api/refresh?provider=claude')
    $before = @(Get-Content "$scenarioFile.posts").Count
    $null = Get-View
    Check 'plain read does not trigger refresh' (@(Get-Content "$scenarioFile.posts").Count -eq $before)

    Write-Host 'Backend not ready / restart'
    $script:lastValid = @{}
    $v = Get-View
    Check 'valid data remembered while up' ($script:lastValid.Count -eq 4)
    Stop-Process -Id $server.Id -Force
    Start-Sleep -Milliseconds 500
    $v = Get-View
    Check 'unreachable detected' (-not $v.Reachable)
    Check 'all rows Unavailable when backend down' (@($v.Providers | ForEach-Object Rows | Where-Object State -eq 'Unavailable').Count -eq 4)
    Check 'unavailable rows show last valid update' ($v.Text -match 'Unavailable\s+.\s+last valid update')
    Check 'level unknown when backend down' ($v.Level -eq 'unknown' -and $null -eq $v.Minimum)
    Check 'no remaining % shown when backend down' ($v.Text -notmatch '%\s+remaining')
    $server = Start-Process node -ArgumentList "`"$(Join-Path $PSScriptRoot 'fake-backend.mjs')`"", $port, "`"$scenarioFile`"" -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    $v = Get-View
    Check 'recovers after backend restart' ($v.Reachable -and (Provider $v 'claude').Rows[0].State -eq 'Ok')

    Write-Host 'Endpoint configuration'
    $root = Join-Path $work 'proj'; New-Item -ItemType Directory $root | Out-Null
    Set-Content (Join-Path $root '.env') "PORT=9123`nHOST=127.0.0.1" -Encoding ascii
    $e = Get-TrayEndpoint -ProjectRoot $root
    Check 'port read from .env' ($e.Port -eq 9123 -and $e.Dashboard -eq 'http://localhost:9123')
    Check 'default port without .env' ((Get-TrayEndpoint -ProjectRoot (Join-Path $work 'none')).Port -eq 8893)
}
finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
