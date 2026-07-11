# Guard: background tooltip S3. Static wiring asserts (LTipWin styles, Hide-Tip integration, R15
# push-before-show, rowTrunc) + behavioral tests on Update-Tip's two-state dwell (extracted, no real
# window) + Build-TipBitmap null/non-null + a GDI-handle stress. Exit 1 on red. MUST pass under BOTH
# pwsh and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
$RES = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent)) 'claude-pet\pet\pet-resident.ps1'
if (-not (Test-Path $RES)) { $RES = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\pet-resident.ps1' }
$fail=@(); function Red($m){ $script:fail+=$m; Write-Host "RED  $m" }; function Grn($m){ Write-Host "ok   $m" }
$raw = [IO.File]::ReadAllText($RES)
$t=$null;$e=$null; $ast=[System.Management.Automation.Language.Parser]::ParseFile($RES,[ref]$t,[ref]$e)
if($e.Count){ Red "resident parse error: $($e[0].Message)"; Write-Host "GUARD FAILED"; exit 1 }
$defs = @($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
function Def($name){ ($defs | Where-Object { $_.Name -eq $name } | Select-Object -First 1) }

# ---- static: LTipWin class ----
if($raw -match 'class LTipWin : Form'){ Grn "LTipWin class present" } else { Red "LTipWin class missing" }
$mtip = [regex]::Match($raw,'class LTipWin[\s\S]*?\n\}')
if($mtip.Success){
  $tw=$mtip.Value
  if($tw -match '0x00080000' -and $tw -match '0x08000000' -and $tw -match '0x00000020'){ Grn "LTipWin ExStyle = LAYERED|NOACTIVATE|TRANSPARENT" } else { Red "LTipWin missing LAYERED/NOACTIVATE/TRANSPARENT" }
  if($tw -match 'ShowWithoutActivation'){ Grn "LTipWin ShowWithoutActivation" } else { Red "LTipWin not ShowWithoutActivation" }
  if($tw -match '0x0084' -and $tw -match 'IntPtr\)\(-1\)'){ Grn "LTipWin WndProc returns HTTRANSPARENT for WM_NCHITTEST" } else { Red "LTipWin WndProc not all-HTTRANSPARENT" }
}
# ---- static: Hide-Tip synchronous wiring (F10) + privacy epoch (G4) ----
if($raw -match 'Hide-Tip\r?\n\s*\$gm = \$script:cardGeom'){ Grn "Hide-Tip synchronous on card click" } else { Red "Hide-Tip not on card click" }
if((Def 'Edit-Row-Layered').Extent.Text -match 'Hide-Tip'){ Grn "Hide-Tip in Edit-Row-Layered" } else { Red "Hide-Tip not in Edit-Row-Layered" }
if($raw -match 'Hide-Tip; \$menu\.Show'){ Grn "Hide-Tip before menu.Show" } else { Red "Hide-Tip not before menu.Show" }
if(([regex]::Matches($raw,'privEpoch\+\+; Hide-Tip')).Count -ge 2){ Grn "privEpoch++ + Hide-Tip on both privacy paths (G4)" } else { Red "privacy epoch/hide not on both paths" }
# ---- static: R15 push-before-show inside Show-Tip ----
$stx = (Def 'Show-Tip').Extent.Text
$iSet = $stx.IndexOf('SetBitmapStraight'); $iShow = $stx.IndexOf('.Show()')
if($iSet -ge 0 -and $iShow -ge 0 -and $iSet -lt $iShow){ Grn "Show-Tip pushes bitmap BEFORE Show (R15)" } else { Red "Show-Tip shows before pushing bitmap (R15 flash)" }
if($stx -match 'WinRect' -and $stx -match 'FromHandle' -and $stx -match 'rect\[2\] -le \$rect\[0\]'){ Grn "Show-Tip: WinRect + card-monitor workarea + invalid-geometry abort (F3/F12/G6)" } else { Red "Show-Tip placement/abort under-wired" }
if($stx -match '\$sideW -lt \$minW'){ Grn "Show-Tip: abort when no usable side width (G6)" } else { Red "Show-Tip missing min-width abort" }
# ---- static: Update-Tip called in the tick; tipWin created + disposed ----
if($raw -match 'Update-Tip \$hr \$hi'){ Grn "Update-Tip wired into the tick" } else { Red "Update-Tip not called in the tick" }
if($raw -match '\$script:tipWin = New-Object LTipWin'){ Grn "tipWin created" } else { Red "tipWin not created" }
if($raw -match '\$script:tipWin\)\s*\{\s*\$script:tipWin\.Dispose'){ Grn "tipWin disposed at shutdown (F13)" } else { Red "tipWin not disposed" }
if($raw -match '\$script:rowTrunc\[\$i\] = '){ Grn "rowTrunc populated in Build-CardStatic (F11)" } else { Red "rowTrunc not populated" }
# progressive disclosure: the tooltip status shows the generic STATE (+count), NOT the compact card
# label "bg: X +N" -- otherwise the first task is repeated (inline AND in the list below)
$btx = (Def 'Build-TipBitmap').Extent.Text
if($btx -notmatch 'Get-BgStatusLabel'){ Grn "tooltip status is generic, not the compact 'bg: X +N' (no redundancy with the list)" } else { Red "tooltip repeats the compact bg label (redundant)" }
if(($btx -match "L 'bgRunning'") -and ($btx -match '@\(\$s\.bgWhat\)\.Count')){ Grn "tooltip status = generic Background running (+count when >1)" } else { Red "tooltip status not generic-with-count" }
# detail must be its OWN block/line, not "·"-joined to the metadata (content carries its own punctuation)
if($btx -match 'text=\$s\.detail'){ Grn "tooltip: detail is its own line/block (not middot-joined)" } else { Red "tooltip detail still inline-joined to metadata" }
# the tooltip shows the conversation ONLY where the CARD does (thinking/attention); a bg tooltip is
# purely the running list (no conversation) -> card & tooltip content stay in lockstep, no divergence
if($btx -match "\`$s\.detail -and \(\`$s\.key -eq 'thinking' -or \`$s\.key -eq 'attention'"){ Grn "tooltip: conversation gated on thinking/attention (mirrors the card B+)" } else { Red "tooltip conversation not gated -> bg tooltip would re-show the noisy done detail" }
if($btx -notmatch 'divider=\$true'){ Grn "tooltip: no divider (bg tooltip is a clean running list, nothing to separate)" } else { Red "stale divider block still present" }

# ---- behavioral: Build-TipBitmap ----
foreach($fn in 'L','Get-BgStatusLabel','Get-RoundPath','Build-TipBitmap','Update-Tip'){ Invoke-Expression (Def $fn).Extent.Text }
$stateColors = @{ bgRunning=[System.Drawing.Color]::FromArgb(60,130,210); done=[System.Drawing.Color]::FromArgb(70,170,90) }
$script:STR = [pscustomobject]@{ bgPrefix='bg'; bgRunning='Background running'; newSession='new' }
$script:privacy = $false
$s = [pscustomobject]@{ title='My Session Title'; label='done'; key='done'; bg=$true; model='Opus'; detail=''; bgWhat=@([pscustomobject]@{kind='shell';id='b1abc';label='mvn spring-boot:run'}) }
$tip = Build-TipBitmap $s 300 800 1.0
if($tip -and $tip.bmp -and $tip.w -eq 300){ Grn "Build-TipBitmap valid -> bitmap" ; $tip.bmp.Dispose() } else { Red "Build-TipBitmap returned null for valid input" }
$tipN = Build-TipBitmap $s 20 800 1.0
if(-not $tipN){ Grn "Build-TipBitmap too-narrow -> null (abort, no tooltip)" } else { Red "Build-TipBitmap should abort on tiny width"; if($tipN.bmp){$tipN.bmp.Dispose()} }
# privacy on -> no bg item lines drawn (indirect: still builds, but the running list is omitted)
$script:privacy = $true
$tipP = Build-TipBitmap $s 300 800 1.0
if($tipP -and $tipP.bmp){ Grn "Build-TipBitmap under privacy still builds (list omitted)"; $tipP.bmp.Dispose() } else { Red "Build-TipBitmap failed under privacy" }
$script:privacy = $false

# ---- GDI-handle stress (G7/F13): repeated build/dispose must not grow GDI objects ----
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class GdiCount { [DllImport("user32.dll")] static extern int GetGuiResources(IntPtr h,int f);
  public static int N(){ return GetGuiResources(System.Diagnostics.Process.GetCurrentProcess().Handle, 0); } }
"@
[void][GdiCount]::N(); for($i=0;$i -lt 30;$i++){ $b=Build-TipBitmap $s 300 800 1.0; if($b){$b.bmp.Dispose()} }
[GC]::Collect(); [GC]::WaitForPendingFinalizers()
$g0=[GdiCount]::N()
for($i=0;$i -lt 200;$i++){ $b=Build-TipBitmap $s 320 800 1.0; if($b){$b.bmp.Dispose()} }
[GC]::Collect(); [GC]::WaitForPendingFinalizers()
$g1=[GdiCount]::N()
if(($g1 - $g0) -le 20){ Grn "GDI stress: 200x build/dispose, delta=$($g1-$g0) (<=20, no leak)" } else { Red "GDI LEAK: delta=$($g1-$g0) over 200 builds" }

# ---- behavioral: Update-Tip two-state dwell (stub Show-Tip/Hide-Tip) ----
function Show-Tip($row){ $script:_shown++; $script:tipShownKey = 'shown' }
function Hide-Tip { $script:_hidden++; $script:tipShownKey = $null }
$script:layered=$true; $script:tipWin=[pscustomobject]@{}; $menu=[pscustomobject]@{Visible=$false}
$script:dragging=$false; $script:editing=$false
$script:rowTrunc = New-Object 'bool[]' 5
$script:TIP_DWELL=400; $script:tipContentGen=1; $script:privEpoch=0
$script:cardList=@([pscustomobject]@{sid='s1';bg=$true})
$script:tipShownKey=$null; $script:tipCandKey=$null; $script:tipSince=(Get-Date); $script:_shown=0; $script:_hidden=0
Update-Tip 0 0
if($script:_shown -eq 0 -and $script:tipCandKey){ Grn "dwell: candidate armed, not shown immediately" } else { Red "dwell: armed wrong (shown=$($script:_shown) cand=$($script:tipCandKey))" }
Update-Tip 0 0
if($script:_shown -eq 0){ Grn "dwell: within window -> not shown" } else { Red "dwell: shown too early" }
$script:tipSince = (Get-Date).AddMilliseconds(-500)
Update-Tip 0 0
if($script:_shown -ge 1){ Grn "dwell: eligible stationary row REACHES dwell -> Show (never stuck hidden, G3)" } else { Red "G3 BUG: stuck hidden, never shows" }
# row-swap under stationary cursor resets the candidate (F1)
$script:tipShownKey=$null; $script:tipCandKey=$null; $script:_shown=0
Update-Tip 0 0; $k1=$script:tipCandKey
$script:cardList=@([pscustomobject]@{sid='s2';bg=$true})
Update-Tip 0 0
if($script:tipCandKey -ne $k1){ Grn "row-swap under stationary cursor -> candidate reset (F1)" } else { Red "stale candidate after re-sort" }
# SHOWN + ineligible (dragging) -> Hide
$script:tipShownKey='shown'; $script:_hidden=0; $script:dragging=$true
Update-Tip 0 0
if($script:_hidden -ge 1 -and -not $script:tipShownKey){ Grn "SHOWN + ineligible -> Hide" } else { Red "SHOWN did not hide on ineligible" }
$script:dragging=$false
# SHOWN + content-gen bump -> Hide (F2/G4)
$script:cardList=@([pscustomobject]@{sid='s1';bg=$true}); $script:tipContentGen=1; $script:privEpoch=0; $script:tipShownKey='s1|1|0'; $script:_hidden=0
Update-Tip 0 0
if($script:_hidden -eq 0){ Grn "SHOWN + same key -> stays" } else { Red "hid on an unchanged key" }
$script:tipContentGen=2
Update-Tip 0 0
if($script:_hidden -ge 1){ Grn "SHOWN + content-gen bump -> Hide+rebuild (F2/G4)" } else { Red "did not invalidate on content change" }
# non-truncated, non-bg row -> ineligible (no tooltip noise)
$script:cardList=@([pscustomobject]@{sid='s3';bg=$false}); $script:rowTrunc[0]=$false; $script:tipShownKey=$null; $script:tipCandKey=$null
Update-Tip 0 0
if(-not $script:tipCandKey){ Grn "non-truncated non-bg row -> ineligible (no noise, D4)" } else { Red "armed on an ineligible row" }

if($fail.Count){ Write-Host "`nGUARD FAILED: $($fail.Count) red"; exit 1 } else { Write-Host "`nGUARD PASS (bg-what S3 tooltip)"; exit 0 }
