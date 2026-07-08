Add-Type -AssemblyName System.Drawing

# lives in tools/ (dev-only); writes the sprites into the sibling pet/ dir (the shipped assets)
$dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

function B([int]$r,[int]$g2,[int]$b,[int]$a=255){ New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a,$r,$g2,$b)) }
function P([int]$r,[int]$g2,[int]$b,[single]$w=3){ New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($r,$g2,$b)), $w }

# Anthropic-warm palette
$ray     = B 217 119 87       # clay / coral  #D97757
$rayHot  = B 233 150 110      # brighter coral (excited)
$face    = B 250 247 240      # cream
$faceLn  = P 222 168 146 4
$eyeDk   = B 58 52 46
$eyeLine = P 58 52 46 8; $eyeLine.StartCap='Round'; $eyeLine.EndCap='Round'
$smile   = P 70 60 52 6; $smile.StartCap='Round'; $smile.EndCap='Round'
$blush   = B 236 150 120 150
$gold    = B 245 190 90
$mouthB  = B 95 60 55

function Star4($g,$cx,$cy,$s,$brush){
  $i = $s * 0.36
  $p = New-Object 'System.Drawing.Point[]' 8
  $p[0]=New-Object System.Drawing.Point([int]$cx,[int]($cy-$s))
  $p[1]=New-Object System.Drawing.Point([int]($cx+$i),[int]($cy-$i))
  $p[2]=New-Object System.Drawing.Point([int]($cx+$s),[int]$cy)
  $p[3]=New-Object System.Drawing.Point([int]($cx+$i),[int]($cy+$i))
  $p[4]=New-Object System.Drawing.Point([int]$cx,[int]($cy+$s))
  $p[5]=New-Object System.Drawing.Point([int]($cx-$i),[int]($cy+$i))
  $p[6]=New-Object System.Drawing.Point([int]($cx-$s),[int]$cy)
  $p[7]=New-Object System.Drawing.Point([int]($cx-$i),[int]($cy-$i))
  $g.FillPolygon($brush,$p)
}

function Make-Frame([string]$eyes, [bool]$excited, [string]$outFile){
  $W = 360; $H = 360
  $cx = 180; $cy = 184
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  # sunburst rays (the Anthropic spark)
  $rb = if ($excited) { $rayHot } else { $ray }
  $len = if ($excited) { 92 } else { 84 }
  for ($i = 0; $i -lt 12; $i++) {
    $st = $g.Save()
    $g.TranslateTransform($cx, $cy)
    $g.RotateTransform([single]($i * 30))
    $g.FillEllipse($rb, -11, -([single]($len + 66)), 22, $len)
    $g.Restore($st)
  }

  # face
  $g.FillEllipse($face, ($cx-72), ($cy-72), 144, 144)
  $g.DrawEllipse($faceLn, ($cx-72), ($cy-72), 144, 144)

  # eyes
  switch ($eyes) {
    'open' {
      $g.FillEllipse($eyeDk, ($cx-38), ($cy-18), 22, 28)
      $g.FillEllipse($eyeDk, ($cx+16), ($cy-18), 22, 28)
      $g.FillEllipse((B 255 255 255), ($cx-32), ($cy-12), 8, 8)
      $g.FillEllipse((B 255 255 255), ($cx+22), ($cy-12), 8, 8)
    }
    'blink' {
      $g.DrawArc($eyeLine, ($cx-38), ($cy-10), 22, 12, 180, 180)
      $g.DrawArc($eyeLine, ($cx+16), ($cy-10), 22, 12, 180, 180)
    }
    'happy' {
      $g.DrawArc($eyeLine, ($cx-40), ($cy-16), 24, 20, 0, 180)
      $g.DrawArc($eyeLine, ($cx+16), ($cy-16), 24, 20, 0, 180)
    }
  }

  # blush
  $g.FillEllipse($blush, ($cx-52), ($cy+8), 26, 15)
  $g.FillEllipse($blush, ($cx+26), ($cy+8), 26, 15)

  # mouth
  if ($excited) { $g.FillEllipse($mouthB, ($cx-11), ($cy+18), 22, 18) }
  else { $g.DrawArc($smile, ($cx-20), ($cy+8), 40, 26, 20, 140) }

  # sparkles when excited
  if ($excited) {
    Star4 $g ($cx+96) ($cy-86) 16 $gold
    Star4 $g ($cx-104) ($cy-40) 12 $gold
    Star4 $g ($cx+108) ($cy+44) 10 $gold
  }

  $g.Dispose()
  $out = Join-Path $dir $outFile
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  "Saved: $out ($((Get-Item $out).Length) bytes)"
}

Make-Frame 'open'  $false 'claude-idle.png'
Make-Frame 'blink' $false 'claude-blink.png'
Make-Frame 'happy' $true  'claude-happy.png'
