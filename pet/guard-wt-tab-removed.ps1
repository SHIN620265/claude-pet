# Guard: WT tab-level jump removed; window-level + VS Code companion + load-bearing session
# fields intact. AST-based (comment/string-safe) static asserts + real new-write & self-heal
# fixtures + parse/compile/ASCII. Exit 1 on any red. Run under pwsh (invokes 5.1 for G6).
$ErrorActionPreference = 'Stop'
$pet = $PSScriptRoot
$fail = @()
function Red($m) { $script:fail += $m; Write-Host "RED  $m" }
function Grn($m) { Write-Host "ok   $m" }
function Parse($path) { $t=$null;$e=$null; $a=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e); @{ ast=$a; tokens=$t; errors=$e } }
$RES = Join-Path $pet 'pet-resident.ps1'; $EV = Join-Path $pet 'pet-event.ps1'; $SS = Join-Path $pet 'pet-session-start.ps1'

# forbidden WT-tab symbols (dynamic-concat so this guard never self-matches when read as text)
$syms = @('JumpWt','PetWtJump','TryFocusTab','TryFocusNonce','Start-NonceJump','nonceInFlight','nonceCooldown','lastNoncePoll','Get-HostTitle','PetCon','wtJump','wtab','jump-nonce','ExistingFp')
$syms += ('Jump' + '-Tab')

# --- G2: deleted files gone ---
foreach ($f in 'JumpWt.cs','jump-nonce.ps1') { if (Test-Path (Join-Path $pet $f)) { Red "G2 $f still exists" } else { Grn "G2 $f gone" } }

# --- G1: no forbidden symbol in NON-COMMENT tokens (AST tokens exclude comments) ---
foreach ($f in $RES,$EV,$SS) {
  $pp = Parse $f
  if ($pp.errors.Count) { Red "G1/parse error in $(Split-Path $f -Leaf): $($pp.errors[0].Message)" ; continue }
  $codeTok = ($pp.tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
  foreach ($s in $syms) { if ($codeTok -match [regex]::Escape($s)) { Red "G1 residual '$s' in $(Split-Path $f -Leaf) (non-comment token)" } }
}
if ($fail.Count -eq 0) { Grn "G1 no residual WT-tab symbols in active tokens" }

# --- G3/G7: Jump-Row AST body -- calls Write-JumpRequest + Activate, and NO tab logic ---
$rp = Parse $RES
$jr = @($rp.ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Jump-Row' }, $true))
if ($jr.Count -ne 1) { Red "G3 Jump-Row not found (or dup)" } else {
  $jr = $jr[0]
  $cmds = @($jr.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
  if ($cmds -contains 'Write-JumpRequest') { Grn "G3 Jump-Row calls Write-JumpRequest (VS Code)" } else { Red "G3 Jump-Row no longer calls Write-JumpRequest" }
  $act = @($jr.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member.Value)" -eq 'Activate' }, $true))
  if ($act.Count -ge 1) { Grn "G3 Jump-Row calls ::Activate (window-level)" } else { Red "G3 Jump-Row no longer activates the window" }
  foreach ($bad in ('Jump'+'-Tab'),'Start-NonceJump') { if ($cmds -contains $bad) { Red "G7 Jump-Row still calls '$bad'" } }
  $types = @($jr.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] }, $true) | ForEach-Object { "$($_.TypeName.FullName)" })
  if ($types -contains 'PetWtJump') { Red "G7 Jump-Row still references [PetWtJump]" }
  $vars = @($jr.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
  if ($vars -contains 'wtab') { Red "G7 Jump-Row still uses `$wtab" }
  if ($fail.Count -eq 0) { Grn "G7 Jump-Row has no tab logic" }
}
# KEEP functions still DEFINED (AST), not just present as text
$defs = @($rp.ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
foreach ($k in 'Jump-Row','Find-HostWindow','Write-JumpRequest') { if ($defs -notcontains $k) { Red "G3 KEEP function '$k' no longer defined" } }
$lpMembers = ($rp.ast.Extent.Text -match 'PickWindowForPath')
if ($lpMembers) { Grn "G3 PickWindowForPath (multi-window) present" } else { Red "G3 PickWindowForPath vanished" }

# --- G5: interrupt watch defined + reads transcript at index 8 ($p[8]) ---
if ($defs -contains 'Test-Interrupted') { Grn "G5 Test-Interrupted defined" } else { Red "G5 Test-Interrupted gone" }
$idx8 = @($rp.ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Index -is [System.Management.Automation.Language.ConstantExpressionAst] -and "$($n.Index.Value)" -eq '8' -and "$($n.Target.Extent.Text)" -eq '$p' }, $true))
if ($idx8.Count -ge 1) { Grn "G5 transcript still read at `$p[8]" } else { Red "G5 no `$p[8] transcript read remains" }

# --- G6: parse (5.1 resident, pwsh hooks) + Lp compile + resident ASCII ---
& powershell.exe -NoProfile -Command "`$e=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$RES',[ref]`$null,[ref]`$e);if(`$e.Count){exit 1}"
if ($LASTEXITCODE -eq 0) { Grn "G6 resident parses under PS 5.1" } else { Red "G6 resident 5.1 parse FAILED" }
$bytes = [IO.File]::ReadAllBytes($RES); if ($bytes | Where-Object { $_ -gt 127 }) { Red "G6 resident has non-ASCII bytes" } else { Grn "G6 resident pure-ASCII" }
# Lp compile must be checked under Windows PowerShell 5.1 (the resident's real runtime);
# pwsh 7 (.NET Core) needs extra WinForms deps and would false-red, so shell to 5.1.
$env:GUARD_RES = $RES
$lpBody = @'
$src=[IO.File]::ReadAllText($env:GUARD_RES,[Text.Encoding]::UTF8)
$m=[regex]::Match($src,'(?s)\$cs = @"\r?\n(.*?)\r?\n"@')
if(-not $m.Success){ exit 2 }
try{ Add-Type -TypeDefinition $m.Groups[1].Value -ReferencedAssemblies System.Windows.Forms,System.Drawing -ErrorAction Stop; exit 0 }catch{ exit 1 }
'@
$lpChk = Join-Path $env:TEMP ("lpchk_" + [Guid]::NewGuid().ToString('N') + ".ps1")
Set-Content -Path $lpChk -Value $lpBody -Encoding ascii
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lpChk
switch ($LASTEXITCODE) { 0 { Grn "G6 Lp (`$cs) compiles under PS 5.1" } 2 { Red "G6 could not locate `$cs block" } default { Red "G6 Lp compile FAILED under 5.1" } }
Remove-Item $lpChk -Force -ErrorAction SilentlyContinue; Remove-Item Env:\GUARD_RES -ErrorAction SilentlyContinue
foreach ($h in $EV,$SS) { $hp = Parse $h; if ($hp.errors.Count) { Red "G6 hook parse FAILED $(Split-Path $h -Leaf)" } else { Grn "G6 $(Split-Path $h -Leaf) parses" } }

# --- G4: fixtures under a temp USERPROFILE (pet-state.txt=off so no resident launch) ---
$old = $env:USERPROFILE
$tmp = Join-Path $env:TEMP ("petguard_" + [Guid]::NewGuid().ToString('N'))
try {
  $sess = Join-Path $tmp '.claude\pet-data\sessions'; New-Item -ItemType Directory -Force -Path $sess | Out-Null
  Set-Content -Path (Join-Path $tmp '.claude\pet-data\pet-state.txt') -Value 'off' -Encoding ascii
  $env:USERPROFILE = $tmp
  # G4a NEW WRITE: fresh session -> pet-session-start writes a 10-field idle record, field8 empty
  $j1 = '{"session_id":"gnew","cwd":"D:\\proj","transcript_path":"C:\\t\\a.jsonl","source":"startup"}'
  $j1 | & pwsh -NoProfile -ExecutionPolicy Bypass -File $SS
  $pn = ([IO.File]::ReadAllText((Join-Path $sess 'gnew'),[Text.Encoding]::UTF8)) -split "`t"
  if ($pn.Count -eq 10) { Grn "G4a new write = 10 fields" } else { Red "G4a new write field count $($pn.Count) != 10" }
  if ($pn[7] -eq '') { Grn "G4a new write field8 empty" } else { Red "G4a new write field8 not empty (='$($pn[7])')" }
  if ($pn[8] -eq 'C:\t\a.jsonl') { Grn "G4a new write transcript at idx8" } else { Red "G4a new write transcript wrong at idx8 (='$($pn[8])')" }
  if ($pn[9] -eq 'D:\proj') { Grn "G4a new write cwd at idx9" } else { Red "G4a new write cwd wrong at idx9 (='$($pn[9])')" }
  # G4b STALE SELF-HEAL: existing 10-field record with non-empty field8 -> resume clears field8, keeps 8/9
  $stale = @('idle','x','t','d','1','','111','STALE_FP','C:\t\b.jsonl','D:\proj') -join "`t"
  [IO.File]::WriteAllText((Join-Path $sess 'gheal'), $stale, (New-Object Text.UTF8Encoding($false)))
  $j2 = '{"session_id":"gheal","cwd":"D:\\proj","transcript_path":"C:\\t\\b.jsonl","source":"resume"}'
  $j2 | & pwsh -NoProfile -ExecutionPolicy Bypass -File $SS
  $ph = ([IO.File]::ReadAllText((Join-Path $sess 'gheal'),[Text.Encoding]::UTF8)) -split "`t"
  if ($ph.Count -eq 10) { Grn "G4b self-heal = 10 fields" } else { Red "G4b self-heal field count $($ph.Count) != 10" }
  if ($ph[7] -eq '') { Grn "G4b stale field8 cleared" } else { Red "G4b stale field8 NOT cleared (='$($ph[7])')" }
  if ($ph[8] -eq 'C:\t\b.jsonl') { Grn "G4b transcript intact at idx8" } else { Red "G4b transcript shifted/lost at idx8 (='$($ph[8])')" }
  if ($ph[9] -eq 'D:\proj') { Grn "G4b cwd intact at idx9" } else { Red "G4b cwd shifted/lost at idx9 (='$($ph[9])')" }
} finally { $env:USERPROFILE = $old; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($fail.Count) { Write-Host "`nGUARD FAILED: $($fail.Count) red"; exit 1 } else { Write-Host "`nGUARD PASS (G1-G7 green)"; exit 0 }
