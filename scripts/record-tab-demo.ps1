param([ValidateSet('zh','en','ja')][string]$Lang = 'en')
# v1.3.0 demo GIF: three localized cards (bound to the three REAL demo claude PIDs)
# -> hover + click each card -> the VS Code terminal tab visibly switches three times.
# Every take self-verifies: after each click the jump-ack matchedPid must equal that
# session's real terminal shell PID, or the take is declared FAIL.
# Two-window gotcha handled: MainWindowHandle is per-PROCESS, so the resident's jump
# cache must be rebuilt while the demo window owns the foreground (work windows are
# minimized first, cache-poisoning entries flushed by a resident restart).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,PresentationCore,WindowsBase
Add-Type -Name D -Namespace W3 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
[DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder sb, int max);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
public struct RECT { public int L; public int T; public int R; public int B; }
'@
[W3.D]::SetProcessDPIAware() | Out-Null

$dataDir = Join-Path $env:USERPROFILE '.claude\pet-data'
$sessDir = Join-Path $dataDir 'sessions'
$petCode = 'C:\Users\28608\claude-pet\pet'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$nowMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

function Restart-Resident {
  $pidFile = Join-Path $dataDir 'pet.pid'
  $rp = 0; [void][int]::TryParse(((Get-Content $pidFile -ErrorAction SilentlyContinue) + ''), [ref]$rp)
  if ($rp -gt 0) {
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$rp" -ErrorAction SilentlyContinue
    if ($ci -and $ci.Name -match 'powershell' -and $ci.CommandLine -match 'pet-resident') {
      Stop-Process -Id $rp -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500
    }
  }
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$petCode\pet-resident.ps1"
}

# --- map the three demo sessions (by prompt keyword) to their real pids/shells ---
# Only TERMINAL-hosted claudes qualify: the VS Code extension / subagents also spawn
# claude processes (claude-parented, no terminal shell) and can even resume a tab's
# session and hijack its pid field -- requiring parent==pwsh filters all of those out.
# Newest matching session file wins when a keyword matches more than one.
$topics = @{ mutex = 'mutex'; haiku = 'haiku'; tcp = 'TCP' }
$all = @{}
foreach ($pr in @(Get-CimInstance -Query 'SELECT ProcessId,ParentProcessId,Name FROM Win32_Process' -ErrorAction SilentlyContinue)) { $all[[int]$pr.ProcessId] = $pr }
$found = @{}
foreach ($f in @(Get-ChildItem $sessDir -File | Where-Object { $_.Name -notmatch '\.' } | Sort-Object LastWriteTime -Descending)) {
  $c = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
  $p = $c -split "`t"; if ($p.Count -lt 7) { continue }
  $cp = 0; [void][int]::TryParse($p[6], [ref]$cp)
  if ($cp -le 0 -or -not $all.ContainsKey($cp) -or $all[$cp].Name -ne 'claude.exe') { continue }
  $par = [int]$all[$cp].ParentProcessId
  if (-not $all.ContainsKey($par) -or $all[$par].Name -ne 'pwsh.exe') { continue }
  foreach ($k in @($topics.Keys)) {
    if (-not $found.ContainsKey($k) -and $p[2] -match $topics[$k]) { $found[$k] = @{ model = $p[5]; cpid = $cp; shell = $par; detail = $(if ($p.Count -ge 4) { $p[3] } else { '' }) } }
  }
}
if ($found.Count -ne 3) { throw "expected 3 terminal-hosted demo sessions, found $($found.Count)" }

# --- find demo vs work VS Code windows by title ---
$codePids = @(Get-Process -Name Code -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
$winList = New-Object System.Collections.ArrayList
$cb = [W3.D+EnumWindowsProc]{ param($h, $lp)
  $wpid = [uint32]0; [void][W3.D]::GetWindowThreadProcessId($h, [ref]$wpid)
  if (($codePids -contains $wpid) -and [W3.D]::IsWindowVisible($h)) {
    $sb = New-Object System.Text.StringBuilder(512); [void][W3.D]::GetWindowText($h, $sb, 512)
    if ($sb.Length -gt 0) { [void]$winList.Add(@{ h = $h; title = $sb.ToString() }) }
  }
  return $true
}
[void][W3.D]::EnumWindows($cb, [IntPtr]::Zero)
$demoWin = [IntPtr]::Zero; $workWins = @()
foreach ($wi in $winList) {
  if ($wi.title -match ' - demo - ') { $demoWin = $wi.h } else { $workWins += $wi.h }
}
if ($demoWin -eq [IntPtr]::Zero) { throw 'demo VS Code window not found (title must contain " - demo - ")' }

# --- localized demo cards, each bound to its session's REAL pid ---
# all three cards are DONE on purpose: the tabs really do hold finished conversations,
# and a "thinking" card opening onto a finished answer would be a staged lie. Details
# echo each session's real answer, so card and content visibly agree.
$T = @{
  zh = @{ mutex = @('done','已完成','解释 mutex 是什么','互斥锁: 同一时刻只有一个线程')
          haiku = @('done','已完成','写一首 terminal 俳句','黑屏微微亮,光标闪烁如呼吸')
          tcp   = @('done','已完成','TCP vs UDP 一句话','TCP 可靠有序,UDP 快而轻') }
  en = @{ mutex = @('done','Done','Explain what a mutex is','Only one thread holds it at a time')
          haiku = @('done','Done','A haiku about terminals','Terminal glows soft, cursor blinks')
          tcp   = @('done','Done','TCP vs UDP in one line','TCP is reliable, UDP is fast') }
  ja = @{ mutex = @('done','完了','mutex とは何かを説明','同時に1スレッドだけが保持')
          haiku = @('done','完了','ターミナルの俳句','一句できました')
          tcp   = @('done','完了','TCP と UDP の違い','TCP は確実,UDP は高速') }
}

# --- pet settings: save + set ---
$langPath = Join-Path $dataDir 'lang.txt'; $sndPath = Join-Path $dataDir 'sound.txt'
$oldLang = ''; if (Test-Path $langPath) { $oldLang = (Get-Content $langPath -Raw).Trim() }
$oldSnd = ''; if (Test-Path $sndPath) { $oldSnd = (Get-Content $sndPath -Raw).Trim() }
[IO.File]::WriteAllText($langPath, $Lang, $utf8)
[IO.File]::WriteAllText($sndPath, 'off', $utf8)

# --- hide ALL real cards (incl. the demo sessions' own), inject localized trio ---
$dismissed = @()
foreach ($f in @(Get-ChildItem $sessDir -File | Where-Object { $_.Name -notmatch '\.' -and $_.Name -notlike 't_demo*' })) {
  $dp = "$($f.FullName).dismiss"
  if (-not (Test-Path $dp)) { [IO.File]::WriteAllText($dp, "$($nowMs + 600000)", $utf8); $dismissed += $dp }
}
$rows = $T[$Lang]
$order = @('mutex','haiku','tcp')   # row0 attention / row1 thinking / row2 done
for ($i = 0; $i -lt 3; $i++) {
  $k = $order[$i]; $r = $rows[$k]
  $mdl = ''; if ($r[0] -eq 'done') { $mdl = $found[$k].model }
  # detail = the REAL first-sentence summary the pet itself extracted from that
  # session's latest reply -- card text and terminal content match verbatim
  $det = $found[$k].detail; if (-not $det) { $det = $r[3] }
  $rec = ($r[0], $r[1], $r[2], $det, "$($nowMs - $i * 60000)", $mdl, "$($found[$k].cpid)") -join "`t"
  [IO.File]::WriteAllText((Join-Path $sessDir "t_demo$i"), $rec, $utf8)
}
Get-ChildItem $dataDir -Filter 'jump-req-*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $dataDir 'jump-ack.json') -Force -ErrorAction SilentlyContinue

# --- geometry (mirror of the resident's math) ---
$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g0.DpiX / 96.0; $g0.Dispose()
$w = [int](148 * $scale); $cardW = [int](312 * $scale)
$rowH = [int](50 * $scale); $rowGap = [int](7 * $scale); $gap = [int](8 * $scale)
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$parts = ((Get-Content (Join-Path $dataDir 'pet-pos.txt') -Raw) + '').Trim() -split ','
$px = [int]$parts[0]; $py = [int]$parts[1]
$cardH = 3 * ($rowH + $rowGap) - $rowGap
$cx = $px + [int]($w/2) - [int]($cardW/2)
if ($cx -lt ($wa.Left + 4)) { $cx = $wa.Left + 4 }
if (($cx + $cardW) -gt ($wa.Right - 4)) { $cx = $wa.Right - 4 - $cardW }
$cy = $py + $w + $gap
if (($cy + $cardH) -gt ($wa.Bottom - 4)) { $cy = $py - $cardH - $gap }
$rowY = @(); for ($i = 0; $i -lt 3; $i++) { $rowY += ($cy + $i * ($rowH + $rowGap) + [int]($rowH / 2)) }
$hoverX = $cx + [int]($cardW * 0.42)
$parkX = $cx - 90; $parkY = $rowY[0] - 30

# crop: card column + a wide slice for the demo window to its left + above
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$crX = [Math]::Max(0, $cx - 800)
$crW = [Math]::Min(($cx + $cardW + 26) - $crX, $scr.Width - $crX)
$crY = [Math]::Max(0, [Math]::Min($py - 120, $cy - 300))
$crH = [Math]::Min(($cy + $cardH + 26) - $crY, $scr.Height - $crY)
# the demo window gets resized INTO the crop, so the bottom-anchored claude TUI
# (where each session's distinct answer lives) is on camera, not below it
$dwX = $crX + 2; $dwY = $crY + 2
$dwW = ($cx - 12) - $dwX; $dwH = $crH - 8

$expected = @($found['mutex'].shell, $found['haiku'].shell, $found['tcp'].shell)
$ackPath = Join-Path $dataDir 'jump-ack.json'
$minimized = @()

try {
  # stage: work windows away -> demo window inherits foreground -> resident restart
  # rebuilds the jump cache while the demo window is the process's foreground window
  foreach ($h in $workWins) { if (-not [W3.D]::IsIconic($h)) { [void][W3.D]::ShowWindow($h, 6); $minimized += $h } }
  Start-Sleep -Milliseconds 600
  $wasMax = [W3.D]::IsZoomed($demoWin)
  $oldRect = New-Object 'W3.D+RECT'; [void][W3.D]::GetWindowRect($demoWin, [ref]$oldRect)
  [void][W3.D]::ShowWindow($demoWin, 9)   # un-maximize so SetWindowPos sticks
  [void][W3.D]::SetWindowPos($demoWin, [IntPtr]::Zero, $dwX, $dwY, $dwW, $dwH, 0x0004)   # SWP_NOZORDER
  [void][W3.D]::SetForegroundWindow($demoWin)
  Restart-Resident
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($parkX, $parkY)
  Start-Sleep -Milliseconds 8200   # resident up + card render + 3x2s pre-warm cycles

  # re-stamp the dismiss shield: pet-event DELETES .dismiss on session activity
  # ("activity revives the card"), and this very command's permission prompt fires an
  # attention event for the invoking session -- its async hook lands within the first
  # few seconds, i.e. before this line. Stamp again now that the hook has come and gone.
  foreach ($f in @(Get-ChildItem $sessDir -File | Where-Object { $_.Name -notmatch '\.' -and $_.Name -notlike 't_demo*' })) {
    $dp = "$($f.FullName).dismiss"
    if (-not (Test-Path $dp) -and ($dismissed -notcontains $dp)) { $dismissed += $dp }
    [IO.File]::WriteAllText($dp, "$([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) + 600000)", $utf8)
  }
  Start-Sleep -Milliseconds 400

  # waypoints: park -> row0 hover -> click -> dwell -> row1 -> click -> dwell -> row2 -> click -> dwell
  $plan = @(
    @{t0=0.0; t1=0.8;  x0=$parkX;  y0=$parkY;    x1=$parkX;  y1=$parkY},
    @{t0=0.8; t1=1.4;  x0=$parkX;  y0=$parkY;    x1=$hoverX; y1=$rowY[0]},
    @{t0=1.4; t1=4.2;  x0=$hoverX; y0=$rowY[0];  x1=$hoverX; y1=$rowY[0]},
    @{t0=4.2; t1=4.8;  x0=$hoverX; y0=$rowY[0];  x1=$hoverX; y1=$rowY[1]},
    @{t0=4.8; t1=7.4;  x0=$hoverX; y0=$rowY[1];  x1=$hoverX; y1=$rowY[1]},
    @{t0=7.4; t1=8.0;  x0=$hoverX; y0=$rowY[1];  x1=$hoverX; y1=$rowY[2]},
    @{t0=8.0; t1=11.4; x0=$hoverX; y0=$rowY[2];  x1=$hoverX; y1=$rowY[2]}
  )
  $clickAt = @(2.2, 5.4, 8.6); $clickDone = @($false, $false, $false)
  $ackAt = @(3.6, 6.8, 10.6); $ackSnap = @('', '', ''); $ackRead = @($false, $false, $false)
  $frameMs = 150; $total = 11.4
  $frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $total) {
    $t = $sw.Elapsed.TotalSeconds
    foreach ($seg in $plan) {
      if ($t -ge $seg.t0 -and $t -lt $seg.t1) {
        $f2 = ($t - $seg.t0) / [Math]::Max(0.001, ($seg.t1 - $seg.t0))
        $mx = [int]($seg.x0 + ($seg.x1 - $seg.x0) * $f2); $my = [int]($seg.y0 + ($seg.y1 - $seg.y0) * $f2)
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($mx, $my)
        break
      }
    }
    for ($k = 0; $k -lt 3; $k++) {
      if (-not $clickDone[$k] -and $t -ge $clickAt[$k]) {
        [W3.D]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [W3.D]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        $clickDone[$k] = $true
      }
      if (-not $ackRead[$k] -and $t -ge $ackAt[$k]) {
        if (Test-Path $ackPath) { $ackSnap[$k] = [IO.File]::ReadAllText($ackPath) }
        $ackRead[$k] = $true
      }
    }
    # per-frame shield repair: any event that revives a real card mid-take gets
    # re-hidden within one frame interval (<=150ms), before most renders can catch it
    foreach ($sf in @(Get-ChildItem $sessDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.' -and $_.Name -notlike 't_demo*' })) {
      $dp2 = "$($sf.FullName).dismiss"
      if (-not (Test-Path $dp2)) {
        [IO.File]::WriteAllText($dp2, "$([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) + 600000)", $utf8)
        if ($dismissed -notcontains $dp2) { $dismissed += $dp2 }
      }
    }
    $bmp = New-Object System.Drawing.Bitmap $crW, $crH
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($crX, $crY, 0, 0, (New-Object System.Drawing.Size($crW, $crH)))
    $cp = [System.Windows.Forms.Cursor]::Position
    $fx = $cp.X - $crX; $fy = $cp.Y - $crY
    if ($fx -ge 0 -and $fy -ge 0 -and $fx -lt $crW -and $fy -lt $crH) {
      $g.FillEllipse([System.Drawing.Brushes]::White, ($fx - 7), ($fy - 7), 14, 14)
      $g.FillEllipse([System.Drawing.Brushes]::Black, ($fx - 5), ($fy - 5), 10, 10)
    }
    $g.Dispose()
    $frames.Add($bmp)
    $lag = $frameMs - ($sw.Elapsed.TotalMilliseconds % $frameMs)
    Start-Sleep -Milliseconds ([int][Math]::Max(1, $lag))
  }
  $sw.Stop()

  # --- verify each click against its ack (proof, not vibes) ---
  $verdicts = @()
  for ($k = 0; $k -lt 3; $k++) {
    $v = 'FAIL'
    if ($ackSnap[$k]) {
      $a = $null; try { $a = $ackSnap[$k] | ConvertFrom-Json } catch {}
      if ($a -and [int]$a.matchedPid -eq $expected[$k]) { $v = 'OK' }
    }
    $verdicts += "click$k expected shell=$($expected[$k]) -> $v ($($ackSnap[$k]))"
  }

  # --- encode GIF ---
  $enc = New-Object System.Windows.Media.Imaging.GifBitmapEncoder
  foreach ($bmp in $frames) {
    $hb = $bmp.GetHbitmap()
    $srcImg = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap($hb, [IntPtr]::Zero, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($srcImg))
    [void][W3.D]::DeleteObject($hb)
  }
  $ms2 = New-Object System.IO.MemoryStream
  $enc.Save($ms2)
  $bytes = $ms2.ToArray(); $ms2.Dispose()
  foreach ($bmp in $frames) { $bmp.Dispose() }
  $gctSize = 0
  if ($bytes[10] -band 0x80) { $gctSize = 3 * [int][Math]::Pow(2, ($bytes[10] -band 7) + 1) }
  $insertAt = 13 + $gctSize
  $loopExt = [byte[]](0x21,0xFF,0x0B,0x4E,0x45,0x54,0x53,0x43,0x41,0x50,0x45,0x32,0x2E,0x30,0x03,0x01,0x00,0x00,0x00)
  $outList = New-Object System.Collections.Generic.List[byte]
  $outList.AddRange([byte[]]$bytes[0..($insertAt-1)]); $outList.AddRange($loopExt); $outList.AddRange([byte[]]$bytes[$insertAt..($bytes.Length-1)])
  $bytes = $outList.ToArray()
  $delay = [int]($frameMs / 10)
  for ($i = 0; $i -lt $bytes.Length - 7; $i++) {
    if ($bytes[$i] -eq 0x21 -and $bytes[$i+1] -eq 0xF9 -and $bytes[$i+2] -eq 0x04) {
      $bytes[$i+4] = [byte]($delay -band 0xFF); $bytes[$i+5] = [byte](($delay -shr 8) -band 0xFF)
      $i += 7
    }
  }
  $out = "C:\Users\28608\claude-pet\docs\demo-tab-v130-$Lang.gif"
  [IO.File]::WriteAllBytes($out, $bytes)
  Write-Output ("saved {0}  frames={1}  size={2}KB" -f $out, $frames.Count, [int]((Get-Item $out).Length / 1KB))
  foreach ($v in $verdicts) { Write-Output $v }
  $okAll = @($verdicts | Where-Object { $_ -match '-> OK' }).Count
  Write-Output ("RESULT: " + $(if ($okAll -eq 3) { 'PASS' } else { 'FAIL' }) + " ($okAll/3 clicks proven)")
}
finally {
  for ($i = 0; $i -lt 3; $i++) { Remove-Item (Join-Path $sessDir "t_demo$i") -Force -ErrorAction SilentlyContinue }
  foreach ($dp in $dismissed) { Remove-Item $dp -Force -ErrorAction SilentlyContinue }
  if ($oldLang) { [IO.File]::WriteAllText($langPath, $oldLang, $utf8) } else { Remove-Item $langPath -Force -ErrorAction SilentlyContinue }
  if ($oldSnd) { [IO.File]::WriteAllText($sndPath, $oldSnd, $utf8) } else { Remove-Item $sndPath -Force -ErrorAction SilentlyContinue }
  if ($wasMax) { [void][W3.D]::ShowWindow($demoWin, 3) }
  else { [void][W3.D]::SetWindowPos($demoWin, [IntPtr]::Zero, $oldRect.L, $oldRect.T, ($oldRect.R - $oldRect.L), ($oldRect.B - $oldRect.T), 0x0004) }
  foreach ($h in $minimized) { [void][W3.D]::ShowWindow($h, 9) }
  Restart-Resident   # rebuild the jump cache under normal window conditions
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(60, 60)
}
