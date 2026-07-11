# Guard: detail-author feature. The shown snippet can be YOUR prompt or CLAUDE's reply (a done->busy
# carry brings the reply into a thinking card). pet-event records the author as field 11; the resident
# marks Claude-authored snippets with a "Claude:" prefix (your prompt stays unmarked). Static asserts
# on pet-event (text only, no parse -- it is pwsh-only) + behavioral test of the resident's Fmt-Detail.
# Exit 1 on red. Runs under BOTH pwsh and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$PET = 'C:\Users\28608\claude-pet\pet'
$RES = Join-Path $PET 'pet-resident.ps1'; $EV = Join-Path $PET 'pet-event.ps1'
if (-not (Test-Path $RES)) { $RES = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\pet-resident.ps1'; $EV = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\pet-event.ps1' }
$fail=@(); function Red($m){ $script:fail+=$m; Write-Host "RED  $m" }; function Grn($m){ Write-Host "ok   $m" }

# ---- pet-event: records the author (field 11), sets it on prompt/done, carries it otherwise ----
$ev = [IO.File]::ReadAllText($EV, [Text.Encoding]::UTF8)
if($ev -match 'function ExistingAuthor'){ Grn "pet-event: ExistingAuthor helper (reads field 11)" } else { Red "pet-event: ExistingAuthor missing" }
if($ev -match 'function WriteSession\(\$key, \$label, \$title, \$detail, \$model, \$detailAuthor\)'){ Grn "pet-event: WriteSession takes \$detailAuthor" } else { Red "pet-event: WriteSession has no author param" }
if($ev -match '\$cwdF, \$detailAuthor\) -join'){ Grn "pet-event: author appended to the record (field 11)" } else { Red "pet-event: author not written to the record" }
if($ev -match 'if \(\$null -eq \$detailAuthor\) \{ \$detailAuthor = ExistingAuthor \}'){ Grn "pet-event: author defaults to ExistingAuthor (carried)" } else { Red "pet-event: author carry-default missing" }
if($ev -match "WriteSession 'thinking' '.+' \`$title \`$clean \`$null 'user'"){ Grn "pet-event: prompt -> author='user'" } else { Red "pet-event: prompt does not set author='user'" }
if($ev -match "WriteSession 'done' '.+' \(TitleOr\) \`$r\.text \`$r\.model 'claude'"){ Grn "pet-event: done(reply) -> author='claude'" } else { Red "pet-event: done(reply) does not set author='claude'" }

# ---- resident: Fmt-Detail marks Claude, leaves your prompt + empty alone ----
$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($RES,[ref]$t,[ref]$e)
if($e.Count){ Red "resident parse error"; Write-Host "GUARD FAILED"; exit 1 }
$d = ($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Fmt-Detail'},$true))
if($d.Count -ne 1){ Red "Fmt-Detail not defined"; Write-Host "GUARD FAILED"; exit 1 }
Invoke-Expression $d[0].Extent.Text
if((Fmt-Detail ([pscustomobject]@{detail='foo';detailAuthor='claude'})) -eq 'Claude: foo'){ Grn "Fmt-Detail: claude -> 'Claude: <text>'" } else { Red "Fmt-Detail claude prefix wrong" }
if((Fmt-Detail ([pscustomobject]@{detail='foo';detailAuthor='user'})) -eq 'foo'){ Grn "Fmt-Detail: user -> plain (unmarked)" } else { Red "Fmt-Detail user should be unmarked" }
if((Fmt-Detail ([pscustomobject]@{detail='foo';detailAuthor=''})) -eq 'foo'){ Grn "Fmt-Detail: unknown author -> plain" } else { Red "Fmt-Detail unknown author wrong" }
if((Fmt-Detail ([pscustomobject]@{detail='';detailAuthor='claude'})) -eq ''){ Grn "Fmt-Detail: empty detail -> '' (no 'Claude:' leak under privacy)" } else { Red "Fmt-Detail emits a bare 'Claude:' on empty detail" }

# ---- resident wiring ----
$raw = [IO.File]::ReadAllText($RES)
$fc = ([regex]::Matches($raw, 'Fmt-Detail \$s')).Count
if($fc -ge 3){ Grn "resident: Fmt-Detail wired in card(x2)+tooltip ($fc sites)" } else { Red "resident: Fmt-Detail wired in <3 render sites ($fc)" }
if($raw -match 'detailAuthor=\$\(if\(\$p\.Count -ge 11\)'){ Grn "resident: detailAuthor read from field 11 onto the list item" } else { Red "resident: detailAuthor not read from field 11" }
if($raw -match '\|\$\(\$_\.detailAuthor\)'){ Grn "resident: \$sig includes detailAuthor (re-render on author change)" } else { Red "resident: \$sig missing detailAuthor" }

if($fail.Count){ Write-Host "`nGUARD FAILED: $($fail.Count) red"; exit 1 } else { Write-Host "`nGUARD PASS (detail-author)"; exit 0 }
