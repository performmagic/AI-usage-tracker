# Presentation logic for the AI Usage tray. No UI in this file so it can be tested.
# The tray only reads the tracker's local API; it never talks to Codex or Claude.

# Backend polls every 60 s (Codex) / 120 s (Claude); observedAt moves on every poll.
$script:StaleAfterSeconds = 600
$script:Dot = [string][char]0x00B7

function Get-TrayEndpoint {
    param([string]$ProjectRoot)
    $port = 8893
    $hostName = '127.0.0.1'
    if ($env:PORT -match '^\d+$') { $port = [int]$env:PORT }
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*PORT\s*=\s*(\d+)\s*$') { $port = [int]$Matches[1] }
            elseif ($line -match '^\s*HOST\s*=\s*([^\s#]+)\s*$' -and $Matches[1] -notin @('0.0.0.0', '::')) { $hostName = $Matches[1] }
        }
    }
    [pscustomobject]@{
        Api       = "http://${hostName}:$port"
        Dashboard = "http://localhost:$port"
        Port      = $port
    }
}

function Format-Countdown {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return '<1m' }
    $d = [math]::Floor($Seconds / 86400)
    $h = [math]::Floor(($Seconds % 86400) / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    if ($d -gt 0) { return "${d}d ${h}h" }
    if ($h -gt 0) { return "${h}h ${m}m" }
    return "${m}m"
}

function Format-ClockTime {
    param([double]$UnixSeconds)
    [DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixSeconds).LocalDateTime.ToString('MM-dd HH:mm')
}

function Get-Level {
    param([Nullable[int]]$Remaining)
    if ($null -eq $Remaining) { return 'unknown' }
    if ($Remaining -lt 10) { return 'critical' }
    if ($Remaining -le 30) { return 'warning' }
    return 'normal'
}

# One quota window -> what the tray may claim about it.
# State: Ok (fresh, current), Stale (a number exists but is not current), Unavailable (no number).
function Get-WindowView {
    param(
        $Window,
        [string]$Label,
        [bool]$Connected,
        [string]$Reason,
        [double]$Now,
        [double]$LastValid = 0
    )
    $view = [ordered]@{ Label = $Label; State = 'Unavailable'; Remaining = $null; ResetsIn = $null; LastValid = $LastValid; Reason = $Reason }
    if ($null -eq $Window -or $null -eq $Window.usedPercent -or $null -eq $Window.resetsAt) {
        if (-not $view.Reason) { $view.Reason = 'Not reported' }
        return [pscustomobject]$view
    }
    $observed = [double]$Window.observedAt
    $view.LastValid = $observed
    if (-not $Connected) {
        $view.State = 'Stale'
        if (-not $view.Reason) { $view.Reason = 'Provider not connected' }
    } elseif ([double]$Window.resetsAt -le $Now) {
        $view.State = 'Stale'
        $view.Reason = 'Window has reset; waiting for new data'
    } elseif (($Now - $observed) -gt $script:StaleAfterSeconds) {
        $view.State = 'Stale'
        $view.Reason = 'No recent update'
    } else {
        $view.State = 'Ok'
        $view.Reason = $null
        $view.Remaining = [int][math]::Max(0, [math]::Min(100, [math]::Round(100 - [double]$Window.usedPercent)))
        $view.ResetsIn = Format-Countdown ([double]$Window.resetsAt - $Now)
    }
    [pscustomobject]$view
}

# $Overview / $Health may be $null when the tracker could not be reached.
function Get-ProviderView {
    param(
        [string]$Name,
        $Overview,
        $Health,
        [double]$Now,
        [hashtable]$LastValid = @{}
    )
    $connected = $false
    $error = $null
    if ($Health -and $Health.providers -and $Health.providers.$Name) {
        $connected = [bool]$Health.providers.$Name.connected
        $error = $Health.providers.$Name.error
    } elseif ($Overview -and $Overview.connection) {
        $connected = [bool]$Overview.connection.connected
        $error = $Overview.connection.error
    }
    if ($null -eq $Overview) { $connected = $false; if (-not $error) { $error = 'Tracker not reachable' } }

    $limits = if ($Overview) { $Overview.limits } else { $null }
    $rows = foreach ($pair in @(@('5-hour', 'fiveHour'), @('7-day', 'sevenDay'))) {
        $key = "$Name/$($pair[1])"
        $win = if ($limits) { $limits.($pair[1]) } else { $null }
        $row = Get-WindowView -Window $win -Label $pair[0] -Connected $connected -Reason $error -Now $Now -LastValid ([double]($LastValid[$key]))
        if ($row.State -eq 'Ok') { $LastValid[$key] = $row.LastValid }
        $row
    }

    $needsAuth = ($Name -eq 'claude') -and (@($rows | Where-Object State -ne 'Ok').Count -gt 0) -and ("$error" -match 'sign-in|token|expired|rejected|login')
    [pscustomobject]@{
        Name      = $Name
        Title     = if ($Name -eq 'claude') { 'Claude' } else { 'Codex' }
        Rows      = @($rows)
        Error     = $error
        AuthHint  = if ($needsAuth) { 'Run Claude CLI once to refresh authentication.' } else { $null }
    }
}

function Get-TrayLevel {
    param($Providers)
    $ok = @($Providers | ForEach-Object { $_.Rows } | Where-Object State -eq 'Ok')
    if ($ok.Count -eq 0) { return [pscustomobject]@{ Level = 'unknown'; Minimum = $null } }
    $min = [int]($ok | Measure-Object -Property Remaining -Minimum).Minimum
    [pscustomobject]@{ Level = (Get-Level $min); Minimum = $min }
}

function Format-RowText {
    param($Row)
    $label = $Row.Label.PadRight(7)
    switch ($Row.State) {
        'Ok' { return "$label $("$($Row.Remaining)%".PadLeft(4)) remaining  $($script:Dot)  resets in $($Row.ResetsIn)" }
        'Stale' {
            $last = if ($Row.LastValid -gt 0) { "last valid update $(Format-ClockTime $Row.LastValid)" } else { 'no valid update yet' }
            return "$label Stale  $($script:Dot)  $last"
        }
        default {
            $last = if ($Row.LastValid -gt 0) { "  $($script:Dot)  last valid update $(Format-ClockTime $Row.LastValid)" } else { '' }
            return "$label Unavailable$last"
        }
    }
}

function Format-ProviderText {
    param($Provider)
    $lines = @($Provider.Title)
    foreach ($row in $Provider.Rows) { $lines += '  ' + (Format-RowText $row) }
    if ($Provider.AuthHint) { $lines += '  ' + $Provider.AuthHint }
    if ($Provider.Note) { $lines += '  ' + $Provider.Note }
    $lines -join "`r`n"
}

# NotifyIcon.Text accepts at most 63 characters, so keep this compact: "Codex 5h 56% 7d 59% | Claude 5h 87% 7d 46%".
function Format-TooltipText {
    param($Providers, $Level)
    $parts = foreach ($p in $Providers) {
        $bits = foreach ($r in $p.Rows) {
            $v = switch ($r.State) { 'Ok' { "$($r.Remaining)%" } 'Stale' { 'stale' } default { 'n/a' } }
            "$($r.Label.Replace('-hour', 'h').Replace('-day', 'd')) $v"
        }
        "$($p.Title) " + ($bits -join ' ')
    }
    $text = $parts -join ' | '
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $text
}

# Fetch overview + health. Any failure yields $null for that piece; never throws.
function Get-TrayData {
    param([string]$ApiBase, [int]$TimeoutSec = 5)
    $result = [ordered]@{ Health = $null; Codex = $null; Claude = $null; Reachable = $false }
    try {
        $result.Health = Invoke-RestMethod -Uri "$ApiBase/api/health" -TimeoutSec $TimeoutSec -ErrorAction Stop
        $result.Reachable = $true
    } catch { return [pscustomobject]$result }
    foreach ($name in 'codex', 'claude') {
        $enabled = $result.Health.providers.$name.enabled
        if ($enabled -eq $false) { continue }
        try { $result[(Get-Culture).TextInfo.ToTitleCase($name)] = Invoke-RestMethod -Uri "$ApiBase/api/overview?provider=$name" -TimeoutSec $TimeoutSec -ErrorAction Stop } catch { }
    }
    [pscustomobject]$result
}

# Build the whole view from fetched data. Pure apart from $LastValid bookkeeping.
function Get-TrayView {
    param($Data, [double]$Now, [hashtable]$LastValid, [string]$ClaudeNote)
    $providers = @(
        (Get-ProviderView -Name 'codex' -Overview $Data.Codex -Health $Data.Health -Now $Now -LastValid $LastValid),
        (Get-ProviderView -Name 'claude' -Overview $Data.Claude -Health $Data.Health -Now $Now -LastValid $LastValid)
    )
    foreach ($p in $providers) { $p | Add-Member -NotePropertyName Note -NotePropertyValue $(if ($p.Name -eq 'claude' -and $ClaudeNote) { $ClaudeNote } else { $null }) -Force }
    $level = Get-TrayLevel $providers
    [pscustomobject]@{
        Providers = $providers
        Level     = $level.Level
        Minimum   = $level.Minimum
        Reachable = $Data.Reachable
        Text      = ($providers | ForEach-Object { Format-ProviderText $_ }) -join "`r`n`r`n"
        Tooltip   = Format-TooltipText $providers $level
    }
}

# Ask the tracker to refresh now (the same call the dashboard's refresh button makes).
function Invoke-TrayRefresh {
    param([string]$ApiBase, [int]$TimeoutSec = 60)
    foreach ($name in 'codex', 'claude') {
        try { Invoke-RestMethod -Method Post -Uri "$ApiBase/api/refresh?provider=$name" -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null } catch { }
    }
}
