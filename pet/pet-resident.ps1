# Claude spark mascot - RESIDENT desktop pet with per-session status cards.
# Pet: transparent per-pixel-alpha layered window (DPI-aware, draggable, blink, gentle bob).
# Cards: one stacked card per live Claude Code session (sessions\<id>), showing the
#        conversation title + state (thinking/attention/done/idle) with a braille spinner.
#        Per row: [x] dismisses that card (reappears on new activity); the pencil icon
#        renames it (locked so auto-updates won't overwrite); a single click on the
#        title/status text jumps to that session's host window (hand cursor = jumpable).
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
// card-layering knife: a per-pixel-alpha layered card window. LAYERED+TOPMOST+TOOLWINDOW+
// NOACTIVATE (no TRANSPARENT, so it still gets mouse input). WM_NCHITTEST returns HTCLIENT
// only over a card body (a rect in HitRects, updated from PS each render) and HTTRANSPARENT
// everywhere else, so clicks on the shadow pad and inter-card gaps pass through to whatever
// is beneath -- preserving the old Region window's natural click-through.
public class LCardWin : Form {
    public int[] HitRects = new int[0];   // [x,y,w,h,...] card-body rects in client device px
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00080000; cp.ExStyle |= 0x00000008; cp.ExStyle |= 0x00000080; cp.ExStyle |= 0x08000000;
            return cp; }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0084) {   // WM_NCHITTEST
            int lp = (int)m.LParam; int sx = (short)(lp & 0xFFFF); int sy = (short)((lp >> 16) & 0xFFFF);
            Point c = PointToClient(new Point(sx, sy));
            bool body = false; int[] hr = HitRects;
            for (int i = 0; i + 3 < hr.Length; i += 4) {
                if (c.X >= hr[i] && c.X < hr[i] + hr[i+2] && c.Y >= hr[i+1] && c.Y < hr[i+1] + hr[i+3]) { body = true; break; }
            }
            m.Result = (IntPtr)(body ? 1 : -1);   // HTCLIENT : HTTRANSPARENT
            return;
        }
        base.WndProc(ref m);
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
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    public static bool IsWin(IntPtr h){ try { return IsWindow(h); } catch { return false; } }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
    public static string ClassName(IntPtr h){ try { System.Text.StringBuilder sb = new System.Text.StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); } catch { return ""; } }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int m);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    // Among visible titled top-level windows owned by a process with the SAME name as
    // `fallback`'s owner, pick the one whose title best matches `cwdPath` (the deepest cwd
    // path component appearing in a title wins). Returns `fallback` unchanged when there are
    // fewer than two such windows, or no unambiguous match -- so single-window and non-editor
    // hosts are never disturbed. Defeats the Electron multi-window trap: every VS Code window
    // shares one Code.exe, so MainWindowHandle only ever exposes one (often wrong) handle.
    public static IntPtr PickWindowForPath(string cwdPath, IntPtr fallback) {
        try {
            if (fallback == IntPtr.Zero || string.IsNullOrEmpty(cwdPath)) return fallback;
            uint fp; GetWindowThreadProcessId(fallback, out fp);
            string procName;
            try { procName = System.Diagnostics.Process.GetProcessById((int)fp).ProcessName; } catch { return fallback; }
            System.Collections.Generic.HashSet<int> pidset = new System.Collections.Generic.HashSet<int>();
            foreach (System.Diagnostics.Process pr in System.Diagnostics.Process.GetProcessesByName(procName)) pidset.Add(pr.Id);
            System.Collections.Generic.List<IntPtr> wins = new System.Collections.Generic.List<IntPtr>();
            System.Collections.Generic.List<string> titles = new System.Collections.Generic.List<string>();
            EnumWindows((h, l) => {
                if (!IsWindowVisible(h)) return true;
                if (GetWindowTextLength(h) == 0) return true;
                uint wp; GetWindowThreadProcessId(h, out wp);
                if (!pidset.Contains((int)wp)) return true;
                System.Text.StringBuilder sb = new System.Text.StringBuilder(400); GetWindowText(h, sb, 400);
                wins.Add(h); titles.Add(sb.ToString());
                return true;
            }, IntPtr.Zero);
            if (wins.Count < 2) return fallback;
            string[] parts = cwdPath.Split(new char[]{'\\','/'}, StringSplitOptions.RemoveEmptyEntries);
            int bestIdx = -1, bestScore = 0, bestCount = 0;
            for (int i = 0; i < wins.Count; i++) {
                int score = 0;
                for (int d = 0; d < parts.Length; d++) {
                    if (parts[d].Length >= 2 && titles[i].IndexOf(parts[d], StringComparison.OrdinalIgnoreCase) >= 0) {
                        if (d + 1 > score) score = d + 1;
                    }
                }
                if (score > bestScore) { bestScore = score; bestIdx = i; bestCount = 1; }
                else if (score == bestScore && score > 0) { bestCount++; }
            }
            if (bestScore == 0 || bestCount != 1) return fallback;
            return wins[bestIdx];
        } catch { return fallback; }
    }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
    // true only if the TOPMOST window under (x,y) belongs to `top`. A purely geometric
    // bounds check would light hover states THROUGH a context menu or any overlapping
    // window -- promising a click that would never reach the card.
    public static bool HitTop(IntPtr top, int x, int y){
        try { return GetAncestor(WindowFromPoint(new POINT(x, y)), 2) == top; } catch { return false; }
    }
    // Bring a top-level window to the foreground. Legit here: this only ever runs from a
    // click ON the pet, so our process holds the input/foreground grant Windows requires.
    // Fallback = the classic AttachThreadInput handshake (what window switchers use).
    public static bool Activate(IntPtr h){
        try {
            if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
            if (SetForegroundWindow(h)) return true;
            uint fgPid; uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
            uint myTid = GetCurrentThreadId();
            if (fgTid != 0 && fgTid != myTid) {
                AttachThreadInput(myTid, fgTid, true);
                bool ok = SetForegroundWindow(h);
                AttachThreadInput(myTid, fgTid, false);
                return ok;
            }
            return false;
        } catch { return false; }
    }
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
    // ---- layered-card support (card-layering knife, S1+) ----
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    // window rect in DEVICE pixels -- the single source of truth for card geometry + hit-test
    public static int[] WinRect(IntPtr h){ try { RECT r; if (GetWindowRect(h, out r)) return new int[]{ r.L, r.T, r.R, r.B }; } catch {} return new int[]{0,0,0,0}; }
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    public static int Dpi(IntPtr h){ try { uint d = GetDpiForWindow(h); if (d >= 48 && d <= 960) return (int)d; } catch {} return 96; }
    // push a STRAIGHT-alpha 32bppArgb frame: premultiply ONCE in place (caller passes a
    // throwaway per-frame bitmap) then UpdateLayeredWindow -- the single-premultiply contract (D8)
    public static void SetBitmapStraight(IntPtr hwnd, Bitmap bmp, int x, int y){
        BitmapData bd = bmp.LockBits(new Rectangle(0,0,bmp.Width,bmp.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        int n = bd.Stride * bd.Height; byte[] buf = new byte[n]; Marshal.Copy(bd.Scan0, buf, 0, n);
        for (int i=0;i<n;i+=4){ byte a=buf[i+3]; buf[i]=(byte)(buf[i]*a/255); buf[i+1]=(byte)(buf[i+1]*a/255); buf[i+2]=(byte)(buf[i+2]*a/255); }
        Marshal.Copy(buf, 0, bd.Scan0, n); bmp.UnlockBits(bd);
        SetBitmap(hwnd, bmp, x, y);
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

# WT tab-level jump (knife 2): the UIA calls live in a compiled helper. Load it lazily; if
# the two UIAutomation GAC assemblies are somehow unavailable the whole tab feature just
# no-ops and jumps stay window-level -- exactly the pre-1.4 behavior.
$script:wtJump = $false
try { Add-Type -Path (Join-Path $code 'JumpWt.cs') -ReferencedAssemblies UIAutomationClient, UIAutomationTypes; $script:wtJump = $true } catch {}

# ---- card-layering knife (S1+): render the card stack to a straight-alpha ARGB bitmap for a
# per-pixel-alpha layered window (smooth AA corners + soft shadow, replacing the aliased Region).
# Gated by PET_CARD_LAYERED (default off); these functions are INERT until the layered window is
# wired, so the live pet is untouched. Layers: cached shadow + cached static (rebuilt on content/
# hover/selection change) composited with a per-frame spinner glyph (D5/D6/D8/D9).
$script:layered = ($env:PET_CARD_LAYERED -eq '1')
$script:cardCache = $null; $script:cardList = @(); $script:cardGeom = $null   # layered-card render state
$script:cardPosX = 0; $script:cardPosY = 0; $script:cardDirty = $false; $script:hoverIcon = 0
function Get-RoundPath($x, $y, $w, $h, $r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, $r, $r, 180, 90); $p.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
  $p.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90); $p.AddArc($x, $y + $h - $r, $r, $r, 90, 90)
  $p.CloseFigure(); return $p
}
function Get-CardGeom($sc) {
  return @{ scale=$sc; cardW=[int](312*$sc); rowH=[int](50*$sc); rowGap=[int](7*$sc); rc=[int](18*$sc); pad=[int](14*$sc); m=[int](14*$sc) }
}
# icon chip geometry for a row (client device px, top-right): the SAME source for rendering,
# hover and hit-test (design S3/#10). $ry = the row's top y in client coords.
function Get-IconChips($gm, $ry) {
  $d = [int](18 * $gm.scale)
  $xL = $gm.pad + $gm.cardW - [int](22 * $gm.scale)   # [x] chip left
  $pL = $xL - $d - [int](2 * $gm.scale)                # pencil chip left
  $t = $ry + [int](3 * $gm.scale); $r = [int]($d / 2)
  return @{ d=$d; r=$r; x=@{ left=$xL; top=$t; cx=($xL+$r); cy=($t+$r); r=$r }; pen=@{ left=$pL; top=$t; cx=($pL+$r); cy=($t+$r); r=$r } }
}
# manual AutoEllipsis via GDI+ MeasureString (single measure/draw path, D9), CJK-safe
function Fit-Text($g, $s, $font, $maxW) {
  if (-not $s) { return '' }
  if ($g.MeasureString($s, $font).Width -le $maxW) { return $s }
  $ell = [string][char]0x2026
  for ($len = $s.Length - 1; $len -gt 0; $len--) {
    $t = $s.Substring(0, $len) + $ell
    if ($g.MeasureString($t, $font).Width -le $maxW) { return $t }
  }
  return $ell
}
# cached layers: shadow (punched under each card body) + static (fills/ring/text/icons/+N, no spinner)
function Build-CardStatic($list, $gm, $hoverRow, $selRow, $overflow, $hoverIcon) {
  $rows = $list.Count
  $W = $gm.cardW + 2*$gm.pad
  $H = $rows*($gm.rowH + $gm.rowGap) - $gm.rowGap + 2*$gm.pad
  $shadow = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($shadow)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $paths = @()
  for ($i = 0; $i -lt $rows; $i++) {
    $y = $gm.pad + $i*($gm.rowH + $gm.rowGap)
    $paths += (Get-RoundPath $gm.pad $y $gm.cardW $gm.rowH $gm.rc)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
    for ($k = 7; $k -ge 1; $k--) {
      $a = [int]((8 - $k) * 2)
      $sp = Get-RoundPath ($gm.pad - $k) ($y + [int](2*$gm.scale) - $k) ($gm.cardW + 2*$k) ($gm.rowH + 2*$k) ($gm.rc + $k)
      $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, 20, 20, 25)); $g.FillPath($sb, $sp); $sb.Dispose(); $sp.Dispose()
    }
  }
  $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy   # punch card body out of the shadow (D5 shared path)
  $clr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0,0,0,0))
  foreach ($p in $paths) { $g.FillPath($clr, $p) }
  $clr.Dispose(); $g.Dispose()
  $static = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($static)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit   # D9: never ClearType/TextRenderer
  $fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
  $fStat = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
  $fIco = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
  $fPen = New-Object System.Drawing.Font('Segoe UI Symbol', 8)
  $brTitle = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,45,45,50))
  $brDim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,216,216,220))
  $sep = '  ' + [string][char]0x00B7 + '  '
  for ($i = 0; $i -lt $rows; $i++) {
    $s = $list[$i]; $y = $gm.pad + $i*($gm.rowH + $gm.rowGap)
    $lit = ($i -eq $hoverRow -or $i -eq $selRow)
    $fillCol = $(if ($lit) { [System.Drawing.Color]::FromArgb(255,254,240,233) } else { [System.Drawing.Color]::FromArgb(255,250,249,245) })
    $fb = New-Object System.Drawing.SolidBrush($fillCol); $g.FillPath($fb, $paths[$i]); $fb.Dispose()
    if ($lit) {
      $pw = [Math]::Max(2, [int][math]::Round(2*$gm.scale))
      $rp = Get-RoundPath ($gm.pad + [int]($pw/2)) ($y + [int]($pw/2)) ($gm.cardW - $pw) ($gm.rowH - $pw) $gm.rc
      $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,217,119,87), [single]$pw); $g.DrawPath($pen, $rp); $pen.Dispose(); $rp.Dispose()
    }
    $title = $(if ($s.title) { $s.title } else { L 'newSession' $s.label })
    $titleMax = $gm.cardW - 2*$gm.m - [int](38*$gm.scale)
    $g.DrawString((Fit-Text $g $title $fTitle $titleMax), $fTitle, $brTitle, [single]($gm.pad + $gm.m), [single]($y + [int](6*$gm.scale)))
    $parts = @(); if ($s.model -and ($s.key -eq 'done' -or $s.key -eq 'idle')) { $parts += $s.model }; $parts += (L $s.key $s.label); if ($s.detail) { $parts += $s.detail }
    $stat = ($parts -join $sep)
    $col = $stateColors[$s.key]; if (-not $col) { $col = [System.Drawing.Color]::FromArgb(90,90,95) }
    $brS = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $col.R, $col.G, $col.B))
    $statMax = $gm.cardW - 2*$gm.m - [int](22*$gm.scale); if ($overflow -gt 0 -and $i -eq ($rows-1)) { $statMax -= [int](30*$gm.scale) }
    $g.DrawString((Fit-Text $g $stat $fStat $statMax), $fStat, $brS, [single]($gm.pad + $gm.m), [single]($y + [int](27*$gm.scale))); $brS.Dispose()
    $chips = Get-IconChips $gm $y
    $rowHover = ($i -eq $hoverRow)
    if ($rowHover -and $hoverIcon -eq 1) {
      $cb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,250,224,220)); $g.FillEllipse($cb, $chips.x.left, $chips.x.top, $chips.d, $chips.d); $cb.Dispose()
      $xc = [System.Drawing.Color]::FromArgb(255,220,70,70)
    } elseif ($rowHover) { $xc = [System.Drawing.Color]::FromArgb(255,150,150,155) } else { $xc = [System.Drawing.Color]::FromArgb(255,216,216,220) }
    $bx = New-Object System.Drawing.SolidBrush($xc); $zx = $g.MeasureString('x', $fIco); $g.DrawString('x', $fIco, $bx, [single]($chips.x.cx - $zx.Width/2), [single]($chips.x.cy - $zx.Height/2)); $bx.Dispose()
    if ($rowHover -and $hoverIcon -eq 2) {
      $cb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,233,230,224)); $g.FillEllipse($cb, $chips.pen.left, $chips.pen.top, $chips.d, $chips.d); $cb.Dispose()
      $pc = [System.Drawing.Color]::FromArgb(255,70,70,80)
    } elseif ($rowHover) { $pc = [System.Drawing.Color]::FromArgb(255,95,95,105) } else { $pc = [System.Drawing.Color]::FromArgb(255,216,216,220) }
    $penG = [string][char]0x270E; $bp = New-Object System.Drawing.SolidBrush($pc); $zp = $g.MeasureString($penG, $fPen); $g.DrawString($penG, $fPen, $bp, [single]($chips.pen.cx - $zp.Width/2), [single]($chips.pen.cy - $zp.Height/2)); $bp.Dispose()
  }
  if ($overflow -gt 0) {
    $fN = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    $brN = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,150,150,155))
    $yN = $gm.pad + ($rows-1)*($gm.rowH + $gm.rowGap) + [int](27*$gm.scale)
    $g.DrawString('+' + $overflow, $fN, $brN, [single]($gm.pad + $gm.cardW - $gm.m - [int](44*$gm.scale)), [single]$yN); $fN.Dispose(); $brN.Dispose()
  }
  $fTitle.Dispose(); $fStat.Dispose(); $fIco.Dispose(); $fPen.Dispose(); $brTitle.Dispose(); $brDim.Dispose()
  foreach ($p in $paths) { $p.Dispose() }
  $g.Dispose()
  return @{ shadow=$shadow; static=$static; W=$W; H=$H }
}
# per-frame compose: cached shadow + cached static + spinner glyph (over the opaque card fill),
# straight alpha; caller pushes via Lp.SetBitmapStraight (premultiply once, D8)
function Compose-CardFrame($cache, $list, $gm, $spinChar) {
  $work = New-Object System.Drawing.Bitmap($cache.W, $cache.H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($work)
  $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy; $g.Clear([System.Drawing.Color]::FromArgb(0,0,0,0))
  $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
  $g.DrawImageUnscaled($cache.shadow, 0, 0); $g.DrawImageUnscaled($cache.static, 0, 0)
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $fSpin = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
  for ($i = 0; $i -lt $list.Count; $i++) {
    $k = $list[$i].key; $y = $gm.pad + $i*($gm.rowH + $gm.rowGap); $glyph = ''; $col = $null
    if ($k -eq 'thinking') { $glyph = [string]$spinChar; $col = [System.Drawing.Color]::FromArgb(255,60,130,210) }
    elseif ($k -eq 'done') { $glyph = [string][char]0x2713; $col = [System.Drawing.Color]::FromArgb(255,70,170,90) }
    elseif ($k -eq 'attention') { $glyph = '!'; $col = [System.Drawing.Color]::FromArgb(255,225,150,40) }
    if ($glyph) { $br = New-Object System.Drawing.SolidBrush($col); $g.DrawString($glyph, $fSpin, $br, [single]($gm.pad + $gm.cardW - $gm.m - [int](16*$gm.scale)), [single]($y + [int](26*$gm.scale))); $br.Dispose() }
  }
  $fSpin.Dispose(); $g.Dispose()
  return $work
}

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
  # editBox is a card-level sibling of the row panels; translate the title's
  # panel-relative bounds into card coordinates
  $editBox.SetBounds(($rowPanel[$idx].Left + $rowTitle[$idx].Left), ($rowPanel[$idx].Top + $rowTitle[$idx].Top), $rowTitle[$idx].Width, $rowTitle[$idx].Height)
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

# ---- click-to-jump: a card row -> that session's host window ----
function LogEv($msg) {
  $log = Join-Path $root 'events.log'
  if ((Test-Path $log) -and ((Get-Item $log).Length -gt 262144)) { Remove-Item $log -Force -ErrorAction SilentlyContinue }
  try { Add-Content $log -Value ('{0}  {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}
# ---- interrupt watch: Esc-interrupting a turn fires no Stop hook (feature request
# #9516), so a thinking card would hang forever. The interrupt leaves a durable mark as
# the FINAL transcript entry -- a user message carrying "interruptedMessageId". Tail the
# transcript; report interrupted only when that mark is the last entry, so a new prompt or
# reply landing afterwards clears it and we never re-trigger on a stale interrupt.
# Shared read (Claude keeps the write handle).
function Test-Interrupted($tp) {
  if (-not $tp -or -not (Test-Path $tp)) { return $false }
  $text = ''
  try {
    $fs = [IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
    $flen = $fs.Length; $take = [Math]::Min($flen, 65536)
    if ($take -le 0) { $fs.Dispose(); return $false }
    [void]$fs.Seek(-$take, 'End')
    $buf = New-Object byte[] $take; [void]$fs.Read($buf, 0, $take); $fs.Dispose()
    $text = [Text.Encoding]::UTF8.GetString($buf)
  } catch { return $false }
  $last = ''
  foreach ($ln in ($text -split "`n")) { $t = $ln.Trim(); if ($t) { $last = $t } }
  return ($last -match '"interruptedMessageId"')
}
# Walk up the parent chain from a claude.exe PID to the first ancestor owning a real
# top-level window (Windows Terminal, VS Code, a plain console, ...). Each ancestor must
# be born no later than its child (2s slack): a recycled parent PID would otherwise point
# at an unrelated newer process and we would activate a stranger's window. No window
# found -> IntPtr.Zero, caller shows the honest head-shake instead of guessing.
# Perf: ONE bulk CIM query (the per-PID Filter form costs 100-300ms per hop), then the
# walk happens in memory; callers cache the resolved HWND so repeat jumps are instant.
function Find-HostWindow([int]$startPid) {
  $all = @{}
  foreach ($pr in @(Get-CimInstance -Query 'SELECT ProcessId,ParentProcessId,CreationDate FROM Win32_Process' -ErrorAction SilentlyContinue)) { $all[[int]$pr.ProcessId] = $pr }
  # side product: the visited ancestor PIDs (claude, its shell, ...) are stashed in
  # $script:jumpChain -- the VS Code companion handshake needs them to match a terminal,
  # and capturing here means cache-hit clicks never pay a second CIM walk
  $chain = New-Object System.Collections.Generic.List[int]
  $cur = $startPid; $prevBorn = $null
  for ($d = 0; $d -lt 8; $d++) {
    if ($cur -le 0 -or -not $all.ContainsKey($cur)) { break }
    $ci = $all[$cur]
    $born = $null; try { $born = [DateTime]$ci.CreationDate } catch {}
    if ($prevBorn -and $born -and $born -gt $prevBorn.AddSeconds(2)) { break }
    [void]$chain.Add($cur)
    $gp = Get-Process -Id $cur -ErrorAction SilentlyContinue
    if ($gp -and $gp.MainWindowHandle.ToInt64() -ne 0) { $script:jumpChain[$startPid] = $chain.ToArray(); return $gp.MainWindowHandle }
    if ($born) { $prevBorn = $born }
    $cur = 0; if ($ci.ParentProcessId) { $cur = [int]$ci.ParentProcessId }
  }
  $script:jumpChain[$startPid] = $chain.ToArray()
  return [IntPtr]::Zero
}
# Companion-extension handshake (tab-level jump inside VS Code): after a successful
# window-level activation, drop the session's ancestor PID chain into a UNIQUE
# jump-req-<nonce>.json at the data ROOT (not sessions\ -- stays out of the
# FileSystemWatcher). The companion extension instance in the owning VS Code window
# matches one of these PIDs against its own terminals' shell PIDs and focuses that
# terminal, then writes jump-ack.json. No extension installed -> the file is inert and
# the jump stays window-level, exactly the pre-1.3 behavior. Best-effort by design: a
# failure here must never undo or block the window jump that already happened, so
# everything is wrapped and the result only feeds the events.log req= flag.
# Write .tmp then rename to a never-existing final name: readers only match *.json so
# they never see a half-written file, and no path ever needs replacing. (First cut used
# File.Replace($tmp,$dst,$null) -- PS 5.1 coerces $null to '' for string parameters,
# so the no-backup overload ALWAYS threw 'path is not of a legal form'. Unique names
# also dodge any scanner briefly holding the previous request file.)
function Write-JumpRequest([int]$cpid) {
  try {
    $chain = $script:jumpChain[$cpid]
    if (-not $chain -or $chain.Count -lt 1) { return 0 }
    $ep = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $nonce = [Guid]::NewGuid().ToString('N')
    $json = '{"nonce":"' + $nonce + '","ts":' + $ep + ',"claudePid":' + $cpid + ',"ancestorPids":[' + ($chain -join ',') + ']}'
    $tmp = Join-Path $root ('jump-req-' + $nonce + '.tmp')
    $dst = Join-Path $root ('jump-req-' + $nonce + '.json')
    [IO.File]::WriteAllText($tmp, $json, [Text.Encoding]::ASCII)
    Move-Item -LiteralPath $tmp -Destination $dst
    foreach ($old in @(Get-ChildItem $root -Filter 'jump-req-*' -File -ErrorAction SilentlyContinue)) {
      if (((Get-Date) - $old.LastWriteTime).TotalSeconds -gt 60) { Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue }
    }
    return 1
  } catch { return 0 }
}
# After a successful WINDOW-level activation, place the Windows Terminal host on the exact
# tab. Direct path: if this session's LIVE state is stable (done/idle/attention, no armed
# .pending) its recorded fingerprint still equals the tab Name -> select it. Otherwise
# (mid-turn, so the title is about to change; or a zero/multi-Name match) fall to the nonce
# channel. Any failure keeps the window-level jump -- tab precision is a bonus, never a
# regression, so we never head-shake here. Returns for events.log:
#   '1' selected directly   '0' handed to the (async) nonce channel or a direct miss
#   '-' not a WT host (VS Code went through the jump-req companion handshake instead)
function Jump-Tab($h, $cp, $sid) {
  if (-not $script:wtJump) { return '-' }
  $cls = ''; try { $cls = [Lp]::ClassName($h) } catch {}
  if ($cls -ne 'CASCADIA_HOSTING_WINDOW_CLASS') { return '-' }
  # direct-connect eligibility (design F1/G1): re-read the session file NOW for the live
  # state + fingerprint. The render row cache lags the tick/FSW by up to ~1.2s, and an
  # armed .pending means the title is about to flip -- neither is safe to match directly.
  $st = ''; $fp = ''
  $c = RU (Join-Path $sessDir $sid)
  if ($c) { $pp = $c -split "`t"; $st = $pp[0]; if ($pp.Count -ge 8) { $fp = $pp[7] } }
  $armed = Test-Path (Join-Path $sessDir "$sid.pending")
  if (($st -eq 'done' -or $st -eq 'idle' -or $st -eq 'attention') -and -not $armed -and $fp) {
    $r = 0; try { $r = [PetWtJump]::TryFocusTab($h, $fp) } catch { $r = 0 }
    if ($r -eq 1) { return '1' }
  }
  Start-NonceJump $h $cp
  return '0'
}
# nonce channel: a short-lived helper stamps a unique title on THIS session's tab (by
# attaching to its console) so the resident can pick it out of same-named siblings, then
# the tick poller selects it and the helper restores. Per-hwnd single slot (last-click-
# wins) plus a per-shell cooldown longer than the helper's life keep stamp/restore from
# racing. Timing invariant (design G2): holdMs < deadline < cooldown.
function Start-NonceJump($h, $cp) {
  if ($env:PET_DISABLE_NONCE -eq '1') { return }   # test switch (T38): prove an honest give-up
  $now = Get-Date
  if ($script:nonceCooldown.ContainsKey($cp) -and $now -lt $script:nonceCooldown[$cp]) { return }
  $nonce = 'PETNONCE_' + [Guid]::NewGuid().ToString('N')
  $holdMs = 2000
  try {
    Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $code 'jump-nonce.ps1'), "$cp", $nonce, "$holdMs"
    ) | Out-Null
  } catch { return }
  $script:nonceInFlight[$h.ToInt64()] = @{ nonce = $nonce; shellPid = $cp; deadline = $now.AddMilliseconds(3400) }
  $script:nonceCooldown[$cp] = $now.AddMilliseconds(4400)
}
function Jump-Row($idx) {
  if ($script:editing) { return }
  $sid = $script:rowSids[$idx]; if (-not $sid) { return }
  $cp = 0; [void][int]::TryParse(($script:rowPids[$idx] + ''), [ref]$cp)
  $ok = $false; $hv = 0; $hit = 0; $rq = 0; $wtab = '-'
  if ($cp -gt 0) {
    $gp0 = Get-Process -Id $cp -ErrorAction SilentlyContinue
    if ($gp0 -and $gp0.ProcessName -eq 'claude') {   # PID recycled by a non-claude process -> never jump
      $h = [IntPtr]::Zero
      if ($script:jumpCache.ContainsKey($cp)) {
        $c = $script:jumpCache[$cp]
        if ($c -ne [IntPtr]::Zero -and [Lp]::IsWin($c)) { $h = $c; $hit = 1 }
      }
      if ($h -eq [IntPtr]::Zero) { $h = Find-HostWindow $cp; $script:jumpCache[$cp] = $h }   # Zero is cached too (stops futile re-warming); a later click re-walks
      if ($h -ne [IntPtr]::Zero) {
        # multi-window VS Code: all windows share one Code.exe so MainWindowHandle can't
        # tell them apart -> re-pick the window whose title matches this session's workspace
        # (field 10 = cwd). No-op for single-window / non-editor hosts. Applied per click
        # (not cached) so it always targets the right window as the window set changes.
        $jcwd = ''; $jsc = RU (Join-Path $sessDir $sid); if ($jsc) { $jsp = $jsc -split "`t"; if ($jsp.Count -ge 10) { $jcwd = $jsp[9] } }
        if ($jcwd) { $h = [Lp]::PickWindowForPath($jcwd, $h) }
        $hv = $h.ToInt64(); $ok = [Lp]::Activate($h)
        if (-not $ok) { $script:jumpCache[$cp] = [IntPtr]::Zero }   # stale target -> drop so the next click re-resolves
        if ($ok) { $rq = Write-JumpRequest $cp; $wtab = Jump-Tab $h $cp $sid }   # tab-level jump rides on a successful window jump only
      }
    }
  }
  if ($ok) { $script:selectedSid = $sid }   # mark this card selected: it stays lit until you pick another
  if (-not $ok) { $script:shakeN = 6 }   # honest feedback: cannot place this session
  LogEv ('jump idx={0} pid={1} hwnd={2} ok={3} cache={4} req={5} wtab={6}' -f $idx, $cp, $hv, [int]$ok, $hit, $rq, $wtab)
}

$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g0.DpiX / 96.0; $g0.Dispose()
$w = [int](148 * $scale)
$cardW = [int](312 * $scale)
$rowH = [int](50 * $scale)
$rowGap = [int](7 * $scale)   # visual gap between per-session cards (notification-center style)
$gap = [int](8 * $scale)
$m = [int](14 * $scale)
$MAXROWS = 3

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:defX = $wa.Right - $w - [int](44 * $scale)
$script:defY = $wa.Bottom - $w - ($MAXROWS * ($rowH + $rowGap) - $rowGap) - $gap - [int](16 * $scale)
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
# card-layering knife: when PET_CARD_LAYERED, the card is a per-pixel-alpha layered window
# (PetWin's exstyle = LAYERED+TOPMOST+TOOLWINDOW+NOACTIVATE) rendered to a bitmap; the child
# controls below are still created but stay inert/invisible under the layered surface (S1 read-only).
$card = if ($script:layered) { New-Object LCardWin } else { New-Object CardWin }
$card.FormBorderStyle = 'None'; $card.ShowInTaskbar = $false; $card.TopMost = $true; $card.StartPosition = 'Manual'
if ($script:layered) {
  # S2: a click on a card body (WM_NCHITTEST already filtered out gaps/shadow) -> jump that
  # row. $e is client (bitmap) coords; subtract the shadow pad and divide by the row pitch.
  $card.add_MouseClick({ param($snd, $e)
    $gm = $script:cardGeom; if (-not $gm) { return }
    $pitch = $gm.rowH + $gm.rowGap; $rel = $e.Y - $gm.pad; if ($rel -lt 0) { return }
    $ri = [int][math]::Floor($rel / $pitch)
    if ($ri -lt 0 -or $ri -ge $MAXROWS -or ($rel - $ri * $pitch) -ge $gm.rowH -or -not $script:rowSids[$ri]) { return }
    $chips = Get-IconChips $gm ($gm.pad + $ri * $pitch)   # priority: [x] > pencil > row jump
    $dx = $e.X - $chips.x.cx; $dy = $e.Y - $chips.x.cy
    if (($dx*$dx + $dy*$dy) -le ($chips.x.r * $chips.x.r)) {
      $sid = $script:rowSids[$ri]; if ($sid) { WU (Join-Path $sessDir "$sid.dismiss") "$(& $nowMs)" }   # [x] -> dismiss
      return
    }
    $dx = $e.X - $chips.pen.cx; $dy = $e.Y - $chips.pen.cy
    if (($dx*$dx + $dy*$dy) -le ($chips.pen.r * $chips.pen.r)) { return }   # pencil -> rename (S4, deferred)
    Jump-Row $ri
  })
}
$card.Size = New-Object System.Drawing.Size($cardW, $rowH)
$card.BackColor = [System.Drawing.Color]::FromArgb(250, 249, 245)
# the window region is a UNION of per-row rounded rects, so each session renders as its
# own card with a true gap between (the gap strip is clipped out of the window entirely)
function Set-CardRegion($rows) {
  $rc = [int](14 * $scale)
  $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
  for ($ri = 0; $ri -lt $rows; $ri++) {
    $y0 = $ri * ($rowH + $rowGap)
    $gp.StartFigure()
    $gp.AddArc(0, $y0, $rc, $rc, 180, 90); $gp.AddArc($cardW - $rc, $y0, $rc, $rc, 270, 90)
    $gp.AddArc($cardW - $rc, $y0 + $rowH - $rc, $rc, $rc, 0, 90); $gp.AddArc(0, $y0 + $rowH - $rc, $rc, $rc, 90, 90)
    $gp.CloseFigure()
  }
  $card.Region = New-Object System.Drawing.Region($gp)
}
if (-not $script:layered) { Set-CardRegion 1 }   # a region would clip the layered ULW bitmap

$rowTitle = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowState = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowSpin  = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowClose = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowEdit  = New-Object 'System.Windows.Forms.Label[]' $MAXROWS
$rowPanel = New-Object 'System.Windows.Forms.Panel[]' $MAXROWS
for ($i = 0; $i -lt $MAXROWS; $i++) {
  # one Panel per row = the whole card is a single interactive unit: it hover-tints as
  # one piece and every non-icon pixel (text or blank) is a jump target
  $pnl = New-Object System.Windows.Forms.Panel
  $pnl.Location = New-Object System.Drawing.Point(0, ($i * ($rowH + $rowGap)))
  $pnl.Size = New-Object System.Drawing.Size($cardW, $rowH)
  $pnl.BackColor = [System.Drawing.Color]::FromArgb(250, 249, 245)
  $pnl.Tag = $i
  $pnl.add_Click({ param($snd,$e) Jump-Row ([int]$snd.Tag) })
  # hover cue: these are floating cards over an ARBITRARY wallpaper (often dark), where
  # the card's own edge is already max contrast -- a subtle interior line drowns. The
  # industry analogue here is the focus ring / selected outline, not a list-row tint:
  # a 2px ring in the mascot's coral marks the hovered card unmistakably on any backdrop
  $pnl.add_Paint({ param($snd,$e)
    if ([int]$snd.Tag -ne $script:hoverRow -and [int]$snd.Tag -ne $script:selRow) { return }   # ring shows on hover OR persistent selection
    $rc2 = [int](14 * $scale)
    $pw = [Math]::Max(2, [int][math]::Round(2 * $scale))
    $half = [int][math]::Ceiling($pw / 2.0)
    $x1 = $snd.Width - 1 - $half; $y1 = $snd.Height - 1 - $half
    $gp2 = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp2.AddArc($half, $half, $rc2, $rc2, 180, 90); $gp2.AddArc($x1 - $rc2, $half, $rc2, $rc2, 270, 90)
    $gp2.AddArc($x1 - $rc2, $y1 - $rc2, $rc2, $rc2, 0, 90); $gp2.AddArc($half, $y1 - $rc2, $rc2, $rc2, 90, 90)
    $gp2.CloseFigure()
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(217,119,87), ([single]$pw))
    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $e.Graphics.DrawPath($pen, $gp2)
    $pen.Dispose(); $gp2.Dispose()
  })
  $card.Controls.Add($pnl); $rowPanel[$i] = $pnl
  $base = 0   # children live inside the row panel now; offsets are panel-relative
  $t = New-Object System.Windows.Forms.Label
  $t.AutoSize = $false; $t.AutoEllipsis = $true; $t.Tag = $i
  $t.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
  $t.ForeColor = [System.Drawing.Color]::FromArgb(45,45,50)
  $t.Location = New-Object System.Drawing.Point($m, ($base + [int](6*$scale)))
  $t.Size = New-Object System.Drawing.Size(($cardW - 2*$m - [int](38*$scale)), [int](22*$scale))
  $t.BackColor = [System.Drawing.Color]::Transparent
  $t.add_Click({ param($snd,$e) Jump-Row ([int]$snd.Tag) })
  $pnl.Controls.Add($t); $rowTitle[$i] = $t
  $s = New-Object System.Windows.Forms.Label
  $s.AutoSize = $false; $s.AutoEllipsis = $true; $s.Tag = $i
  $s.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
  $s.ForeColor = [System.Drawing.Color]::FromArgb(90,90,95)
  $s.Location = New-Object System.Drawing.Point($m, ($base + [int](27*$scale)))
  $s.Size = New-Object System.Drawing.Size(($cardW - 2*$m - [int](22*$scale)), [int](20*$scale))
  $s.BackColor = [System.Drawing.Color]::Transparent
  $s.add_Click({ param($snd,$e) Jump-Row ([int]$snd.Tag) })
  $pnl.Controls.Add($s); $rowState[$i] = $s
  $sp = New-Object System.Windows.Forms.Label
  $sp.AutoSize = $false; $sp.TextAlign = 'MiddleCenter'; $sp.Tag = $i
  $sp.add_Click({ param($snd,$e) Jump-Row ([int]$snd.Tag) })
  $sp.Font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
  $sp.ForeColor = [System.Drawing.Color]::FromArgb(60,130,210)
  $sp.Location = New-Object System.Drawing.Point(($cardW - $m - [int](16*$scale)), ($base + [int](26*$scale)))
  $sp.Size = New-Object System.Drawing.Size([int](16*$scale), [int](20*$scale))
  $sp.BackColor = [System.Drawing.Color]::Transparent
  $pnl.Controls.Add($sp); $rowSpin[$i] = $sp
  # icon buttons get CIRCULAR hover backplates with breathing room (18px chip around an
  # 8pt glyph) -- the Chrome-tab-x / VS Code pattern; a square plate glued to the glyph
  # is what made the first attempt look wrong
  $icoD = [int](18 * $scale)
  $xc = New-Object System.Windows.Forms.Label
  $xc.Text = 'x'; $xc.TextAlign = 'MiddleCenter'; $xc.Cursor = 'Hand'; $xc.Tag = $i
  $xc.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
  $xc.ForeColor = [System.Drawing.Color]::FromArgb(216,216,220)
  $xc.Location = New-Object System.Drawing.Point(($cardW - [int](22*$scale)), ($base + [int](3*$scale)))
  $xc.Size = New-Object System.Drawing.Size($icoD, $icoD)
  $gpc = New-Object System.Drawing.Drawing2D.GraphicsPath; $gpc.AddEllipse(0, 0, $icoD, $icoD)
  $xc.Region = New-Object System.Drawing.Region($gpc)
  $xc.BackColor = [System.Drawing.Color]::Transparent
  $xc.add_Click({ param($snd,$e)
    $idx = [int]$snd.Tag; $sid = $script:rowSids[$idx]
    if ($sid) { WU (Join-Path $sessDir "$sid.dismiss") "$(& $nowMs)" }
  })
  $xc.add_MouseEnter({ param($snd,$e) $script:xHoverIdx = [int]$snd.Tag; $snd.BackColor = [System.Drawing.Color]::FromArgb(250,224,220); $snd.ForeColor = [System.Drawing.Color]::FromArgb(220,70,70) })
  $xc.add_MouseLeave({ param($snd,$e) $script:xHoverIdx = -1; $snd.BackColor = [System.Drawing.Color]::Transparent; $snd.ForeColor = [System.Drawing.Color]::FromArgb(150,150,155) })
  $pnl.Controls.Add($xc); $xc.BringToFront(); $rowClose[$i] = $xc
  $ec = New-Object System.Windows.Forms.Label
  $ec.Text = ([char]0x270E); $ec.TextAlign = 'MiddleCenter'; $ec.Cursor = 'Hand'; $ec.Tag = $i
  $ec.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 8)
  $ec.ForeColor = [System.Drawing.Color]::FromArgb(216,216,220)
  $ec.Location = New-Object System.Drawing.Point(($cardW - [int](22*$scale) - $icoD - [int](2*$scale)), ($base + [int](3*$scale)))
  $ec.Size = New-Object System.Drawing.Size($icoD, $icoD)
  $gpe = New-Object System.Drawing.Drawing2D.GraphicsPath; $gpe.AddEllipse(0, 0, $icoD, $icoD)
  $ec.Region = New-Object System.Drawing.Region($gpe)
  $ec.BackColor = [System.Drawing.Color]::Transparent
  $ec.add_Click({ param($snd,$e) Edit-Row ([int]$snd.Tag) })
  $ec.add_MouseEnter({ param($snd,$e) $snd.BackColor = [System.Drawing.Color]::FromArgb(233,230,224); $snd.ForeColor = [System.Drawing.Color]::FromArgb(70,70,80) })
  $ec.add_MouseLeave({ param($snd,$e) $snd.BackColor = [System.Drawing.Color]::Transparent; $snd.ForeColor = [System.Drawing.Color]::FromArgb(95,95,105) })
  $pnl.Controls.Add($ec); $ec.BringToFront(); $rowEdit[$i] = $ec
}

# overflow badge: when more sessions are eligible than rows, a static gray "+N" sits at
# the bottom-right of the last row (left of its spinner). Zero interaction, ASCII only.
$stateNormW = $cardW - 2*$m - [int](22*$scale)
$stateShrunkW = $stateNormW - [int](30*$scale)
$ovBadge = New-Object System.Windows.Forms.Label
$ovBadge.AutoSize = $false; $ovBadge.TextAlign = 'MiddleRight'
$ovBadge.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$ovBadge.ForeColor = [System.Drawing.Color]::FromArgb(150,150,155)
$ovBadge.BackColor = [System.Drawing.Color]::Transparent
$ovBadge.Location = New-Object System.Drawing.Point(($cardW - $m - [int](46*$scale)), [int](27*$scale))
$ovBadge.Size = New-Object System.Drawing.Size([int](28*$scale), [int](20*$scale))
$ovBadge.Visible = $false
$rowPanel[$MAXROWS - 1].Controls.Add($ovBadge)   # lives inside the last row card (panel-relative)

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
$script:lastPoll = $now0; $script:lastSpin = $now0; $script:spinIdx = 0; $script:lastPend = $now0
$script:animOn = $true; try { $script:animOn = [Lp]::AnimationsOn() } catch {}; $script:lastAnimChk = $now0
$script:lastTop = $now0
$script:cardShown = $false; $script:cardH = $rowH; $script:lastSig = '__'; $script:hoverRow = -2; $script:xHoverIdx = -1
$script:selRow = -2; $script:selectedSid = ''   # the last-clicked card stays lit (selection tracked by sid, follows re-sorts)
$script:lastKeys = @{}; $script:rowKeys = New-Object 'string[]' $MAXROWS; $script:rowSids = New-Object 'string[]' $MAXROWS; $script:firstPoll = $true
$script:rowPids = New-Object 'string[]' $MAXROWS; $script:shakeN = 0
$script:jumpCache = @{}; $script:lastWarm = $now0   # claudePid -> host HWND (pre-warmed so the first click is instant)
$script:jumpChain = @{}   # claudePid -> ancestor PID chain from that walk (consumed by the VS Code companion handshake)
$script:nonceInFlight = @{}   # hwnd(int64) -> @{ nonce; shellPid; deadline } (per-hwnd single slot, last-click-wins)
$script:nonceCooldown = @{}   # shellPid -> cooldown-until DateTime (> helper life so a shell is not re-poked mid-flight)
$script:lastNoncePoll = $now0; $script:lastIntr = $now0
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
  if ($script:shakeN -gt 0) { return }   # let the head-shake finish; its last tick re-places
  $cx = $script:x + [int]($w/2) - [int]($cardW/2)
  if ($cx -lt ($wa.Left + 4)) { $cx = $wa.Left + 4 }
  if (($cx + $cardW) -gt ($wa.Right - 4)) { $cx = $wa.Right - 4 - $cardW }
  $cy = $script:y + $w + $gap
  if (($cy + $script:cardH) -gt ($wa.Bottom - 4)) { $cy = $script:y - $script:cardH - $gap }
  if ($script:layered) {
    # the layered window is bigger than the card content by the shadow pad on every side;
    # store the screen origin so the frame push (UpdateLayeredWindow) positions it there
    $p = [int](14 * $scale); $script:cardPosX = $cx - $p; $script:cardPosY = $cy - $p
  } elseif ($card.Left -ne $cx -or $card.Top -ne $cy) { $card.Left = $cx; $card.Top = $cy }
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
    # display TTL vs storage TTL: after 30min idle the card is only HIDDEN -- the file
    # (first-prompt title, rename lock, model badge) must survive so a revived session
    # keeps its identity; physical deletion only after 7 days of silence
    $idleMs = $now - $epoch
    if ($idleMs -gt 604800000) { Remove-Item $f.FullName, "$($f.FullName).dismiss", "$($f.FullName).titlelock", "$($f.FullName).pending" -Force -ErrorAction SilentlyContinue; continue }
    if ($idleMs -gt 1800000) { continue }
    $dp = "$($f.FullName).dismiss"
    if (Test-Path $dp) { $de = 0L; [long]::TryParse((RU $dp), [ref]$de) | Out-Null; if ($de -ge $epoch) { continue } }
    $list += [pscustomobject]@{ sid=$f.Name; key=$p[0]; label=$p[1]; title=$p[2]; detail=$(if($p.Count -ge 4){$p[3]}else{''}); epoch=$epoch; model=$(if($p.Count -ge 6){$p[5]}else{''}); cpid=$(if($p.Count -ge 7){$p[6]}else{''}) }
  }
  # minimal hybrid: float 'attention' (needs you) to the top; everything else stays newest-first
  $list = @($list | Sort-Object @{Expression={ if ($_.key -eq 'attention') { 0 } else { 1 } }}, @{Expression={ $_.epoch }; Descending=$true})
  # overflow = eligible-but-not-shown sessions (dismissed/hidden already filtered out above)
  $overflow = $list.Count - $MAXROWS; if ($overflow -lt 0) { $overflow = 0 }
  $list = @($list | Select-Object -First $MAXROWS)

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
    for ($i=0; $i -lt $MAXROWS; $i++){ $script:rowKeys[$i] = ''; $script:rowSids[$i] = ''; $script:rowPids[$i] = '' }
    return
  }

  $sig = (($list | ForEach-Object { "$($_.sid)|$($_.key)|$($_.title)|$($_.detail)|$($_.model)|$($_.cpid)" }) -join '##') + "|ov=$overflow"
  if ($script:layered) {
    # layered path: rebuild the cached shadow+static layers on any content/hover/selection
    # change; the tick composes the spinner frame and pushes. Row maps stay in sync for jump.
    $srIdx = -1; if ($script:selectedSid) { for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].sid -eq $script:selectedSid) { $srIdx = $i; break } } }
    $lsig = $sig + "|hv$($script:hoverRow)|hi$($script:hoverIcon)|sr$srIdx"
    if ($lsig -ne $script:lastSig) {
      $gm = Get-CardGeom $scale
      if ($script:cardCache) { $script:cardCache.shadow.Dispose(); $script:cardCache.static.Dispose(); $script:cardCache = $null }
      $script:cardCache = Build-CardStatic $list $gm $script:hoverRow $srIdx $overflow $script:hoverIcon
      $script:cardList = $list; $script:cardGeom = $gm
      $card.Size = New-Object System.Drawing.Size($script:cardCache.W, $script:cardCache.H)
      # WM_NCHITTEST hit rects: one card-body rect per visible row (client device px) so the
      # window only captures clicks on a card body; gaps/shadow pass through (S2, alpha-aware)
      $hitr = New-Object System.Collections.Generic.List[int]
      for ($i = 0; $i -lt $list.Count; $i++) { [void]$hitr.Add($gm.pad); [void]$hitr.Add($gm.pad + $i*($gm.rowH + $gm.rowGap)); [void]$hitr.Add($gm.cardW); [void]$hitr.Add($gm.rowH) }
      $card.HitRects = $hitr.ToArray()
      for ($i = 0; $i -lt $MAXROWS; $i++) {
        if ($i -lt $list.Count) { $script:rowKeys[$i] = $list[$i].key; $script:rowSids[$i] = $list[$i].sid; $script:rowPids[$i] = $list[$i].cpid }
        else { $script:rowKeys[$i] = ''; $script:rowSids[$i] = ''; $script:rowPids[$i] = '' }
      }
      $script:cardH = ($list.Count * ($rowH + $rowGap)) - $rowGap
      $script:lastSig = $lsig; $script:cardDirty = $true
    }
  } elseif ($sig -ne $script:lastSig) {
    for ($i = 0; $i -lt $MAXROWS; $i++) {
      if ($i -lt $list.Count) {
        $s = $list[$i]
        $lab = L $s.key $s.label
        $rowTitle[$i].Text = $(if ($s.title) { $s.title } else { L 'newSession' $s.label })
        # status line: [model badge, post-turn states only] . state . detail
        # mid-turn (thinking/attention) the badge would read as "the model currently
        # running", which we cannot truthfully know -- so it only renders on done/idle
        $parts = @(); if ($s.model -and ($s.key -eq 'done' -or $s.key -eq 'idle')) { $parts += $s.model }; $parts += $lab; if ($s.detail) { $parts += $s.detail }
        $rowState[$i].Text = ($parts -join "  $([char]0x00B7)  ")
        $col = $stateColors[$s.key]; if (-not $col) { $col = [System.Drawing.Color]::FromArgb(90,90,95) }
        $rowState[$i].ForeColor = $col
        # hand cursor = this row can jump (has a recorded claude PID); default = it cannot
        # (legacy record, heals on the session's next event) -- the affordance never lies
        $csr = $(if ($s.cpid) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default })
        $rowTitle[$i].Cursor = $csr; $rowState[$i].Cursor = $csr; $rowPanel[$i].Cursor = $csr
        $script:rowKeys[$i] = $s.key; $script:rowSids[$i] = $s.sid; $script:rowPids[$i] = $s.cpid
        if (-not $rowPanel[$i].Visible) { $rowPanel[$i].Visible = $true }
      } else {
        if ($rowPanel[$i].Visible) { $rowPanel[$i].Visible = $false }
        $rowSpin[$i].Visible = $false
        $script:rowKeys[$i] = ''; $script:rowSids[$i] = ''; $script:rowPids[$i] = ''
      }
    }
    if ($overflow -gt 0 -and $list.Count -eq $MAXROWS) {
      $ovBadge.Text = '+' + $overflow
      $rowState[$MAXROWS - 1].Width = $stateShrunkW   # make room so the badge never covers text
      if (-not $ovBadge.Visible) { $ovBadge.Visible = $true }
      $ovBadge.BringToFront()
    } else {
      if ($ovBadge.Visible) { $ovBadge.Visible = $false }
      $rowState[$MAXROWS - 1].Width = $stateNormW
    }
    $h = ($list.Count * ($rowH + $rowGap)) - $rowGap
    if ($card.Height -ne $h) { $card.Height = $h; Set-CardRegion $list.Count }
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
  elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $menu.Show($form, $form.PointToClient([System.Windows.Forms.Cursor]::Position)) }   # owner-show keeps the menu above owned/topmost siblings
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
  # head-shake: brief lateral wiggle of the card = "cannot jump for this row" (no i18n,
  # no dialog); the final tick snaps the card back via Place-Card (guarded while shaking)
  if ($script:shakeN -gt 0 -and $script:cardShown) {
    $script:shakeN--
    if ($script:shakeN -eq 0) { Place-Card }
    else { $card.Left = $card.Left + $(if ($script:shakeN % 2) { 6 } else { -6 }) }
  }
  # pre-warm at most one unresolved jump target per 2s cycle, so the first click on a
  # fresh card is a cache hit; failures cache Zero (no futile retries -- a real click
  # re-walks once as the fallback)
  if (($now - $script:lastWarm).TotalMilliseconds -ge 2000) {
    $script:lastWarm = $now
    for ($i = 0; $i -lt $MAXROWS; $i++) {
      $cp3 = 0; [void][int]::TryParse(($script:rowPids[$i] + ''), [ref]$cp3)
      if ($cp3 -gt 0 -and -not $script:jumpCache.ContainsKey($cp3)) {
        $script:jumpCache[$cp3] = Find-HostWindow $cp3
        break
      }
    }
  }
  if (($now - $script:lastAnimChk).TotalSeconds -ge 3) { $script:lastAnimChk = $now; try { $script:animOn = [Lp]::AnimationsOn() } catch {} }
  # keep the pet/cards above other windows (Windows silently demotes topmost on focus changes);
  # but don't fight a fullscreen game / presentation / Do-Not-Disturb, and NEVER re-assert
  # while transient UI (rename box, context menu) is open -- slamming the card to the top of
  # the topmost band would cover the menu (same class of bug as the editing guard)
  if (-not $script:editing -and -not $menu.Visible -and ($now - $script:lastTop).TotalSeconds -ge 2) {
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
    if ($script:layered) {
      # recompose cached layers + this spinner frame and push (D6). Only when a thinking
      # card is animating or the cache just changed -- static states need no repush.
      $anim = $false; for ($i = 0; $i -lt $MAXROWS; $i++) { if ($script:rowKeys[$i] -eq 'thinking') { $anim = $true; break } }
      if (($script:cardDirty -or $anim) -and $script:cardCache) {
        $work = Compose-CardFrame $script:cardCache $script:cardList $script:cardGeom $ch
        try { [Lp]::SetBitmapStraight($card.Handle, $work, $script:cardPosX, $script:cardPosY) } catch {}
        $work.Dispose(); $script:cardDirty = $false
      }
    } else {
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
  }
  if ($script:layered) {
    # layered hover: hovered row + icon from the card's screen origin (cardPosX/Y), occlusion-
    # honest via HitTop (WM_NCHITTEST makes gaps/shadow transparent, so HitTop is true only over
    # an actionable card body). Feeds the cache rebuild in Update-Card via lsig.
    $hr = -1; $hi = 0
    if ($script:cardShown -and $card.Visible -and $script:cardGeom) {
      $cp = [System.Windows.Forms.Cursor]::Position
      if ([Lp]::HitTop($card.Handle, $cp.X, $cp.Y)) {
        $gm = $script:cardGeom; $rx = $cp.X - $script:cardPosX; $ry = $cp.Y - $script:cardPosY
        $rel = $ry - $gm.pad; $pitch = $gm.rowH + $gm.rowGap; $ri2 = [int][math]::Floor($rel / $pitch)
        if ($ri2 -ge 0 -and $ri2 -lt $script:cardList.Count -and ($rel - $ri2 * $pitch) -lt $gm.rowH) {
          $hr = $ri2; $chips = Get-IconChips $gm ($gm.pad + $ri2 * $pitch)
          if ((($rx - $chips.x.cx) * ($rx - $chips.x.cx) + ($ry - $chips.x.cy) * ($ry - $chips.x.cy)) -le ($chips.x.r * $chips.x.r)) { $hi = 1 }
          elseif ((($rx - $chips.pen.cx) * ($rx - $chips.pen.cx) + ($ry - $chips.pen.cy) * ($ry - $chips.pen.cy)) -le ($chips.pen.r * $chips.pen.r)) { $hi = 2 }
        }
      }
    }
    if ($hr -ne $script:hoverRow -or $hi -ne $script:hoverIcon) { $script:hoverRow = $hr; $script:hoverIcon = $hi }
  } else {
  # dim row action icons by default; brighten the row currently under the cursor
  $hr = -1
  if ($script:cardShown -and $card.Visible) {
    $cpos2 = [System.Windows.Forms.Cursor]::Position
    if ($card.Bounds.Contains($cpos2) -and [Lp]::HitTop($card.Handle, $cpos2.X, $cpos2.Y)) {
      $rel = $cpos2.Y - $card.Top; $pitch = $rowH + $rowGap
      $ri2 = [int][math]::Floor($rel / $pitch)
      if ($ri2 -lt $MAXROWS -and ($rel - $ri2 * $pitch) -lt $rowH) { $hr = $ri2 }   # cursor in a gap counts as nowhere
    }
  }
  # which row (if any) is the persistently-selected card -- tracked by sid so it follows
  # re-sorts and re-indexing; recomputed every tick from the live row->sid mapping
  $sr = -1
  if ($script:selectedSid) { for ($si = 0; $si -lt $MAXROWS; $si++) { if ($script:rowSids[$si] -eq $script:selectedSid) { $sr = $si; break } } }
  if ($hr -ne $script:hoverRow -or $sr -ne $script:selRow) {
    $script:hoverRow = $hr; $script:selRow = $sr
    for ($i = 0; $i -lt $MAXROWS; $i++) {
      # a card lights (apricot fill + coral ring) when hovered OR selected. Hue shift (not
      # lightness) because cream->white is a ~2% delta nobody sees, and hue is the second-
      # most-sensitive channel after edges. The edit/close action icons brighten on HOVER
      # only, so a merely-selected card is lit without action-affordance clutter.
      $lit = ($i -eq $hr -or $i -eq $sr)
      $rowPanel[$i].BackColor = $(if ($lit) { [System.Drawing.Color]::FromArgb(254,240,233) } else { [System.Drawing.Color]::FromArgb(250,249,245) })
      $rowPanel[$i].Invalidate()   # repaint the ring (appears/disappears with hover or selection)
      $rowEdit[$i].ForeColor = $(if ($i -eq $hr) { [System.Drawing.Color]::FromArgb(95,95,105) } else { [System.Drawing.Color]::FromArgb(216,216,220) })
      $rowClose[$i].ForeColor = $(if ($i -eq $script:xHoverIdx) { [System.Drawing.Color]::FromArgb(220,70,70) } elseif ($i -eq $hr) { [System.Drawing.Color]::FromArgb(150,150,155) } else { [System.Drawing.Color]::FromArgb(216,216,220) })
    }
  }
  }

  if (($now - $script:startAt).TotalSeconds -ge 6 -and ($now - $script:lastClaude).TotalSeconds -ge 2) {
    $script:lastClaude = $now
    if (-not (Get-Process -Name claude -ErrorAction SilentlyContinue)) { [System.Windows.Forms.Application]::Exit() }
  }
  # approved-command watch: the platform emits nothing between "user approved" and "tool
  # finished", so while a card sits on attention with an armed .pending sidecar we look
  # for the pending command ITSELF running as a child of that session's claude.exe --
  # born after the dialog appeared. That is proof of approval (never a guess): flip the
  # card back to thinking. No match -> leave the card alone (recovers on PostToolUse as
  # before). Runs only while something is pending; cost is one CIM query per 1.2s.
  if (($now - $script:lastPend).TotalMilliseconds -ge 1200) {
    $script:lastPend = $now
    foreach ($pf in @(Get-ChildItem $sessDir -Filter '*.pending' -File -ErrorAction SilentlyContinue)) {
      $sess = $pf.FullName.Substring(0, $pf.FullName.Length - 8)
      $c = RU $sess
      if (-not $c) { Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue; continue }
      $p = $c -split "`t"
      if ($p[0] -ne 'attention') { continue }   # disarm/cleanup is pet-event's job
      $q = (RU $pf.FullName) -split "`t"
      if ($q.Count -lt 3) { Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue; continue }
      $cpid = 0; [void][int]::TryParse($q[0], [ref]$cpid)
      $arm = 0L; [void][long]::TryParse($q[1], [ref]$arm)
      $snip = $q[2]
      if ($cpid -le 0 -or -not $snip) { Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue; continue }
      foreach ($proc in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$cpid" -ErrorAction SilentlyContinue)) {
        $cl = ($proc.CommandLine + '') -replace '[\s\\"''`]+', ''   # keep in sync with pet-event.ps1
        if (-not $cl) { continue }
        if ($cl.Contains('pet-event.ps1')) { continue }   # our own hooks are claude's children too
        if (-not $cl.Contains($snip)) { continue }
        $born = 0L
        try { $born = [DateTimeOffset]::new((Get-Date $proc.CreationDate).ToUniversalTime(), [TimeSpan]::Zero).ToUnixTimeMilliseconds() } catch {}
        if ($born -le 0 -or $born -lt ($arm - 2000)) { continue }   # predates the dialog -> not ours
        while ($p.Count -lt 5) { $p += '' }
        $p[0] = 'thinking'; $p[1] = L 'thinking' $p[1]; $p[4] = "$(& $nowMs)"
        WU $sess ($p -join "`t")
        Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue
        $script:fsDirty = $true
        break
      }
    }
  }
  # interrupt watch: flip a hung 'thinking' card to idle when its transcript shows an
  # Esc-interrupt as the latest entry (interrupts fire no Stop hook). Slow cadence; only
  # thinking cards pay the tail read. 'busy' events also write the 'thinking' key, so this
  # covers both.
  if (($now - $script:lastIntr).TotalMilliseconds -ge 700) {
    $script:lastIntr = $now
    for ($i = 0; $i -lt $MAXROWS; $i++) {
      if ($script:rowKeys[$i] -ne 'thinking') { continue }
      $sid = $script:rowSids[$i]; if (-not $sid) { continue }
      $sess = Join-Path $sessDir $sid
      $c = RU $sess; if (-not $c) { continue }
      $p = $c -split "`t"
      if ($p[0] -ne 'thinking') { continue }   # re-read: the row cache can lag a real state change
      $tpI = ''; if ($p.Count -ge 9) { $tpI = $p[8] }
      if (-not $tpI) { continue }
      if (Test-Interrupted $tpI) {
        while ($p.Count -lt 9) { $p += '' }
        $p[0] = 'idle'; $p[1] = L 'idle' 'idle'; $p[4] = "$(& $nowMs)"
        WU $sess ($p -join "`t")
        $script:fsDirty = $true
        LogEv ('interrupt->idle sid={0}' -f $sid)
      }
    }
  }
  # nonce channel poller (knife 2): drive the async tab-select without blocking the UI
  # thread. For each in-flight window scan once for its nonce tab; a hit selects it (in the
  # .cs) and clears the slot; past the deadline give up (the window-level jump already
  # landed) and clear. Only runs while a nonce is in flight.
  if ($script:nonceInFlight.Count -gt 0 -and ($now - $script:lastNoncePoll).TotalMilliseconds -ge 180) {
    $script:lastNoncePoll = $now
    foreach ($hk in @($script:nonceInFlight.Keys)) {
      $e = $script:nonceInFlight[$hk]
      $h = [IntPtr]$hk
      if (-not [Lp]::IsWin($h)) { $script:nonceInFlight.Remove($hk); continue }
      $r = 0; try { $r = [PetWtJump]::TryFocusNonce($h, $e.nonce) } catch { $r = 0 }
      if ($r -eq 1) {
        $script:nonceInFlight.Remove($hk)
        LogEv ('wtab nonce hit hwnd={0} shell={1} scan={2}ms' -f $hk, $e.shellPid, [PetWtJump]::LastScanMs)
      } elseif ($now -ge $e.deadline) {
        $script:nonceInFlight.Remove($hk)
        LogEv ('wtab nonce miss hwnd={0} shell={1}' -f $hk, $e.shellPid)
      }
    }
  }
})

$form.add_Shown({ LogEv ('resident up wtJump=' + [int]$script:wtJump); Render 'idle'; Update-Card; $tick.Start() })
[System.Windows.Forms.Application]::Run($form)
foreach ($f in $script:frames.Values) { $f.Dispose() }
try { $fsw.EnableRaisingEvents = $false; $fsw.Dispose() } catch {}
$card.Dispose(); $form.Dispose()
Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
try { $script:petMutex.ReleaseMutex() } catch {}
try { $script:petMutex.Dispose() } catch {}
