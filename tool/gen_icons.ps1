# Generates the app icon (no external assets needed).
#
#   .\tool\gen_icons.ps1
#
# Outputs:
#   dist/icon-1024.png                                (source art)
#   android/app/src/main/res/mipmap-*/ic_launcher.png (48/72/96/144/192)
#
# Design: rounded square with a blue->violet gradient, a white heart, and a
# translucent play triangle - "likes you can watch".

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded square background
    $radius = [int]($size * 0.22)
    $d = $radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($size - $d, 0, $d, $d, 270, 90)
    $path.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
    $path.AddArc(0, $size - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 29, 155, 240),
        [System.Drawing.Color]::FromArgb(255, 138, 43, 226),
        45)
    $g.FillPath($grad, $path)

    # heart from the classic parametric curve
    $points = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    $cx = $size * 0.5
    $cy = $size * 0.54
    $scale = $size / 42.0
    for ($i = 0; $i -le 180; $i++) {
        $t = $i * [Math]::PI / 90.0
        $x = 16 * [Math]::Pow([Math]::Sin($t), 3)
        $y = 13 * [Math]::Cos($t) - 5 * [Math]::Cos(2 * $t) - 2 * [Math]::Cos(3 * $t) - [Math]::Cos(4 * $t)
        $points.Add([System.Drawing.PointF]::new(
            [float]($cx + $x * $scale * 0.92),
            [float]($cy - $y * $scale * 0.92)))
    }
    $heart = New-Object System.Drawing.Drawing2D.GraphicsPath
    $heart.AddPolygon($points.ToArray())
    $g.FillPath([System.Drawing.Brushes]::White, $heart)

    # translucent play triangle (bottom right)
    $tri = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tx = $size * 0.70
    $ty = $size * 0.72
    $ts = $size * 0.16
    $tri.AddPolygon(@(
        [System.Drawing.PointF]::new([float]$tx, [float]($ty - $ts)),
        [System.Drawing.PointF]::new([float]($tx + $ts * 1.15), [float]$ty),
        [System.Drawing.PointF]::new([float]$tx, [float]($ty + $ts))
    ))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 255, 255, 255), [float]($size * 0.055))
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $tri)

    $g.Dispose()
    return $bmp
}

$targets = @(
    @{ Path = 'android\app\src\main\res\mipmap-mdpi\ic_launcher.png'; Size = 48 },
    @{ Path = 'android\app\src\main\res\mipmap-hdpi\ic_launcher.png'; Size = 72 },
    @{ Path = 'android\app\src\main\res\mipmap-xhdpi\ic_launcher.png'; Size = 96 },
    @{ Path = 'android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png'; Size = 144 },
    @{ Path = 'android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png'; Size = 192 },
    @{ Path = 'dist\icon-1024.png'; Size = 1024 }
)

foreach ($t in $targets) {
    $full = Join-Path $root $t.Path
    $dir = Split-Path -Parent $full
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $bmp = New-IconBitmap $t.Size
    $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "wrote $($t.Path) ($($t.Size)px)"
}
