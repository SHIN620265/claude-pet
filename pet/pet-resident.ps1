# Claude spark mascot - RESIDENT desktop pet with per-session status cards.
# Pet: transparent per-pixel-alpha layered window (DPI-aware, draggable, blink, gentle bob).
# Cards: one stacked card per live Claude Code session (sessions\<id>), showing the
#        conversation title + state (thinking/attention/done/idle) with a braille spinner.
#        Per row: [x] dismisses that card (reappears on new activity); double-click the
#        title to rename it (locked so auto-updates won't overwrite).
# Lifecycle: exits when all Claude Code (claude.exe) instances are gone.
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cs = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class PetWin : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00080000; cp.ExStyle |= 0x00000008; cp.ExStyle |= 0x00000080; cp.ExStyle |= 0x08000000;
            return cp; }
    }
}
public class CardWin : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x00000008; cp.ExStyle |= 0x00000080; return cp; }
    }
}
public static class Lp {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    public static void EnableDpi(){ try { SetProcessDpiAwarenessContext((IntPtr)(-4)); } catch { try { SetProcessDPIAware(); } catch {} } }
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int pquns);
    public static bool CanNotify(){ try { int s = 5; SHQueryUserNotificationState(out s); return s == 5; } catch { return true; } }   // 5 = QUNS_ACCEPTS_NOTIFICATIONS
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint a, uint b, ref int c, uint d);
    public static bool AnimationsOn(){ try { int v = 1; SystemParametersInfo(0x1042, 0, ref v, 0); return v != 0; } catch { return true; } }   // 0x1042 = SPI_GETCLIENTAREAANIMATION
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    public static void Top(IntPtr h){ try { SetWindowPos(h, (IntPtr)(-1), 0, 0, 0, 0, 0x0013); } catch {} }   // HWND_TOPMOST + NOSIZE|NOMOVE|NOACTIVATE
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x,int y){X=x;Y=y;} }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; public SIZE(int x,int y){cx=x;cy=y;} }
    [StructLayout(LayoutKind.Sequential, Pack=1)] public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    public static Bitmap Prep(string path, int w, int h){
        Bitmap dst = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(dst)) {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            using (Image img = Image.FromFile(path)) g.DrawImage(img, 0, 0, w, h);
        }
        BitmapData bd = dst.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        int n = bd.Stride * bd.Height; byte[] buf = new byte[n]; Marshal.Copy(bd.Scan0, buf, 0, n);
        for (int i=0;i<n;i+=4){ byte a=buf[i+3]; buf[i]=(byte)(buf[i]*a/255); buf[i+1]=(byte)(buf[i+1]*a/255); buf[i+2]=(byte)(buf[i+2]*a/255); }
        Marshal.Copy(buf, 0, bd.Scan0, n); dst.UnlockBits(bd); return dst;
    }
    public static void SetBitmap(IntPtr hwnd, Bitmap bmp, int x, int y){
        IntPtr screenDc = GetDC(IntPtr.Zero); IntPtr memDc = CreateCompatibleDC(screenDc); IntPtr hBmp = IntPtr.Zero, old = IntPtr.Zero;
        try {
            hBmp = bmp.GetHbitmap(Color.FromArgb(0)); old = SelectObject(memDc, hBmp);
            SIZE size = new SIZE(bmp.Width, bmp.Height); POINT src = new POINT(0,0); POINT dst = new POINT(x,y);
            BLENDFUNCTION blend = new BLENDFUNCTION(); blend.BlendOp=0; blend.BlendFlags=0; blend.SourceConstantAlpha=255; blend.AlphaFormat=1;
            UpdateLayeredWindow(hwnd, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, 2);
        } finally { ReleaseDC(IntPtr.Zero, screenDc); if (old != IntPtr.Zero) SelectObject(memDc, old); if (hBmp != IntPtr.Zero) DeleteObject(hBmp); DeleteDC(memDc); }
    }
}
"@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing
[Lp]::EnableDpi()

# single-instance guard: concurrent SessionStart hooks can race past the pet.pid check
# and spawn two residents; a named mutex makes the loser exit before it touches pet.pid
$script:petMutex = New-Object System.Threading.Mutex($false, 'ClaudePetResident')
$acquired = $false
try { $acquired = $script:petMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }   # previous owner was force-killed; take over
if (-not $acquired) { return }

$code = $PSScriptRoot
$root = Join-Path $env:USERPROFILE '.claude\pet-data'
if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
# bundled assets live in the (read-only) plugin dir; mirror them into the writable data
# dir, refreshing when the shipped copy is newer (so plugin updates actually take effect)
foreach ($a in 'strings.json', 'done.wav', 'attn.wav', 'claude-idle.png', 'claude-blink.png', 'claude-happy.png') {
  $sA = Join-Path $code $a; $dA = Join-Path $root $a
  if ((Test-Path $sA) -and ((-not (Test-Path $dA)) -or ((Get-Item $sA).LastWriteTimeUtc -gt (Get-Item $dA).LastWriteTimeUtc))) { Copy-Item $sA $dA -Force }
}
$pidPath = Join-Path $root 'pet.pid'
$posPath = Join-Path $root 'pet-pos.txt'
$collapsePath = Join-Path $root 'collapsed.flag'
$sessDir = Join-Path $root 'sessions'
if (-not (Test-Path $sessDir)) { New-Item -ItemType Directory -Path $sessDir | Out-Null }
function RU($p){ if (Test-Path $p) { try { return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } catch {} } return '' }
function WU($p, $s){ [IO.File]::WriteAllText($p, $s, (New-Object Text.UTF8Encoding($false))) }
$nowMs = { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

# soft synthesized chimes (done = warm ascending; attn = higher quick double)
$script:sndDone = $null; $script:sndAttn = $null
$donePath = Join-Path $root 'done.wav'; $attnPath = Join-Path $root 'attn.wav'
if (Test-Path $donePath) { try { $script:sndDone = New-Object System.Media.SoundPlayer $donePath; $script:sndDone.Load() } catch {} }
if (Test-Path $attnPath) { try { $script:sndAttn = New-Object System.Media.SoundPlayer $attnPath; $script:sndAttn.Load() } catch {} }

# i18n: load strings.json + resolve locale (lang.txt holds a code or "auto" -> OS UI culture)
function Load-Strings {
  $script:STR = $null; $script:ALLSTR = $null
  try {
    $script:ALLSTR = (RU (Join-Path $root 'strings.json')) | ConvertFrom-Json
    $loc = ((RU (Join-Path $root 'lang.txt')) + '').Trim().ToLower()
    if (-not $loc -or $loc -eq 'auto') { $loc = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
    $nm = @($script:ALLSTR.PSObject.Properties.Name)
    if ($nm -contains $loc) { $script:STR = $script:ALLSTR.$loc }
    elseif ($nm -contains 'en') { $script:STR = $script:ALLSTR.en }
    elseif ($nm.Count -gt 0) { $script:STR = $script:ALLSTR.($nm[0]) }
  } catch {}
}
function L($key, $fallback) {
  if ($script:STR -and ($script:STR.PSObject.Properties.Name -contains $key)) { return $script:STR.$key }
  return $fallback
}
Load-Strings
$sv = ((RU (Join-Path $root 'sound.txt')) + '').Trim().ToLower(); $script:soundOn = ($sv -ne 'off')

function Set-Title($sid, $newTitle) {
  $fp = Join-Path $sessDir $sid
  $c = RU $fp; if (-not $c) { return }
  $p = $c -split "`t"; while ($p.Count -lt 5) { $p += '' }
  $p[2] = $newTitle
  $p[4] = "$(& $nowMs)"
  WU $fp ($p -join "`t")
  WU "$fp.titlelock" '1'
}
function Edit-Row($idx) {
  $sid = $script:rowSids[$idx]; if (-not $sid) { return }
  $cur = ''; $c = RU (Join-Path $sessDir $sid); if ($c) { $cur = ($c -split "`t")[2] }
  $script:editSid = $sid; $script:editing = $true
  $editBox.Bounds = $rowTitle[$idx].Bounds
  $editBox.Text = $cur
  $editBox.Visible = $true; $editBox.BringToFront()
  $card.Activate(); $editBox.Focus(); $editBox.SelectAll()
}
function Commit-Edit {
  if (-not $script:editing) { return }
  $script:editing = $false
  $t = ($editBox.Text + '').Trim()
  $editBox.Visible = $false
  if ($t -and $script:editSid) { Set-Title $script:editSid $t; $script:lastSig = '__' }
}
function Cancel-Edit {
  $script:editing = $false; $editBox.Visible = $false
}

$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g0.DpiX / 96.0; $g0.Dispose()
$w = [int](148 * $scale)
$cardW = [int](312 * $scale)
$rowH = [int](50 * $scale)
$gap = [int](8 * $scale)
$m = [int](14 * $scale)
$MAXROWS = 3

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:defX = $wa.Right - $w - [int](44 * $scale)
$script:defY = $wa.Bottom - $w - ($MAXROWS * $rowH) - $gap - [int](16 * $scale)
$script:x = $script:defX; $script:y = $script:defY
if (Test-Path $posPath) {
  $parts = ((RU $posPath) + '').Trim() -split ','
  if ($parts.Count -eq 2) {
    $px = 0; $py = 0
    if ([int]::TryParse($parts[0], [ref]$px) -and [int]::TryParse($parts[1], [ref]$py)) {
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      if ($px -ge $vs.Left -and $px -le ($vs.Right - 40) -and $py -ge $vs.Top -and $py -le ($vs.Bottom - 40)) { $script:x = $px; $script:y = $py }
    }
  }
}

$script:frames = @{
  idle  = [Lp]::Prep((Join-Path $root 'claude-idle.png'),  $w, $w)
  blink = [Lp]::Prep((Join-Path $root 'claude-blink.png'), $w, $w)
  happy = [Lp]::Prep((Join-Path $root 'claude-happy.png'), $w, $w)
}
$PID | Set-Content $pidPath -ErrorAction SilentlyContinue

$form = New-Object PetWin
$form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'
$form.Bounds = New-Object System.Drawing.Rectangle($script:x, $script:y, $w, $w)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menuClose = L 'closePet' 'Close pet'
$menuReset = L 'resetPos' 'Reset position'
$miClose = $menu.Items.Add($menuClose)
$miClose.add_Click({ Set-Content -Path (Join-Path $root 'pet-state.txt') -Value 'off'; [System.Windows.Forms.Application]::Exit() })
$miReset = $menu.Items.Add($menuReset)
$miReset.add_Click({ $script:x = $script:defX; $script:y = $script:defY; "$($script:x),$($script:y)" | Set-Content $posPath })

# sound on/off + language submenu
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSound = New-Object System.Windows.Forms.ToolStripMenuItem
$miSound.Text = L 'sound' 'Sound'
$miSound.Checked = $script:soundOn
$miSound.add_Click({ param($snd, $e) $script:soundOn = -not $script:soundOn; WU (Join-Path $root 'sound.txt') ($(if ($script:soundOn) { 'on' } else { 'off' })); $miSound.Checked = $script:soundOn })
[void]$menu.Items.Add($miSound)
$miLang = New-Object System.Windows.Forms.ToolStripMenuItem
$miLang.Text = L 'language' 'Language'
$script:langItems = @{}
if ($script:ALLSTR) {
  foreach ($code in @($script:ALLSTR.PSObject.Properties.Name)) {
    $disp = ($script:ALLSTR.$code).'_name'; if (-not $disp) { $disp = $code }
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = $disp; $it.Tag = $code
    $it.add_Click({ param($snd, $e) Set-Lang ([string]$snd.Tag) })
    [void]$miLang.DropDownItems.Add($it)
    $script:langItems[$code] = $it
  }
}
[void]$miLang.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem
$miAuto.Text = L 'auto' 'Auto'; $miAuto.Tag = 'auto'
$miAuto.add_Click({ param($snd, $e) Set-Lang 'auto' })
[void]$miLang.DropDownItems.Add($miAuto)
[void]$menu.Items.Add($miLang)

function Update-LangChecks {
  $cur = ((RU (Join-Path $root 'lang.txt')) + '').Trim().ToLower()
  $miAuto.Checked = (-not $cur -or $cur -eq 'auto')
  foreach ($k in @($script:langItems.Keys)) { $script:langItems[$k].Checked = ($k -eq $cur) }
}
function Apply-Lang {
  Load-Strings
  $miClose.Text = L 'closePet' 'Close pet'
  $miReset.Text = L 'resetPos' 'Reset position'
  $miSound.Text = L 'sound' 'Sound'
  $miLang.Text = L 'language' 'Language'
  $miAuto.Text = L 'auto' 'Auto'
  Update-LangChecks
  $script:lastSig = '__'
  $script:lastLang = ((RU (Join-Path $root 'lang.txt')) + '').Trim()
}
function Set-Lang($code) { WU (Join-Path $root 'lang.txt') $code; Apply-Lang }
Update-LangChecks
$script:lastLang = ((RU (Join-Path $root 'lang.txt')) + '').Trim()

# ---- multi-row card ----
$card = New-Object CardWin
$card.FormBorderStyle = 'None'; $card.ShowInTaskbar = $false; $card.TopMost = $true; $card.StartPosition = 'Manual'
$card.Size = New-Object System.Drawing.Size($cardW, $rowH)
$card.BackColor = [System.Drawing.Color]::FromArgb(250, 249, 245)
function Set-CardRegion($h) {
  $rc = [int](14 * $scale)
  $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
  $gp.AddArc(0,0,$rc,$rc,180,90); $gp.AddArc($cardW-$rc,0,$rc,$rc,270,90)
  $gp.AddArc($cardW-$rc,$h-$rc,$rc,$rc,0,90); $gp.AddArc(0,$h-$rc,$rc,$rc,90,90); $gp.CloseAllFigures()
  $card.Region = New-Object System.Drawing.Region($gp)
}
Set-CardRegion $rowH

$rowTitle = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowState = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowSpin  = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowClose = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowEdit  = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
for ($i = 0; $i -lt $MAXROWS; $i++) {
  $base = $i * $rowH
  $t = New-Object System.Windows.Forms.Label
  $t.AutoSize = $false; $t.AutoEllipsis = $true; $t.Tag = $i
  $t.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
  $t.ForeColor = [System.Drawing.Color]::FromArgb(45,45,50)
  $t.Location = New-Object System.Drawing.Point($m, ($base + [int](6*$scale)))
  $t.Size = New-Object System.Drawing.Size(($cardW - 2*$m - [int](38*$scale)), [int](22*$scale))
  $t.BackColor = [System.Drawing.Color]::Transparent
  $card.Controls.Add($t); $rowTitle[$i] = $t
  $s = New-Object System.Windows.Forms.Label
  $s.AutoSize = $false; $s.AutoEllipsis = $true
  $s.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
  $s.ForeColor = [System.Drawing.Color]::FromArgb(90,90,95)
  $s.Location = New-Object System.Drawing.Point($m, ($base + [int](27*$scale)))
  $s.Size = New-Object System.Drawing.Size(($cardW - 2*$m - [int](22*$scale)), [int](20*$scale))
  $s.BackColor = [System.Drawing.Color]::Transparent
  $card.Controls.Add($s); $rowState[$i] = $s
  $sp = New-Object System.Windows.Forms.Label
  $sp.AutoSize = $false; $sp.TextAlign = 'MiddleCenter'
  $sp.Font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
  $sp.ForeColor = [System.Drawing.Color]::FromArgb(60,130,210)
  $sp.Location = New-Object System.Drawing.Point(($cardW - $m - [int](16*$scale)), ($base + [int](26*$scale)))
  $sp.Size = New-Object System.Drawing.Size([int](16*$scale), [int](20*$scale))
  $sp.BackColor = [System.Drawing.Color]::Transparent
  $card.Controls.Add($sp); $rowSpin[$i] = $sp
  $xc = New-Object System.Windows.Forms.Label
  $xc.Text = 'x'; $xc.TextAlign = 'MiddleCenter'; $xc.Cursor = 'Hand'; $xc.Tag = $i
  $xc.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
  $xc.ForeColor = [System.Drawing.Color]::FromArgb(216,216,220)
  $xc.Location = New-Object System.Drawing.Point(($cardW - [int](17*$scale)), ($base + [int](4*$scale)))
  $xc.Size = New-Object System.Drawing.Size([int](14*$scale), [int](14*$scale))
  $xc.BackColor = [System.Drawing.Color]::Transparent
  $xc.add_Click({ param($snd,$e)
    $idx = [int]$snd.Tag; $sid = $script:rowSids[$idx]
    if ($sid) { WU (Join-Path $sessDir "$sid.dismiss") "$(& $nowMs)" }
  })
  $xc.add_MouseEnter({ param($snd,$e) $script:xHoverIdx = [int]$snd.Tag; $snd.ForeColor = [System.Drawing.Color]::FromArgb(220,70,70) })
  $xc.add_MouseLeave({ param($snd,$e) $script:xHoverIdx = -1; $snd.ForeColor = [System.Drawing.Color]::FromArgb(150,150,155) })
  $card.Controls.Add($xc); $xc.BringToFront(); $rowClose[$i] = $xc
  $ec = New-Object System.Windows.Forms.Label
  $ec.Text = ([char]0x270E); $ec.TextAlign = 'MiddleCenter'; $ec.Cursor = 'Hand'; $ec.Tag = $i
  $ec.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 8)
  $ec.ForeColor = [System.Drawing.Color]::FromArgb(216,216,220)
  $ec.Location = New-Object System.Drawing.Point(($cardW - [int](34*$scale)), ($base + [int](4*$scale)))
  $ec.Size = New-Object System.Drawing.Size([int](15*$scale), [int](14*$scale))
  $ec.BackColor = [System.Drawing.Color]::Transparent
  $ec.add_Click({ param($snd,$e) Edit-Row ([int]$snd.Tag) })
  $card.Controls.Add($ec); $ec.BringToFront(); $rowEdit[$i] = $ec
}

# inline edit-in-place textbox (replaces the legacy InputBox); on-brand, edit-in-place
$editBox = New-Object System.Windows.Forms.TextBox
$editBox.BorderStyle = 'FixedSingle'
$editBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$editBox.BackColor = [System.Drawing.Color]::White
$editBox.ForeColor = [System.Drawing.Color]::FromArgb(45, 45, 50)
$editBox.Visible = $false
$card.Controls.Add($editBox)
$editBox.add_KeyDown({ param($snd, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $e.SuppressKeyPress = $true; Commit-Edit }
  elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $e.SuppressKeyPress = $true; Cancel-Edit }
})
$editBox.add_LostFocus({ if ($script:editing) { Commit-Edit } })

$stateColors = @{
  thinking  = [System.Drawing.Color]::FromArgb(60,130,210)
  attention = [System.Drawing.Color]::FromArgb(225,150,40)
  done      = [System.Drawing.Color]::FromArgb(70,170,90)
  idle      = [System.Drawing.Color]::FromArgb(140,140,145)
}

# ---- state ----
$script:curFrame = ''; $script:dispX = -99999; $script:dispY = -99999
$script:bobOff = 0; $script:bobPhase = 0.0
$script:dragging = $false; $script:dragOffX = 0; $script:dragOffY = 0
$now0 = Get-Date
$script:nextBlink = $now0.AddSeconds((Get-Random -Minimum 2.4 -Maximum 4.0))
$script:blinkUntil = $now0; $script:reactUntil = $now0; $script:startAt = $now0; $script:lastClaude = $now0
$script:lastPoll = $now0; $script:lastSpin = $now0; $script:spinIdx = 0
$script:animOn = $true; try { $script:animOn = [Lp]::AnimationsOn() } catch {}; $script:lastAnimChk = $now0
$script:lastTop = $now0
$script:cardShown = $false; $script:cardH = $rowH; $script:lastSig = '__'; $script:hoverRow = -2; $script:xHoverIdx = -1
$script:lastKeys = @{}; $script:rowKeys = New-Object 'string[]' $MAXROWS; $script:rowSids = New-Object 'string[]' $MAXROWS; $script:firstPoll = $true
$script:fsDirty = $false
$script:editing = $false; $script:editSid = ''
$spinChars = @(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F) | ForEach-Object { [char]$_ }
$checkChar = [char]0x2713
$staticSpin = [char]0x2026

function Render($key) {
  $tx = $script:x; $ty = $script:y + $script:bobOff
  if ($key -ne $script:curFrame -or $tx -ne $script:dispX -or $ty -ne $script:dispY) {
    [Lp]::SetBitmap($form.Handle, $script:frames[$key], $tx, $ty); $script:curFrame = $key; $script:dispX = $tx; $script:dispY = $ty
  }
}
function Place-Card {
  $cx = $script:x + [int]($w/2) - [int]($cardW/2)
  if ($cx -lt ($wa.Left + 4)) { $cx = $wa.Left + 4 }
  if (($cx + $cardW) -gt ($wa.Right - 4)) { $cx = $wa.Right - 4 - $cardW }
  $cy = $script:y + $w + $gap
  if (($cy + $script:cardH) -gt ($wa.Bottom - 4)) { $cy = $script:y - $script:cardH - $gap }
  if ($card.Left -ne $cx -or $card.Top -ne $cy) { $card.Left = $cx; $card.Top = $cy }
}
function Update-Card {
  $now = & $nowMs
  $lng = ((RU (Join-Path $root 'lang.txt')) + '').Trim()
  if ($lng -ne $script:lastLang) { Apply-Lang }
  $snd = (((RU (Join-Path $root 'sound.txt')) + '').Trim().ToLower() -ne 'off')
  if ($snd -ne $script:soundOn) { $script:soundOn = $snd; $miSound.Checked = $snd }
  $list = @()
  foreach ($f in @(Get-ChildItem $sessDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.' })) {
    $c = RU $f.FullName; if (-not $c) { continue }
    $p = $c -split "`t"; if ($p.Count -lt 2) { continue }
    $epoch = 0L; if ($p.Count -ge 5) { [long]::TryParse($p[4], [ref]$epoch) | Out-Null }
    if (($now - $epoch) -gt 1800000) { Remove-Item $f.FullName, "$($f.FullName).dismiss", "$($f.FullName).titlelock" -Force -ErrorAction SilentlyContinue; continue }
    $dp = "$($f.FullName).dismiss"
    if (Test-Path $dp) { $de = 0L; [long]::TryParse((RU $dp), [ref]$de) | Out-Null; if ($de -ge $epoch) { continue } }
    $list += [pscustomobject]@{ sid=$f.Name; key=$p[0]; label=$p[1]; title=$p[2]; detail=$(if($p.Count -ge 4){$p[3]}else{''}); epoch=$epoch; model=$(if($p.Count -ge 6){$p[5]}else{''}) }
  }
  # minimal hybrid: float 'attention' (needs you) to the top; everything else stays newest-first
  $list = @($list | Sort-Object @{Expression={ if ($_.key -eq 'attention') { 0 } else { 1 } }}, @{Expression={ $_.epoch }; Descending=$true} | Select-Object -First $MAXROWS)

  foreach ($s in $list) {
    if ($script:lastKeys[$s.sid] -ne $s.key) {
      if (-not $script:firstPoll) {
        if ($s.key -eq 'done') { if ($script:soundOn -and [Lp]::CanNotify() -and $script:sndDone) { $script:sndDone.Play() }; $script:reactUntil = (Get-Date).AddSeconds(2.2) }
        elseif ($s.key -eq 'attention') { if ($script:soundOn -and [Lp]::CanNotify() -and $script:sndAttn) { $script:sndAttn.Play() }; $script:reactUntil = (Get-Date).AddSeconds(2.2) }
      }
      $script:lastKeys[$s.sid] = $s.key
    }
  }
  $script:firstPoll = $false

  if ((Test-Path $collapsePath) -or $list.Count -eq 0) {
    if ($script:cardShown) { $card.Hide(); $script:cardShown = $false }
    for ($i=0; $i -lt $MAXROWS; $i++){ $script:rowKeys[$i] = ''; $script:rowSids[$i] = '' }
    return
  }

  $sig = ($list | ForEach-Object { "$($_.sid)|$($_.key)|$($_.title)|$($_.detail)|$($_.model)" }) -join '##'
  if ($sig -ne $script:lastSig) {
    for ($i = 0; $i -lt $MAXROWS; $i++) {
      if ($i -lt $list.Count) {
        $s = $list[$i]
        $lab = L $s.key $s.label
        $rowTitle[$i].Text = $(if ($s.title) { $s.title } else { L 'newSession' $s.label })
        # status line: [model of the session's last reply] . state . latest input
        $parts = @(); if ($s.model) { $parts += $s.model }; $parts += $lab; if ($s.detail) { $parts += $s.detail }
        $rowState[$i].Text = ($parts -join "  $([char]0x00B7)  ")
        $col = $stateColors[$s.key]; if (-not $col) { $col = [System.Drawing.Color]::FromArgb(90,90,95) }
        $rowState[$i].ForeColor = $col
        $script:rowKeys[$i] = $s.key; $script:rowSids[$i] = $s.sid
        $rowTitle[$i].Visible = $true; $rowState[$i].Visible = $true; $rowClose[$i].Visible = $true; $rowEdit[$i].Visible = $true
      } else {
        $rowTitle[$i].Visible = $false; $rowState[$i].Visible = $false; $rowSpin[$i].Visible = $false; $rowClose[$i].Visible = $false; $rowEdit[$i].Visible = $false
        $script:rowKeys[$i] = ''; $script:rowSids[$i] = ''
      }
    }
    $h = $list.Count * $rowH
    if ($card.Height -ne $h) { $card.Height = $h; Set-CardRegion $h }
    $script:cardH = $h
    $script:lastSig = $sig
  }
  Place-Card
  if (-not $script:cardShown) { $card.Show(); $script:cardShown = $true }
}

$form.add_MouseDown({ param($s,$e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:dragging = $true; $form.Capture = $true
    $cpos = [System.Windows.Forms.Cursor]::Position; $script:dragOffX = $cpos.X - $script:x; $script:dragOffY = $cpos.Y - $script:y
  }
})
$form.add_MouseMove({ param($s,$e)
  if ($script:dragging) { $cpos = [System.Windows.Forms.Cursor]::Position; $script:x = $cpos.X - $script:dragOffX; $script:y = $cpos.Y - $script:dragOffY; $script:bobOff = 0; Render 'happy'; Place-Card }
})
$form.add_MouseUp({ param($s,$e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:dragging) { $script:dragging = $false; $form.Capture = $false; "$($script:x),$($script:y)" | Set-Content $posPath -ErrorAction SilentlyContinue }
  elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $menu.Show([System.Windows.Forms.Cursor]::Position) }
})
$form.add_DoubleClick({ if (Test-Path $collapsePath) { Remove-Item $collapsePath -Force } else { New-Item -ItemType File $collapsePath -Force | Out-Null } })

# react to session file changes instantly instead of waiting for the next poll;
# SynchronizingObject marshals the events onto the UI thread, the 120ms poll stays as fallback
$fsw = New-Object System.IO.FileSystemWatcher $sessDir
$fsw.IncludeSubdirectories = $false
$fsw.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite'
$fsw.SynchronizingObject = $form
$fsHandler = { $script:fsDirty = $true }
$fsw.add_Changed($fsHandler); $fsw.add_Created($fsHandler); $fsw.add_Deleted($fsHandler); $fsw.add_Renamed($fsHandler)
$fsw.EnableRaisingEvents = $true

$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = 60
$tick.add_Tick({
  $now = Get-Date
  if (-not $script:editing -and ($script:fsDirty -or ($now - $script:lastPoll).TotalMilliseconds -ge 120)) { $script:fsDirty = $false; $script:lastPoll = $now; Update-Card }
  if (($now - $script:lastAnimChk).TotalSeconds -ge 3) { $script:lastAnimChk = $now; try { $script:animOn = [Lp]::AnimationsOn() } catch {} }
  # keep the pet/cards above other windows (Windows silently demotes topmost on focus changes);
  # but don't fight a fullscreen game / presentation / Do-Not-Disturb
  if (-not $script:editing -and ($now - $script:lastTop).TotalSeconds -ge 2) {
    $script:lastTop = $now
    if ([Lp]::CanNotify()) { [Lp]::Top($form.Handle); if ($card.Visible) { [Lp]::Top($card.Handle) } }
  }
  $cur = [System.Windows.Forms.Cursor]::Position
  $hover = ($cur.X -ge $script:x -and $cur.X -le ($script:x + $w) -and $cur.Y -ge $script:y -and $cur.Y -le ($script:y + $w))
  if ($script:dragging) { }
  elseif ($hover -or $now -lt $script:reactUntil) { $script:bobOff = 0; Render 'happy' }
  elseif ($script:animOn) {
    $script:bobPhase += 0.16; $script:bobOff = [int][math]::Round(3 * [math]::Sin($script:bobPhase))
    if ($now -ge $script:nextBlink -and $now -ge $script:blinkUntil) { $script:blinkUntil = $now.AddMilliseconds(150); $script:nextBlink = $now.AddSeconds((Get-Random -Minimum 2.4 -Maximum 4.4)) }
    if ($now -lt $script:blinkUntil) { Render 'blink' } else { Render 'idle' }
  } else {
    $script:bobOff = 0; Render 'idle'
  }
  if ($script:cardShown -and ($now - $script:lastSpin).TotalMilliseconds -ge 90) {
    $script:lastSpin = $now; $script:spinIdx = ($script:spinIdx + 1) % $spinChars.Count
    $ch = $(if ($script:animOn) { $spinChars[$script:spinIdx] } else { $staticSpin })
    for ($i = 0; $i -lt $MAXROWS; $i++) {
      $k = $script:rowKeys[$i]
      if ($k -eq 'thinking') {
        if (-not $rowSpin[$i].Visible) { $rowSpin[$i].Visible = $true }
        $rowSpin[$i].ForeColor = [System.Drawing.Color]::FromArgb(60,130,210); $rowSpin[$i].Text = $ch
      } elseif ($k -eq 'done') {
        if (-not $rowSpin[$i].Visible) { $rowSpin[$i].Visible = $true }
        $rowSpin[$i].ForeColor = [System.Drawing.Color]::FromArgb(70,170,90)
        if ($rowSpin[$i].Text -ne $checkChar) { $rowSpin[$i].Text = $checkChar }
      } elseif ($k -eq 'attention') {
        if (-not $rowSpin[$i].Visible) { $rowSpin[$i].Visible = $true }
        $rowSpin[$i].ForeColor = [System.Drawing.Color]::FromArgb(225,150,40)
        if ($rowSpin[$i].Text -ne '!') { $rowSpin[$i].Text = '!' }
      } else {
        if ($rowSpin[$i].Visible) { $rowSpin[$i].Visible = $false; $rowSpin[$i].Text = '' }
      }
    }
  }
  # dim row action icons by default; brighten the row currently under the cursor
  $hr = -1
  if ($script:cardShown -and $card.Visible) {
    $cpos2 = [System.Windows.Forms.Cursor]::Position
    if ($card.Bounds.Contains($cpos2)) { $hr = [int][math]::Floor(($cpos2.Y - $card.Top) / $rowH) }
  }
  if ($hr -ne $script:hoverRow) {
    $script:hoverRow = $hr
    for ($i = 0; $i -lt $MAXROWS; $i++) {
      $rowEdit[$i].ForeColor = $(if ($i -eq $hr) { [System.Drawing.Color]::FromArgb(95,95,105) } else { [System.Drawing.Color]::FromArgb(216,216,220) })
      $rowClose[$i].ForeColor = $(if ($i -eq $script:xHoverIdx) { [System.Drawing.Color]::FromArgb(220,70,70) } elseif ($i -eq $hr) { [System.Drawing.Color]::FromArgb(150,150,155) } else { [System.Drawing.Color]::FromArgb(216,216,220) })
    }
  }

  if (($now - $script:startAt).TotalSeconds -ge 6 -and ($now - $script:lastClaude).TotalSeconds -ge 2) {
    $script:lastClaude = $now
    if (-not (Get-Process -Name claude -ErrorAction SilentlyContinue)) { [System.Windows.Forms.Application]::Exit() }
  }
})

$form.add_Shown({ Render 'idle'; Update-Card; $tick.Start() })
[System.Windows.Forms.Application]::Run($form)
foreach ($f in $script:frames.Values) { $f.Dispose() }
try { $fsw.EnableRaisingEvents = $false; $fsw.Dispose() } catch {}
$card.Dispose(); $form.Dispose()
Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
try { $script:petMutex.ReleaseMutex() } catch {}
try { $script:petMutex.Dispose() } catch {}
