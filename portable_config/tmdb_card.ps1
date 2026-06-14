#requires -version 5
# tmdb_card.ps1 -- render the whole movie-info card (backdrop + dark panel + poster + text)
# into ONE BGRA buffer for a single mpv overlay-add. Avoids the ASS-vs-bitmap z-order conflict.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tmdb_card.ps1 -Spec <json-file>
# Prints "<cardW> <cardH>" on success; "ERR <message>" + exit 1 on failure.
param([Parameter(Mandatory = $true)][string]$Spec)

$ErrorActionPreference = 'Stop'

# Compiled BGRA HDR encoder: sRGB -> linear -> BT.709->BT.2020 -> scale to RefNits -> PQ (ST.2084).
# Runs in-place over the byte[] (skips fully transparent pixels). Compiled C# so it's milliseconds.
Add-Type -TypeDefinition @'
public static class TmdbHdr {
    static double SrgbToLin(double c) { return c <= 0.04045 ? c / 12.92 : System.Math.Pow((c + 0.055) / 1.055, 2.4); }
    static double Pq(double L) {
        double m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        double Lm = System.Math.Pow(L, m1);
        return System.Math.Pow((c1 + c2 * Lm) / (1.0 + c3 * Lm), m2);
    }
    public static void Encode(byte[] buf, double refNits) {
        double scale = refNits / 10000.0;
        for (int i = 0; i + 3 < buf.Length; i += 4) {
            if (buf[i + 3] == 0) continue; // transparent corner
            double b = SrgbToLin(buf[i]     / 255.0);
            double g = SrgbToLin(buf[i + 1] / 255.0);
            double r = SrgbToLin(buf[i + 2] / 255.0);
            double R = 0.627403896 * r + 0.329283038 * g + 0.043313066 * b;
            double G = 0.069097289 * r + 0.919540395 * g + 0.011362316 * b;
            double B = 0.016391439 * r + 0.088013308 * g + 0.895595253 * b;
            if (R < 0) R = 0; if (G < 0) G = 0; if (B < 0) B = 0;
            R *= scale; G *= scale; B *= scale;
            if (R > 1) R = 1; if (G > 1) G = 1; if (B > 1) B = 1;
            buf[i]     = (byte)(Pq(B) * 255.0 + 0.5);
            buf[i + 1] = (byte)(Pq(G) * 255.0 + 0.5);
            buf[i + 2] = (byte)(Pq(R) * 255.0 + 0.5);
        }
    }
}
'@

function New-RoundedPath([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($r -le 0) { $p.AddRectangle((New-Object System.Drawing.Rectangle($x, $y, $w, $h))); return $p }
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-ColorAttrs([double]$sat, [double]$gn, [double]$gamma) {
    $lr = 0.2126; $lg = 0.7152; $lb = 0.0722; $s = $sat
    $cm = New-Object System.Drawing.Imaging.ColorMatrix
    $cm.Item(0, 0) = ($lr * (1 - $s) + $s) * $gn; $cm.Item(0, 1) = ($lr * (1 - $s)) * $gn; $cm.Item(0, 2) = ($lr * (1 - $s)) * $gn
    $cm.Item(1, 0) = ($lg * (1 - $s)) * $gn; $cm.Item(1, 1) = ($lg * (1 - $s) + $s) * $gn; $cm.Item(1, 2) = ($lg * (1 - $s)) * $gn
    $cm.Item(2, 0) = ($lb * (1 - $s)) * $gn; $cm.Item(2, 1) = ($lb * (1 - $s)) * $gn; $cm.Item(2, 2) = ($lb * (1 - $s) + $s) * $gn
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    if ($gamma -ne 1.0 -and $gamma -gt 0) { $ia.SetGamma($gamma) }
    return $ia
}

function Get-Img([string]$url) {
    if ([string]::IsNullOrEmpty($url)) { return $null }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'mpv-tmdb-info/1.0')
        $b = $wc.DownloadData($url); $wc.Dispose()
        return [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $b)))
    }
    catch { return $null }
}

try {
    Add-Type -AssemblyName System.Drawing
    $s = Get-Content -LiteralPath $Spec -Raw -Encoding UTF8 | ConvertFrom-Json

    $H = [int]$s.height
    $Wd = [int]$s.width_hint
    function Scale([double]$f) { return [int][Math]::Round($H * $f) }
    $pad = Scale 0.020; $gap = Scale 0.020; $radius = Scale 0.012
    $title_fs = Scale 0.030; $meta_fs = Scale 0.0195; $body_fs = Scale 0.016
    $tagline_fs = [int][Math]::Round($meta_fs * 0.92); $credit_fs = [int][Math]::Round($body_fs * 0.92)
    $sp1 = Scale 0.012; $sp2 = Scale 0.016; $sp_small = Scale 0.008
    $pw = [int]$s.poster_width
    $text_w = [Math]::Max(440, [Math]::Min(900, [int]($Wd * 0.26)))

    # Color is handled by an optional BT.2020-PQ post-encode (HDR), not per-image knobs.
    $hdrEncode = [bool]$s.hdr_encode
    $refNits = if ($s.ref_nits) { [double]$s.ref_nits } else { 203.0 }
    $iaBd = New-ColorAttrs 1.0 0.42 1.0   # backdrop only dimmed for legibility (no color change)

    $poster = Get-Img $s.poster_url
    $backdrop = $null
    if ($s.show_backdrop) { $backdrop = Get-Img $s.backdrop_url }

    if ($poster) { $ph = [int]($poster.Height * $pw / $poster.Width) } else { $pw = 0; $ph = 0 }
    $colGap = if ($pw -gt 0) { $gap } else { 0 }

    # fonts (sizes in pixels)
    $PX = [System.Drawing.GraphicsUnit]::Pixel
    $fTitle  = New-Object System.Drawing.Font('Segoe UI', $title_fs, [System.Drawing.FontStyle]::Bold, $PX)
    $fTag    = New-Object System.Drawing.Font('Segoe UI', $tagline_fs, [System.Drawing.FontStyle]::Italic, $PX)
    $fMeta   = New-Object System.Drawing.Font('Segoe UI', $meta_fs, [System.Drawing.FontStyle]::Regular, $PX)
    $fMetaB  = New-Object System.Drawing.Font('Segoe UI', $meta_fs, [System.Drawing.FontStyle]::Bold, $PX)
    $fBody   = New-Object System.Drawing.Font('Segoe UI', $body_fs, [System.Drawing.FontStyle]::Regular, $PX)
    $fCredit = New-Object System.Drawing.Font('Segoe UI', $credit_fs, [System.Drawing.FontStyle]::Regular, $PX)

    $tmp = New-Object System.Drawing.Bitmap(1, 1)
    $mg = [System.Drawing.Graphics]::FromImage($tmp)
    $mg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    function LineH($font) { return [int][Math]::Ceiling($mg.MeasureString('Ag', $font).Height) }

    # content
    $title = [string]$s.title
    if ($s.year) { $title = "$title ($($s.year))" }
    $tagline = [string]$s.tagline

    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisWord
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit
    $plotMaxH = 5 * (LineH $fBody)
    $plotH = 0
    if ($s.overview) {
        $sz = $mg.MeasureString([string]$s.overview, $fBody, (New-Object System.Drawing.SizeF($text_w, $plotMaxH)), $fmt)
        $plotH = [int][Math]::Ceiling($sz.Height)
    }

    $creditParts = @()
    if ($s.director) { $creditParts += "Dir  $($s.director)" }
    if ($s.cast) { $creditParts += "Cast  $($s.cast)" }
    $credit = if ($creditParts.Count -gt 0) { $creditParts -join ("    " + [char]0x2022 + "    ") } else { $null }

    $hTitle = LineH $fTitle
    $hTag = if ($tagline) { $sp_small + (LineH $fTag) } else { 0 }
    $hMeta = LineH $fMeta
    $hPlot = if ($plotH -gt 0) { $sp2 + $plotH } else { 0 }
    $hCredit = if ($credit) { $sp2 + (LineH $fCredit) } else { 0 }
    $text_h = $hTitle + $hTag + $sp1 + $hMeta + $hPlot + $hCredit

    $content_h = [Math]::Max($ph, $text_h)
    $cardW = $pad + $pw + $colGap + $text_w + $pad
    $cardH = $pad + $content_h + $pad

    # ---- compose ----
    $card = New-Object System.Drawing.Bitmap($cardW, $cardH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($card)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

    $g.SetClip((New-RoundedPath 0 0 $cardW $cardH $radius))
    # opaque dark base (keeps interior alpha=255 so no premultiply needed)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 16, 16, 18))), 0, 0, $cardW, $cardH)
    if ($backdrop) {
        $dstA = $cardW / $cardH; $srcA = $backdrop.Width / $backdrop.Height
        if ($srcA -gt $dstA) { $sh = $backdrop.Height; $sw = [int]($backdrop.Height * $dstA); $sx = [int](($backdrop.Width - $sw) / 2); $sy = 0 }
        else { $sw = $backdrop.Width; $sh = [int]($backdrop.Width / $dstA); $sx = 0; $sy = [int](($backdrop.Height - $sh) / 2) }
        $bdDest = New-Object System.Drawing.Rectangle(0, 0, $cardW, $cardH)
        $g.DrawImage($backdrop, $bdDest, [single]$sx, [single]$sy, [single]$sw, [single]$sh, [System.Drawing.GraphicsUnit]::Pixel, $iaBd)
    }
    # dark scrim for text legibility (opaque result over opaque base/backdrop)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 0, 0, 0))), 0, 0, $cardW, $cardH)

    # poster (rounded, with a faint border)
    if ($poster) {
        $px = $pad
        $py = $pad + [int](($content_h - $ph) / 2)
        $pPath = New-RoundedPath $px $py $pw $ph ([int]($radius * 0.6))
        $g.SetClip($pPath)
        $pDest = New-Object System.Drawing.Rectangle($px, $py, $pw, $ph)
        $g.DrawImage($poster, $pDest)   # true sRGB colors; HDR encode (if any) happens on the whole card
        $g.SetClip((New-RoundedPath 0 0 $cardW $cardH $radius))  # restore card clip
        $g.DrawPath((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110, 255, 255, 255), 1.5)), $pPath)
    }

    # text
    $tx = $pad + $pw + $colGap
    $ty = $pad + [int](($content_h - $text_h) / 2)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $grayB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 188, 188, 188))
    $plotB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 206, 206, 206))
    $tagB  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 176, 176, 176))
    $goldB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 200, 64))

    $y = $ty
    $g.DrawString($title, $fTitle, $white, [single]$tx, [single]$y)
    $y += $hTitle
    if ($tagline) {
        $g.DrawString($tagline, $fTag, $tagB, [single]$tx, [single]($y + $sp_small))
        $y += $hTag
    }
    $y += $sp1
    # meta row: gold rating, then gray "• genres • runtime"
    $mx = $tx
    $bullet = "   " + [char]0x2022 + "   "
    if ($s.rating) {
        $rt = ([char]0x2605) + " " + ('{0:0.0}' -f [double]$s.rating)
        $g.DrawString($rt, $fMetaB, $goldB, [single]$mx, [single]$y)
        $mx += $mg.MeasureString($rt, $fMetaB).Width
    }
    $grayParts = @()
    if ($s.genres) { $grayParts += [string]$s.genres }
    if ($s.runtime) { $rm = [int]$s.runtime; $grayParts += ('{0}h {1:00}m' -f [int][Math]::Floor($rm / 60), ($rm % 60)) }
    if ($grayParts.Count -gt 0) {
        $rest = $grayParts -join $bullet
        if ($s.rating) { $rest = $bullet + $rest }
        $g.DrawString($rest, $fMeta, $grayB, [single]$mx, [single]$y)
    }
    $y += $hMeta
    if ($plotH -gt 0) {
        $rectF = New-Object System.Drawing.RectangleF([single]$tx, [single]($y + $sp2), [single]$text_w, [single]$plotH)
        $g.DrawString([string]$s.overview, $fBody, $plotB, $rectF, $fmt)
        $y += $hPlot
    }
    if ($credit) {
        $g.DrawString($credit, $fCredit, $grayB, [single]$tx, [single]($y + $sp2))
    }

    $g.Dispose()
    if ($poster) { $poster.Dispose() }
    if ($backdrop) { $backdrop.Dispose() }

    # ---- export raw BGRA ----
    $rect = New-Object System.Drawing.Rectangle(0, 0, $cardW, $cardH)
    $data = $card.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $len = $data.Stride * $cardH
    $buf = New-Object byte[] $len
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
    $card.UnlockBits($data); $card.Dispose()

    # ---- optional HDR encode: sRGB -> BT.2020 + PQ at RefNits (so mpv displays it correctly on HDR) ----
    if ($hdrEncode) { [TmdbHdr]::Encode($buf, $refNits) }

    $tmpOut = "$($s.out).tmp"
    [System.IO.File]::WriteAllBytes($tmpOut, $buf)
    if (Test-Path $s.out) { Remove-Item -LiteralPath $s.out -Force }
    Move-Item -LiteralPath $tmpOut -Destination $s.out -Force

    Write-Output "$cardW $cardH"
    exit 0
}
catch {
    Write-Output "ERR [line $($_.InvocationInfo.ScriptLineNumber)] $($_.Exception.GetType().Name): $($_.Exception.Message)"
    exit 1
}
