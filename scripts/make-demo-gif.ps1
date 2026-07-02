# Renders the promo demo GIF (docs/demo.gif) entirely offscreen -- no live pet, no
# screen capture. Reuses the real mascot PNGs (pet/claude-*.png) and replicates the
# status-card look from pet-resident.ps1, then encodes with ffmpeg (palettegen).
# Story: card 1 "Ship the release?" cycles  needs-input -> thinking -> done,  looping;
# card 2 stays thinking (spinner), card 3 stays done. Done cards carry the v1.0.7
# model badge (different models per session); mid-turn cards never do.
# Requires ffmpeg on PATH.
Add-Type -AssemblyName System.Drawing

$repo   = Split-Path $PSScriptRoot -Parent
$petDir = Join-Path $repo 'pet'
$outDir = Join-Path $repo 'docs'
$tmp    = Join-Path $env:TEMP 'claude-pet-gif-frames'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$S       = 1.2
$cardW   = [int](312*$S)
$rowH    = [int](50*$S)
$m       = [int](14*$S)
$rc      = [int](14*$S)
$mascotW = [int](148*$S)
$pad     = 24
$canvasW = $cardW + 2*$pad
$cardX   = $pad
$cardY   = 150
$canvasH = $cardY + 3*$rowH + 22

$bg     = [System.Drawing.Color]::FromArgb(24,24,28)
$cream  = [System.Drawing.Color]::FromArgb(250,249,245)
$titleC = [System.Drawing.Color]::FromArgb(45,45,50)
$col = @{
  thinking  = [System.Drawing.Color]::FromArgb(60,130,210)
  attention = [System.Drawing.Color]::FromArgb(225,150,40)
  done      = [System.Drawing.Color]::FromArgb(70,170,90)
}
$fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', [single](10.5*$S), [System.Drawing.FontStyle]::Bold)
$fState = New-Object System.Drawing.Font('Microsoft YaHei UI', [single](9.5*$S))
$fSpin  = New-Object System.Drawing.Font('Consolas', [single](11*$S), [System.Drawing.FontStyle]::Bold)

$mid   = [char]0x00B7
$check = [char]0x2713
$spinChars = @(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F) | ForEach-Object { [char]$_ }

$frames = @{
  idle  = [System.Drawing.Image]::FromFile((Join-Path $petDir 'claude-idle.png'))
  blink = [System.Drawing.Image]::FromFile((Join-Path $petDir 'claude-blink.png'))
  happy = [System.Drawing.Image]::FromFile((Join-Path $petDir 'claude-happy.png'))
}

function RoundRect($g,$x,$y,$w,$h,$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x,$y,$r,$r,180,90); $p.AddArc($x+$w-$r,$y,$r,$r,270,90)
  $p.AddArc($x+$w-$r,$y+$h-$r,$r,$r,0,90); $p.AddArc($x,$y+$h-$r,$r,$r,90,90); $p.CloseAllFigures()
  return $p
}
function DrawRow($g,$i,$title,$state,$detail,$key,$spinIdx,$model) {
  $base = $cardY + $i*$rowH
  $g.DrawString($title, $fTitle, (New-Object System.Drawing.SolidBrush $titleC), ($cardX+$m), ($base + [int](5*$S)))
  $parts = @(); if ($model) { $parts += $model }; $parts += $state; if ($detail) { $parts += $detail }
  $line = $parts -join "  $mid  "
  $g.DrawString($line, $fState, (New-Object System.Drawing.SolidBrush $col[$key]), ($cardX+$m), ($base + [int](26*$S)))
  $sx = $cardX + $cardW - $m - [int](17*$S); $sy = $base + [int](25*$S)
  $sb = New-Object System.Drawing.SolidBrush $col[$key]
  if ($key -eq 'thinking')      { $g.DrawString($spinChars[$spinIdx % $spinChars.Count], $fSpin, $sb, $sx, $sy) }
  elseif ($key -eq 'done')      { $g.DrawString($check, $fSpin, $sb, $sx, $sy) }
  elseif ($key -eq 'attention') { $g.DrawString('!', $fSpin, $sb, ($sx + [int](4*$S)), $sy) }
}

# timeline @ 10fps
$FPS = 10
$phases = @()
0..13  | ForEach-Object { $phases += 'attention' }   # 1.4s needs-input
14..31 | ForEach-Object { $phases += 'thinking' }    # 1.8s thinking
32..49 | ForEach-Object { $phases += 'done' }        # 1.8s done
$N = $phases.Count

for ($f = 0; $f -lt $N; $f++) {
  $bmp = New-Object System.Drawing.Bitmap($canvasW, $canvasH)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.Clear($bg)

  # mascot: gentle bob; blink briefly; happy during done onset
  $bob = [int][math]::Round(4 * [math]::Sin($f * 0.4))
  $mf = 'idle'
  if ($phases[$f] -eq 'done' -and $f -lt 38) { $mf = 'happy' }
  elseif (($f % 24) -ge 22) { $mf = 'blink' }
  $mx = [int](($canvasW - $mascotW)/2); $my = 2 + $bob
  $g.DrawImage($frames[$mf], $mx, $my, $mascotW, $mascotW)

  # card background
  $path = RoundRect $g $cardX $cardY $cardW ($rowH*3) $rc
  $g.FillPath((New-Object System.Drawing.SolidBrush $cream), $path)

  # row 0: the hero card, cycling; the model badge appears only once the turn is done
  switch ($phases[$f]) {
    'attention' { DrawRow $g 0 'Ship the release?' 'Needs your input' 'waiting for your OK' 'attention' 0 '' }
    'thinking'  { DrawRow $g 0 'Ship the release?' 'Thinking' 'applying your changes' 'thinking' $f '' }
    'done'      { DrawRow $g 0 'Ship the release?' 'Done' 'released' 'done' 0 'Opus 4.8' }
  }
  DrawRow $g 1 'Refactor the auth module' 'Thinking' 'reading the codebase' 'thinking' ($f+3) ''
  DrawRow $g 2 'Run the test suite' 'Done' '42 passed, 0 failed' 'done' 0 'Fable 5'

  $g.Dispose()
  $bmp.Save((Join-Path $tmp ('f{0:D3}.png' -f $f)), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
foreach ($im in $frames.Values) { $im.Dispose() }
"rendered $N frames @ ${canvasW}x${canvasH} -> $tmp"
