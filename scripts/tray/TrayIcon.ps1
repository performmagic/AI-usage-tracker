# Tray icon drawing: a dark rounded tile with a 270-degree gauge. The colored arc
# length is the lowest remaining quota; the color is the status. Needs System.Drawing.

Add-Type -Namespace Native -Name Metrics -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr handle);
'@

$script:IconColors = @{
    normal   = [System.Drawing.Color]::FromArgb(52, 211, 120)
    warning  = [System.Drawing.Color]::FromArgb(251, 191, 36)
    critical = [System.Drawing.Color]::FromArgb(248, 82, 82)
    unknown  = [System.Drawing.Color]::FromArgb(148, 163, 184)
}
$script:IconTile = [System.Drawing.Color]::FromArgb(15, 23, 42)
$script:IconTrack = [System.Drawing.Color]::FromArgb(71, 85, 105)

# Pixel size Windows will show the tray icon at (16 at 100% scale, 24 at 150%, 32 at 200%).
function Get-TrayIconSize {
    $size = [Native.Metrics]::GetSystemMetrics(49)  # SM_CXSMICON
    if ($size -lt 16) { 16 } else { $size }
}

function New-TrayIconBitmap {
    param([string]$Level, $Minimum, [int]$Size = 16)
    $scale = 8
    $big = $Size * $scale
    $canvas = New-Object System.Drawing.Bitmap $big, $big
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Tile
    $radius = [int]($big * 0.24)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($big - $d, 0, $d, $d, 270, 90)
    $path.AddArc($big - $d, $big - $d, $d, $d, 0, 90)
    $path.AddArc(0, $big - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $tile = New-Object System.Drawing.SolidBrush $script:IconTile
    $g.FillPath($tile, $path)

    # Gauge: opens at the bottom, runs clockwise from 135 to 405 degrees.
    $thickness = $big * $(if ($Size -le 16) { 0.20 } else { 0.13 })
    $inset = $big * $(if ($Size -le 16) { 0.14 } else { 0.11 }) + $thickness / 2
    $rect = New-Object System.Drawing.RectangleF $inset, $inset, ($big - 2 * $inset), ($big - 2 * $inset)
    $trackPen = New-Object System.Drawing.Pen $script:IconTrack, $thickness
    $trackPen.StartCap = 'Round'; $trackPen.EndCap = 'Round'
    $g.DrawArc($trackPen, $rect, 135, 270)
    if ($null -ne $Minimum) {
        $sweep = [math]::Max(14, 270 * [math]::Min(100, [math]::Max(0, [double]$Minimum)) / 100)
        $fillPen = New-Object System.Drawing.Pen $script:IconColors[$Level], $thickness
        $fillPen.StartCap = 'Round'; $fillPen.EndCap = 'Round'
        $g.DrawArc($fillPen, $rect, 135, $sweep)
        $fillPen.Dispose()
    }

    # Number inside the gauge, only when there is room to read it.
    if ($Size -ge 24) {
        $text = if ($null -eq $Minimum) { '?' } else { "$Minimum" }
        $fontPx = $big * $(if ($text.Length -ge 3) { 0.23 } else { 0.33 })
        $font = New-Object System.Drawing.Font 'Segoe UI', $fontPx, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.DrawString($text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, ($big * 0.04), $big, $big), $format)
        $font.Dispose()
    }
    $g.Dispose(); $tile.Dispose(); $trackPen.Dispose(); $path.Dispose()

    # Downscale with high-quality filtering to the real tray size.
    $final = New-Object System.Drawing.Bitmap $Size, $Size
    $fg = [System.Drawing.Graphics]::FromImage($final)
    $fg.InterpolationMode = 'HighQualityBicubic'
    $fg.PixelOffsetMode = 'HighQuality'
    $fg.CompositingQuality = 'HighQuality'
    $fg.DrawImage($canvas, 0, 0, $Size, $Size)
    $fg.Dispose(); $canvas.Dispose()
    $final
}

function New-TrayIcon {
    param([string]$Level, $Minimum, [int]$Size = (Get-TrayIconSize))
    $bitmap = New-TrayIconBitmap -Level $Level -Minimum $Minimum -Size $Size
    $handle = $bitmap.GetHicon()
    $bitmap.Dispose()
    [pscustomobject]@{ Icon = [System.Drawing.Icon]::FromHandle($handle); Handle = $handle }
}
