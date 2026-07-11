# Guard: background "what is running" S2 (statusline label A). Behavioral tests on Get-BgStatusLabel
# (AST-extracted, no GUI): render-time privacy gating, named/count formatting, and the never-lie
# fallbacks (never a bare "bg: ", never command text under privacy). Plus static wiring asserts on
# both render paths. Exit 1 on red. MUST pass under BOTH pwsh and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$RES = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent)) 'claude-pet\pet\pet-resident.ps1'
if (-not (Test-Path $RES)) { $RES = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\pet-resident.ps1' }
$STRF = Join-Path (Split-Path $RES) 'strings.json'
$fail=@(); function Red($m){ $script:fail+=$m; Write-Host "RED  $m" }; function Grn($m){ Write-Host "ok   $m" }

$t=$null;$e=$null; $ast=[System.Management.Automation.Language.Parser]::ParseFile($RES,[ref]$t,[ref]$e)
if($e.Count){ Red "resident parse error: $($e[0].Message)"; Write-Host "GUARD FAILED"; exit 1 }
$defs = @($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($fn in 'L','Get-BgStatusLabel'){
  $d = $defs | Where-Object { $_.Name -eq $fn } | Select-Object -First 1
  if(-not $d){ Red "function $fn not defined"; continue }
  Invoke-Expression $d.Extent.Text
}
if($fail.Count){ Write-Host "`nGUARD FAILED (functions missing)"; exit 1 }
$script:STR = [pscustomobject]@{ bgPrefix='bg'; bgRunning='Background running' }
Grn "Get-BgStatusLabel + L extracted"

function Item($kind,$id,$label){ [pscustomobject]@{ kind=$kind; id=$id; label=$label } }
function S($bgWhat){ [pscustomobject]@{ label='done'; bgWhat=$bgWhat } }

# privacy OFF: single named -> "bg: <label>"
$script:privacy=$false
$r = Get-BgStatusLabel (S @( (Item 'shell' 'b1' 'mvn spring-boot:run') ))
if($r -eq 'bg: mvn spring-boot:run'){ Grn "single named -> 'bg: <label>'" } else { Red "single named -> '$r'" }

# two named -> "bg(2): <first> +1"
$r2 = Get-BgStatusLabel (S @( (Item 'shell' 'b1' 'srv A'), (Item 'shell' 'b2' 'srv B') ))
if($r2 -eq 'bg(2): srv A +1'){ Grn "two named -> 'bg(2): srv A +1'" } else { Red "two named -> '$r2'" }

# count includes an unlabeled (unknown) item, name taken from the labeled one
$r3 = Get-BgStatusLabel (S @( (Item 'shell' 'b1' 'srv') , (Item 'unknown' 'z' '') ))
if($r3 -eq 'bg(2): srv +1'){ Grn "labeled+unknown -> 'bg(2): srv +1' (count includes unknown)" } else { Red "labeled+unknown -> '$r3'" }

# all labels empty -> generic (NEVER a bare 'bg: ')
$r4 = Get-BgStatusLabel (S @( (Item 'unknown' 'z' ''), (Item 'unknown' 'y' '') ))
if($r4 -eq 'Background running'){ Grn "all-empty labels -> generic (no bare 'bg: ')" } else { Red "all-empty -> '$r4'" }
if($r4 -notmatch '^bg:\s*$' -and $r4 -notmatch '^bg\(\d+\):\s*$'){ Grn "never emits an empty 'bg: '/'bg(n): '" } else { Red "emitted a content-less bg label: '$r4'" }

# empty list -> generic
$r5 = Get-BgStatusLabel (S @())
if($r5 -eq 'Background running'){ Grn "empty bgWhat -> generic" } else { Red "empty -> '$r5'" }

# privacy ON: generic ONLY, never the command text (F2/G4/R7)
$script:privacy=$true
$r6 = Get-BgStatusLabel (S @( (Item 'shell' 'b1' 'SECRET-token=deadbeef /srv/x') ))
if($r6 -eq 'Background running'){ Grn "privacy on -> generic" } else { Red "privacy on -> '$r6'" }
if($r6 -notmatch 'SECRET' -and $r6 -notmatch 'deadbeef' -and $r6 -notmatch 'srv'){ Grn "privacy on: NO command text leaks (R7)" } else { Red "PRIVACY LEAK: '$r6'" }
$script:privacy=$false

# single-item cardinality trap (F7): what.Count for a 1-element array must be 1, not a property count
$r7 = Get-BgStatusLabel (S @( (Item 'shell' 'b1' 'only') ))
if($r7 -eq 'bg: only'){ Grn "single-item count = 1 (no PS-5.1 cardinality trap, F7)" } else { Red "single-item cardinality -> '$r7'" }

# ---- static wiring asserts ----
$raw = [IO.File]::ReadAllText($RES)
# both render paths must route bg rows through Get-BgStatusLabel (layered Build-CardStatic + Region)
$calls = ([regex]::Matches($raw, 'Get-BgStatusLabel \$s')).Count
if($calls -ge 2){ Grn "both render paths call Get-BgStatusLabel ($calls sites)" } else { Red "Get-BgStatusLabel wired in <2 render paths ($calls)" }
if($raw -match 'bgWhat=\$bgWhatL' -or $raw -match 'bgWhat=\$\(') { Grn "wired: bgWhat on the list item" } else { Red "bgWhat not attached to the list item" }
if($raw -match 'bgGen=\$bgGenL' -or $raw -match 'bgGen=') { Grn "wired: bgGen on the list item" } else { Red "bgGen not attached" }
if($raw -match '\|\$\(\$_\.bgGen\)') { Grn "wired: \$sig includes bgGen (re-render on evidence change)" } else { Red "\$sig missing bgGen fingerprint" }
# i18n: bgPrefix present in all locales (read UTF8 like the resident, not Get-Content -Raw)
try { $j=([IO.File]::ReadAllText($STRF,(New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json; foreach($lc in 'zh','en','ja'){ if($j.$lc.bgPrefix){ Grn "strings.$lc.bgPrefix present" } else { Red "strings.$lc.bgPrefix missing" } } } catch { Red "strings.json invalid: $_" }

if($fail.Count){ Write-Host "`nGUARD FAILED: $($fail.Count) red"; exit 1 } else { Write-Host "`nGUARD PASS (bg-what S2)"; exit 0 }
