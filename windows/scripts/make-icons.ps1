# Draws OmniCast's icons into windows/app/Assets (already committed; run again
# only to change them). Needs Windows PowerShell 5.1 (System.Drawing):
#   powershell -ExecutionPolicy Bypass -File windows\scripts\make-icons.ps1
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$Assets = Join-Path (Split-Path -Parent $PSScriptRoot) 'app\Assets'
New-Item -ItemType Directory -Force $Assets | Out-Null

function New-IconBitmap([int]$size, [string]$badge) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = [single]$size

    # Rounded square, blue to violet.
    $r = $s * 0.22
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $m = $s * 0.04; $w = $s - 2 * $m
    $path.AddArc($m, $m, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($m + $w - 2 * $r, $m, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($m + $w - 2 * $r, $m + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc($m, $m + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $rect = New-Object System.Drawing.RectangleF 0, 0, $s, $s
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, 0, 120, 212)), ([System.Drawing.Color]::FromArgb(255, 136, 61, 220)), 45
    $g.FillPath($brush, $path)

    # Broadcast mark: a dot with two arcs on each side.
    $c = $s / 2
    $white = [System.Drawing.Color]::White
    $dot = $s * 0.13
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $white), $c - $dot / 2, $c - $dot / 2, $dot, $dot)
    $pen = New-Object System.Drawing.Pen $white, ([math]::Max(1.2, $s * 0.07))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    foreach ($k in 0.26, 0.40) {
        $rr = $s * $k
        $g.DrawArc($pen, $c - $rr, $c - $rr, 2 * $rr, 2 * $rr, -40, 80)
        $g.DrawArc($pen, $c - $rr, $c - $rr, 2 * $rr, 2 * $rr, 140, 80)
    }

    # State badge, bottom right.
    if ($badge) {
        $b = $s * 0.42; $bx = $s - $b; $by = $s - $b
        $red = [System.Drawing.Color]::FromArgb(255, 196, 43, 28)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $white), $bx, $by, $b, $b)
        $inner = $b * 0.74; $o = ($b - $inner) / 2
        if ($badge -eq 'live') {
            $g.FillEllipse((New-Object System.Drawing.SolidBrush $red), $bx + $o, $by + $o, $inner, $inner)
        } else {
            $ring = New-Object System.Drawing.Pen $red, ([math]::Max(1.5, $b * 0.16))
            $g.DrawEllipse($ring, $bx + $o + $b * 0.06, $by + $o + $b * 0.06, $inner - $b * 0.12, $inner - $b * 0.12)
            $d = $inner * 0.38
            $g.FillEllipse((New-Object System.Drawing.SolidBrush $red), $bx + ($b - $d) / 2, $by + ($b - $d) / 2, $d, $d)
        }
    }
    $g.Dispose()
    return $bmp
}

# An .ico with PNG entries (Vista+ format), one per size.
function Save-Ico([string]$file, [string]$badge) {
    $sizes = 16, 20, 24, 32, 48, 64, 256
    $pngs = foreach ($sz in $sizes) {
        $bmp = New-IconBitmap $sz $badge
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        , $ms.ToArray()
    }
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $out
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $sz = $sizes[$i]; $dim = if ($sz -ge 256) { 0 } else { $sz }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    [System.IO.File]::WriteAllBytes((Join-Path $Assets $file), $out.ToArray())
}

Save-Ico 'OmniCast.ico' ''
Save-Ico 'OmniCast-live.ico' 'live'
Save-Ico 'OmniCast-rec.ico' 'rec'
$png = New-IconBitmap 64 ''
$png.Save((Join-Path $Assets 'OmniCast.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$png.Dispose()
Write-Host "Icons written to $Assets"
