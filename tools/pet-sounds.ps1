# Generates soft BELL/MARIMBA-like notification chimes (done.wav / attn.wav).
# v3 (best-practice tuned):
#   done = lower, ascending, SHORT (<=~0.3s salient), warm near-harmonic timbre  -> "success"
#   attn = a gentle rising "your turn" two-note (warm timbre, NOT an alarm) -- companion-style.
#          (Industrial-urgency tricks are wrong here: the user hears it many times a day, so
#           personality / low annoyance matters more than raw urgency.)
# Smooth sine partials + fast attack + exponential decay; quiet; follows system volume.
# lives in tools/ (dev-only); writes the chimes into the sibling pet/ dir (the shipped assets)
$dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet'

$partialsWarm = @(
  @{ mult = 1.00; amp = 1.00; decay = 1.0 },
  @{ mult = 2.00; amp = 0.45; decay = 1.8 },
  @{ mult = 3.01; amp = 0.20; decay = 2.8 }
)

function New-Chime {
  param([object[]]$notes, [string]$out, [double]$peak, [object[]]$partials, [double]$decayScale = 1.0)
  $sr = 44100
  $norm = ($partials | Measure-Object -Property amp -Sum).Sum
  $samples = New-Object 'System.Collections.Generic.List[int16]'
  foreach ($n in $notes) {
    $freq = [double]$n.freq
    $cnt  = [int]($sr * ([double]$n.ms / 1000.0))
    $atk  = [int]($sr * 0.010)
    $rel  = [int]($sr * 0.010)
    $tau  = ($cnt / 3.0) * $decayScale
    for ($i = 0; $i -lt $cnt; $i++) {
      $a = 1.0
      if ($i -lt $atk) { $a = $i / $atk }
      if ($i -gt ($cnt - $rel)) { $a = $a * [math]::Max(0.0, ($cnt - $i) / $rel) }
      $v = 0.0
      foreach ($p in $partials) {
        $env = [math]::Exp(-$i / ($tau / $p.decay))
        $v += [math]::Sin(2 * [math]::PI * $freq * $p.mult * $i / $sr) * $p.amp * $env
      }
      $v = ($v / $norm) * $peak * $a
      if ($v -gt 1.0) { $v = 1.0 } elseif ($v -lt -1.0) { $v = -1.0 }
      $samples.Add([int16][math]::Round($v * 32767))
    }
    $g = [int]($sr * ([double]$n.gap / 1000.0))
    for ($i = 0; $i -lt $g; $i++) { $samples.Add([int16]0) }
  }
  $dataLen = $samples.Count * 2
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
  $bw.Write([uint32](36 + $dataLen))
  $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
  $bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
  $bw.Write([uint32]16); $bw.Write([uint16]1); $bw.Write([uint16]1)
  $bw.Write([uint32]$sr); $bw.Write([uint32]($sr * 2)); $bw.Write([uint16]2); $bw.Write([uint16]16)
  $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([uint32]$dataLen)
  foreach ($s in $samples) { $bw.Write([int16]$s) }
  $bw.Flush()
  [System.IO.File]::WriteAllBytes($out, $ms.ToArray())
  $bw.Dispose(); $ms.Dispose()
}

# done: D5 -> G5, warm, connected "ding~da"; lower-priority -> quieter, shorter tail
New-Chime -notes @(@{freq=587;ms=120;gap=10}, @{freq=784;ms=230;gap=0}) -out (Join-Path $dir 'done.wav') -peak 0.205 -partials $partialsWarm -decayScale 1.0
# attn: rising "your turn" two taps; ACTION-required -> louder + a bit more sustain (higher RMS than done)
New-Chime -notes @(@{freq=720;ms=95;gap=65}, @{freq=960;ms=150;gap=0}) -out (Join-Path $dir 'attn.wav') -peak 0.33 -partials $partialsWarm -decayScale 1.15
"done.wav $((Get-Item (Join-Path $dir 'done.wav')).Length) bytes; attn.wav $((Get-Item (Join-Path $dir 'attn.wav')).Length) bytes"
