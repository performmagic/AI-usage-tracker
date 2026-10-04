# AI Usage tray: shows Codex and Claude quota from the local tracker API.
# Run hidden:  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File ai-usage-tray.ps1
# -PrintState prints the current view as text and exits (no UI, for checks and tests).
# -Snapshot <png> renders the popup to an image and exits (for visual checks).
param([switch]$PrintState, [string]$Snapshot)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'TrayLogic.ps1')

$endpoint = Get-TrayEndpoint -ProjectRoot $projectRoot
$lastValid = @{}

if ($PrintState) {
    $view = Get-TrayView -Data (Get-TrayData -ApiBase $endpoint.Api) -Now ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -LastValid $lastValid
    if (-not $view.Reachable) { 'Tracker not reachable at ' + $endpoint.Api }
    $view.Text
    "Level: $($view.Level)"
    exit 0
}

# One tray per user session.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\AIUsageTrackerTray', [ref]$createdNew)
if (-not $createdNew -and -not $Snapshot) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'TrayIcon.ps1')
[void][Native.Metrics]::SetProcessDPIAware()  # so the icon is drawn at the real tray size
[System.Windows.Forms.Application]::EnableVisualStyles()

$logFile = Join-Path $projectRoot 'logs\ai-usage-tray.log'
function Write-TrayLog([string]$message) {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 200KB) { Remove-Item $logFile -Force }
        Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format 's'), $message)
    } catch { }
}

$script:view = $null
$script:fetchedAt = [DateTime]::MinValue
$script:currentHandle = [IntPtr]::Zero

# --- Popup -------------------------------------------------------------------
$popup = New-Object System.Windows.Forms.Form
$popup.FormBorderStyle = 'FixedToolWindow'
$popup.ControlBox = $false
$popup.Text = ''
$popup.ShowInTaskbar = $false
$popup.TopMost = $true
$popup.StartPosition = 'Manual'
$popup.BackColor = [System.Drawing.Color]::White
$popup.Padding = New-Object System.Windows.Forms.Padding 12

$body = New-Object System.Windows.Forms.Label
$body.Font = New-Object System.Drawing.Font 'Consolas', 10
$body.AutoSize = $true
$body.MaximumSize = New-Object System.Drawing.Size 520, 0
$body.Location = New-Object System.Drawing.Point 12, 12

$footer = New-Object System.Windows.Forms.Label
$footer.Font = New-Object System.Drawing.Font 'Segoe UI', 8.5
$footer.ForeColor = [System.Drawing.Color]::DimGray
$footer.AutoSize = $true

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.AutoSize = $true
$buttons.FlowDirection = 'LeftToRight'
$buttons.WrapContents = $false

function New-PopupButton($text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.AutoSize = $true; $b.FlatStyle = 'System'; $b.Font = New-Object System.Drawing.Font 'Segoe UI', 9
    $b
}
$btnRefresh = New-PopupButton 'Refresh now'
$btnDashboard = New-PopupButton 'Open Dashboard'
$btnExit = New-PopupButton 'Exit'
$buttons.Controls.AddRange(@($btnRefresh, $btnDashboard, $btnExit))
$popup.Controls.AddRange(@($body, $footer, $buttons))

function Update-PopupLayout {
    $body.Text = $script:view.Text
    $stamp = if ($script:view.Reachable) { "Checked $($script:fetchedAt.ToString('HH:mm:ss'))" } else { "Tracker not reachable ($($endpoint.Api)). Last check $($script:fetchedAt.ToString('HH:mm:ss'))" }
    $footer.Text = $stamp
    $body.PerformLayout()
    $footer.Location = New-Object System.Drawing.Point 12, ($body.Bottom + 10)
    $buttons.Location = New-Object System.Drawing.Point 8, ($footer.Bottom + 6)
    $popup.ClientSize = New-Object System.Drawing.Size ([math]::Max($body.Right, $buttons.Right) + 16), ($buttons.Bottom + 12)
}

function Show-Popup {
    if (((Get-Date) - $script:fetchedAt).TotalSeconds -gt 30) { Update-Tray }
    else { Render-View }
    Update-PopupLayout
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $popup.Location = New-Object System.Drawing.Point ($area.Right - $popup.Width - 8), ($area.Bottom - $popup.Height - 8)
    $popup.Show()
    $popup.Activate()
}

$popup.Add_Deactivate({ if ($popup.Visible) { $popup.Hide() } })
$popup.Add_FormClosing({ param($s, $e) if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $popup.Hide() } })

# --- Tray icon and menu --------------------------------------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$miDashboard = $menu.Items.Add('Open Dashboard')
$null = $menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')
$notify.ContextMenuStrip = $menu

function Render-View {
    # Recompute from cached data so countdowns and the stale rules use the current time.
    $script:view = Get-TrayView -Data $script:data -Now ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -LastValid $lastValid
    $new = New-TrayIcon $script:view.Level $script:view.Minimum
    $old = $script:currentHandle
    $notify.Icon = $new.Icon
    $script:currentHandle = $new.Handle
    if ($old -ne [IntPtr]::Zero) { [Native.Metrics]::DestroyIcon($old) | Out-Null }
    $tip = if ($script:view.Reachable) { $script:view.Tooltip } else { 'AI Usage: tracker not reachable' }
    $notify.Text = $tip
    if ($popup.Visible) { Update-PopupLayout }
}

function Update-Tray {
    try {
        $script:data = Get-TrayData -ApiBase $endpoint.Api -TimeoutSec 4
        $script:fetchedAt = Get-Date
        Render-View
    } catch { Write-TrayLog "update failed: $($_.Exception.Message)" }
}

function Invoke-Refresh {
    try {
        $popup.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $notify.Text = 'AI Usage: refreshing...'
        Invoke-TrayRefresh -ApiBase $endpoint.Api
    } catch { Write-TrayLog "refresh failed: $($_.Exception.Message)" }
    finally { $popup.Cursor = [System.Windows.Forms.Cursors]::Default }
    Update-Tray
}

function Open-Dashboard { try { Start-Process $endpoint.Dashboard } catch { Write-TrayLog "open dashboard failed: $($_.Exception.Message)" } }

function Stop-Tray {
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    if ($script:currentHandle -ne [IntPtr]::Zero) { [Native.Metrics]::DestroyIcon($script:currentHandle) | Out-Null }
    $popup.Dispose()
    [System.Windows.Forms.Application]::ExitThread()
}

$notify.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { if ($popup.Visible) { $popup.Hide() } else { Show-Popup } } })
$miRefresh.Add_Click({ Invoke-Refresh })
$miDashboard.Add_Click({ Open-Dashboard })
$miExit.Add_Click({ Stop-Tray })
$btnRefresh.Add_Click({ Invoke-Refresh; Update-PopupLayout })
$btnDashboard.Add_Click({ $popup.Hide(); Open-Dashboard })
$btnExit.Add_Click({ Stop-Tray })

# The tracker already polls Codex/Claude; the tray only re-reads its local API.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-Tray })

try {
    $script:data = [pscustomobject]@{ Health = $null; Codex = $null; Claude = $null; Reachable = $false }
    if ($Snapshot) {
        Update-Tray
        Update-PopupLayout
        $popup.Show()
        $bitmap = New-Object System.Drawing.Bitmap $popup.Width, $popup.Height
        $popup.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle 0, 0, $popup.Width, $popup.Height))
        $bitmap.Save($Snapshot, [System.Drawing.Imaging.ImageFormat]::Png)
        $popup.Dispose()
        if ($script:currentHandle -ne [IntPtr]::Zero) { [Native.Metrics]::DestroyIcon($script:currentHandle) | Out-Null }
        return
    }
    $notify.Visible = $true
    Update-Tray
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-TrayLog "fatal: $($_.Exception.Message)"
} finally {
    try { $notify.Visible = $false } catch { }
    try { if ($createdNew) { $mutex.ReleaseMutex() } } catch { }
}
