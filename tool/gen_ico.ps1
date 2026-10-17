# Generates windows/runner/resources/app_icon.ico from the same art as the
# Android icon (multi-size ICO, 32bpp DIB entries - the format every Windows
# shell version understands).
#
#   .\tool\gen_ico.ps1 [-OutFile path]

param([string]$OutFile)

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $root 'windows\runner\resources\app_icon.ico' }

function New-ArtBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $radius = [Math]::Max(2, [int]($size * 0.22))
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

    if ($size -ge 32) {
        $tri = New-Object System.Drawing.Drawing2D.GraphicsPath
        $tx = $size * 0.70
        $ty = $size * 0.72
        $ts = $size * 0.16
        $tri.AddPolygon(@(
            [System.Drawing.PointF]::new([float]$tx, [float]($ty - $ts)),
            [System.Drawing.PointF]::new([float]($tx + $ts * 1.15), [float]$ty),
            [System.Drawing.PointF]::new([float]$tx, [float]($ty + $ts))
        ))
        $pen = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::FromArgb(210, 255, 255, 255),
            [float][Math]::Max(1.0, $size * 0.055))
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $g.DrawPath($pen, $tri)
    }

    $g.Dispose()
    return $bmp
}

# One ICO image entry: BITMAPINFOHEADER + bottom-up BGRA + 1bpp AND mask.
function Get-IconEntryBytes([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width
    $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $raw = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($data)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    $bw.Write([int]40)              # biSize
    $bw.Write([int]$w)              # biWidth
    $bw.Write([int]($h * 2))        # biHeight (XOR + AND)
    $bw.Write([int16]1)             # biPlanes
    $bw.Write([int16]32)            # biBitCount
    $bw.Write([int]0)               # biCompression = BI_RGB
    $bw.Write([int]($w * $h * 4))   # biSizeImage
    $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)

    for ($y = $h - 1; $y -ge 0; $y--) {
        $bw.Write($raw, $y * $stride, $w * 4)
    }

    $maskRow = [int]([Math]::Ceiling($w / 32.0) * 4)
    $zero = New-Object byte[] $maskRow
    for ($y = 0; $y -lt $h; $y++) { $bw.Write($zero) }

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose()
    $ms.Dispose()
    # Leading comma keeps PowerShell from unrolling the byte array on return.
    return , $bytes
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$entries = New-Object System.Collections.Generic.List[object]
foreach ($s in $sizes) {
    $bmp = New-ArtBitmap $s
    $data = Get-IconEntryBytes $bmp
    $bmp.Dispose()
    if ($null -eq $data -or $data.Length -eq 0) { throw "empty icon entry for $s" }
    $entries.Add([pscustomobject]@{ Size = $s; Data = [byte[]]$data })
    Write-Host "  entry $($s)x$($s): $($data.Length) bytes"
}

$dir = Split-Path -Parent $OutFile
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$fs = [System.IO.File]::Create($OutFile)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([int16]0)      # reserved
$bw.Write([int16]1)      # type = icon
$bw.Write([int16]$entries.Count)

$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
    $bw.Write([byte]$dim)
    $bw.Write([byte]$dim)
    $bw.Write([byte]0)     # color count
    $bw.Write([byte]0)     # reserved
    $bw.Write([int16]1)    # planes
    $bw.Write([int16]32)   # bpp
    $bw.Write([int]$e.Data.Length)
    $bw.Write([int]$offset)
    $offset += $e.Data.Length
}
foreach ($e in $entries) { $bw.Write($e.Data) }
$bw.Flush(); $bw.Dispose(); $fs.Dispose()

# Read it back so a broken file fails here instead of in the Windows build.
$icon = New-Object System.Drawing.Icon($OutFile)
Write-Host "wrote $OutFile ($((Get-Item $OutFile).Length) bytes, $($icon.Width)x$($icon.Height) default)"
$icon.Dispose()
