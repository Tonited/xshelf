# Generates the launcher icon PNGs (+ a big preview) for X Like Manage.
#
# Design: X's mark (two crossing strokes) on a dark navy rounded tile.
# The "\" stroke is white, the "/" stroke is the app accent blue (#6CC7F5).
# Geometry lives in a 108x108 space and is scaled per density.
#
# Usage: pwsh -File tool/make_icons.ps1

Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# --- geometry in 108x108 space (kept inside the adaptive-icon safe circle) ---
$strokeA = @(  # "\" top-left -> bottom-right
    @(32.6, 38.7), @(66.6, 78.7), @(75.4, 71.3), @(41.4, 31.3)
)
$strokeB = @(  # "/" top-right -> bottom-left
    @(66.6, 31.3), @(32.6, 71.3), @(41.4, 78.7), @(75.4, 38.7)
)
# lower-left arm of "/" (cut just below the crossing) -> the accent-blue piece
$strokeAccent = @(
    @(44.8, 57.0), @(32.6, 71.3), @(41.4, 78.7), @(59.9, 57.0)
)

function New-RoundedRect([System.Drawing.RectangleF]$r, [float]$radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $path.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $path.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-Icon {
    param([int]$Size, [string]$Path, [double]$ArtScale = 1.0)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # --- tile: vertical gradient, rounded corners ---
    $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
    $radius = [float]($Size * 0.235)
    $tile = New-RoundedRect $rect $radius
    $c1 = [System.Drawing.ColorTranslator]::FromHtml('#16233A')
    $c2 = [System.Drawing.ColorTranslator]::FromHtml('#0A1018')
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect, $c1, $c2, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($brush, $tile)

    # subtle top highlight so the tile does not look flat
    $hlRect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size * 0.55)
    $hl = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $hlRect,
        [System.Drawing.Color]::FromArgb(26, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
        [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($hl, $tile)

    # --- the X mark ---
    $k = ($Size / 108.0) * $ArtScale
    $origin = ($Size - 108.0 * $k) / 2.0
    function To-Points($shape, [double]$k, [double]$origin) {
        $pts = New-Object 'System.Drawing.PointF[]' $shape.Count
        for ($i = 0; $i -lt $shape.Count; $i++) {
            $pts[$i] = New-Object System.Drawing.PointF(
                [float]($origin + $shape[$i][0] * $k),
                [float]($origin + $shape[$i][1] * $k))
        }
        return , $pts
    }

    $white = New-Object System.Drawing.SolidBrush(
        [System.Drawing.ColorTranslator]::FromHtml('#F7FAFC'))
    $blue = New-Object System.Drawing.SolidBrush(
        [System.Drawing.ColorTranslator]::FromHtml('#6CC7F5'))

    # White X (both strokes), then the lower-left arm of "/" in the accent blue:
    # that reads as a real X with one deliberate accent instead of a striped bar.
    $g.FillPolygon($white, (To-Points $strokeB $k $origin))
    $g.FillPolygon($white, (To-Points $strokeA $k $origin))
    $g.FillPolygon($blue, (To-Points $strokeAccent $k $origin))

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)

    $brush.Dispose(); $hl.Dispose(); $white.Dispose(); $blue.Dispose()
    $tile.Dispose(); $g.Dispose(); $bmp.Dispose()
}

$res = Join-Path $Root 'android/app/src/main/res'
$sizes = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
foreach ($k in $sizes.Keys) {
    $size = $sizes[$k]
    New-Icon -Size $size -Path (Join-Path $res "mipmap-$k/ic_launcher.png") -ArtScale 1.18
    Write-Host "wrote mipmap-$k ($size px)"
}

# big preview for docs / README
New-Icon -Size 512 -Path (Join-Path $Root 'docs/logo-512.png') -ArtScale 1.0
Write-Host 'wrote docs/logo-512.png'
