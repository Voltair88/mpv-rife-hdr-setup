#requires -version 5
# tmdb_card.ps1 -- render the whole movie/TV info card (backdrop + dark panel + poster + text)
# into ONE BGRA buffer for a single mpv overlay-add. Avoids the ASS-vs-bitmap z-order conflict.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tmdb_card.ps1 -Spec <json-file>
# Prints "<cardW> <cardH>" on success; "ERR <message>" + exit 1 on failure.
#
# The layout is computed at a natural size then UNIFORMLY scaled to fit within max_w x max_h
# (the window minus margins) so the card is never clipped in a small / non-fullscreen window.
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
    # Available room for the card (window minus margins). Falls back to full size for old specs.
    $maxW = if ($s.max_w) { [int]$s.max_w } else { $Wd }
    $maxH = if ($s.max_h) { [int]$s.max_h } else { $H }
    $pwReq = [int]$s.poster_width
    $baseTextW = [Math]::Max(440, [Math]::Min(900, [int]($Wd * 0.26)))

    $hdrEncode = [bool]$s.hdr_encode
    $refNits = if ($s.ref_nits) { [double]$s.ref_nits } else { 203.0 }
    $iaBd = New-ColorAttrs 1.0 0.42 1.0   # backdrop only dimmed for legibility (no color change)

    $poster = Get-Img $s.poster_url
    $backdrop = $null
    if ($s.show_backdrop) { $backdrop = Get-Img $s.backdrop_url }
    $posterAspect = if ($poster) { $poster.Height / $poster.Width } else { 0 }

    $PX = [System.Drawing.GraphicsUnit]::Pixel
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisWord
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit

    $tmp = New-Object System.Drawing.Bitmap(1, 1)
    $mg = [System.Drawing.Graphics]::FromImage($tmp)
    $mg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    function LineH($font) { return [int][Math]::Ceiling($mg.MeasureString('Ag', $font).Height) }

    # content strings (independent of scale)
    $title = [string]$s.title
    if ($s.year) { $title = "$title ($($s.year))" }
    $tagline = [string]$s.tagline
    $creditParts = @()
    if ($s.director) { $creditParts += "Dir  $($s.director)" }
    if ($s.cast) { $creditParts += "Cast  $($s.cast)" }
    $credit = if ($creditParts.Count -gt 0) { $creditParts -join ("    " + [char]0x2022 + "    ") } else { $null }

    # Compute the full layout for a given uniform scale (1.0 = natural). Returns a hashtable.
    function Compute-Layout([double]$scale) {
        $Hu = $H * $scale
        $pad = [int][Math]::Round($Hu * 0.020)
        $gap = [int][Math]::Round($Hu * 0.020)
        $radius = [int][Math]::Round($Hu * 0.012)
        $sp1 = [int][Math]::Round($Hu * 0.012)
        $sp2 = [int][Math]::Round($Hu * 0.016)
        $sp_small = [int][Math]::Round($Hu * 0.008)
        $title_fs = [Math]::Max(6, [int][Math]::Round($Hu * 0.030))
        $meta_fs = [Math]::Max(5, [int][Math]::Round($Hu * 0.0195))
        $body_fs = [Math]::Max(4, [int][Math]::Round($Hu * 0.016))
        $tagline_fs = [Math]::Max(4, [int][Math]::Round($meta_fs * 0.92))
        $credit_fs = [Math]::Max(4, [int][Math]::Round($body_fs * 0.92))
        $plotPrefW = [int][Math]::Round($baseTextW * $scale)   # preferred plot wrap width

        $fTitle = New-Object System.Drawing.Font('Segoe UI', $title_fs, [System.Drawing.FontStyle]::Bold, $PX)
        $fTag = New-Object System.Drawing.Font('Segoe UI', $tagline_fs, [System.Drawing.FontStyle]::Italic, $PX)
        $fMeta = New-Object System.Drawing.Font('Segoe UI', $meta_fs, [System.Drawing.FontStyle]::Regular, $PX)
        $fMetaB = New-Object System.Drawing.Font('Segoe UI', $meta_fs, [System.Drawing.FontStyle]::Bold, $PX)
        $fBody = New-Object System.Drawing.Font('Segoe UI', $body_fs, [System.Drawing.FontStyle]::Regular, $PX)
        $fCredit = New-Object System.Drawing.Font('Segoe UI', $credit_fs, [System.Drawing.FontStyle]::Regular, $PX)

        # The title and meta rows are single (un-wrapped) lines, so the text column must be wide
        # enough for the WIDEST of them or they overflow the card's right edge. Measure exactly as
        # drawn (mixed fonts), then size text_w to fit; the plot wraps within that width.
        $metaW = 0.0
        if ($s.rating) {
            $rt = ([char]0x2605) + ' ' + ('{0:0.0}' -f [double]$s.rating)
            $metaW += $mg.MeasureString($rt, $fMetaB).Width
            if ($s.rating_note) { $metaW += $mg.MeasureString(' ' + [string]$s.rating_note, $fMeta).Width }
        }
        $bulletStr = '   ' + [char]0x2022 + '   '
        $grayParts = @()
        if ($s.genres) { $grayParts += [string]$s.genres }
        if ($s.runtime) { $rm = [int]$s.runtime; $grayParts += ('{0}h {1:00}m' -f [int][Math]::Floor($rm / 60), ($rm % 60)) }
        if ($grayParts.Count -gt 0) {
            $rest = $grayParts -join $bulletStr
            if ($s.rating) { $rest = $bulletStr + $rest }
            $metaW += $mg.MeasureString($rest, $fMeta).Width
        }
        $titleW = $mg.MeasureString($title, $fTitle).Width
        $text_w = [Math]::Max($plotPrefW, [Math]::Max([int][Math]::Ceiling($titleW), [int][Math]::Ceiling($metaW)))

        $pw = if ($poster) { [int][Math]::Round($pwReq * $scale) } else { 0 }
        $ph = if ($poster) { [int][Math]::Round($pw * $posterAspect) } else { 0 }
        $colGap = if ($pw -gt 0) { $gap } else { 0 }

        $plotMaxH = 5 * (LineH $fBody)
        $plotH = 0
        if ($s.overview) {
            $sz = $mg.MeasureString([string]$s.overview, $fBody, (New-Object System.Drawing.SizeF($text_w, $plotMaxH)), $fmt)
            $plotH = [int][Math]::Ceiling($sz.Height)
        }

        $hTitle = LineH $fTitle
        $hTag = if ($tagline) { $sp_small + (LineH $fTag) } else { 0 }
        $hMeta = LineH $fMeta
        $hPlot = if ($plotH -gt 0) { $sp2 + $plotH } else { 0 }
        $hCredit = if ($credit) { $sp2 + (LineH $fCredit) } else { 0 }
        $text_h = $hTitle + $hTag + $sp1 + $hMeta + $hPlot + $hCredit

        $content_h = [Math]::Max($ph, $text_h)
        $cardW = $pad + $pw + $colGap + $text_w + $pad
        $cardH = $pad + $content_h + $pad

        return @{
            pad = $pad; radius = $radius; sp1 = $sp1; sp2 = $sp2; sp_small = $sp_small
            pw = $pw; ph = $ph; colGap = $colGap; text_w = $text_w
            fTitle = $fTitle; fTag = $fTag; fMeta = $fMeta; fMetaB = $fMetaB; fBody = $fBody; fCredit = $fCredit
            hTitle = $hTitle; hTag = $hTag; hMeta = $hMeta; hPlot = $hPlot; hCredit = $hCredit
            plotH = $plotH; text_h = $text_h; content_h = $content_h; cardW = $cardW; cardH = $cardH
        }
    }

    # 1st pass natural, then uniformly shrink to fit the window (with a small safety margin).
    $L = Compute-Layout 1.0
    $fit = [Math]::Min(1.0, [Math]::Min($maxW / [double]$L.cardW, $maxH / [double]$L.cardH))
    if ($fit -lt 1.0) { $L = Compute-Layout ($fit * 0.98) }

    $pad = $L.pad; $radius = $L.radius; $sp1 = $L.sp1; $sp2 = $L.sp2; $sp_small = $L.sp_small
    $pw = $L.pw; $ph = $L.ph; $colGap = $L.colGap; $text_w = $L.text_w
    $content_h = $L.content_h; $text_h = $L.text_h; $cardW = $L.cardW; $cardH = $L.cardH

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
    if ($poster -and $pw -gt 0) {
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
    $tagB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 176, 176, 176))
    $goldB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 200, 64))

    $y = $ty
    $g.DrawString($title, $L.fTitle, $white, [single]$tx, [single]$y)
    $y += $L.hTitle
    if ($tagline) {
        $g.DrawString($tagline, $L.fTag, $tagB, [single]$tx, [single]($y + $sp_small))
        $y += $L.hTag
    }
    $y += $sp1
    # meta row: gold rating, optional "(series/episode)" source label, then gray "• genres • runtime"
    $mx = $tx
    $bullet = "   " + [char]0x2022 + "   "
    if ($s.rating) {
        $rt = ([char]0x2605) + " " + ('{0:0.0}' -f [double]$s.rating)
        $g.DrawString($rt, $L.fMetaB, $goldB, [single]$mx, [single]$y)
        $mx += $mg.MeasureString($rt, $L.fMetaB).Width
        if ($s.rating_note) {
            $note = " " + [string]$s.rating_note
            $g.DrawString($note, $L.fMeta, $grayB, [single]$mx, [single]$y)
            $mx += $mg.MeasureString($note, $L.fMeta).Width
        }
    }
    $grayParts = @()
    if ($s.genres) { $grayParts += [string]$s.genres }
    if ($s.runtime) { $rm = [int]$s.runtime; $grayParts += ('{0}h {1:00}m' -f [int][Math]::Floor($rm / 60), ($rm % 60)) }
    if ($grayParts.Count -gt 0) {
        $rest = $grayParts -join $bullet
        if ($s.rating) { $rest = $bullet + $rest }
        $g.DrawString($rest, $L.fMeta, $grayB, [single]$mx, [single]$y)
    }
    $y += $L.hMeta
    if ($L.plotH -gt 0) {
        $rectF = New-Object System.Drawing.RectangleF([single]$tx, [single]($y + $sp2), [single]$text_w, [single]$L.plotH)
        $g.DrawString([string]$s.overview, $L.fBody, $plotB, $rectF, $fmt)
        $y += $L.hPlot
    }
    if ($credit) {
        $g.DrawString($credit, $L.fCredit, $grayB, [single]$tx, [single]($y + $sp2))
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
