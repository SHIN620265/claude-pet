# Guard: the interrupted->thinking race. After a new prompt, a card must NOT re-flip to
# "interrupted" just because the OLD interrupt mark is still the transcript's last durable
# entry. Test-Interrupted returns the mark's timestamp; the watch flips only if it's at/after
# the current thinking epoch. Extracts Test-Interrupted from the resident (no GUI). Exit 1 on red.
$ErrorActionPreference='Stop'
$RES = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent)) 'claude-pet\pet\pet-resident.ps1'
if (-not (Test-Path $RES)) { $RES = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\pet-resident.ps1' }
$fail=@(); function Red($m){ $script:fail+=$m; Write-Host "RED  $m" }; function Grn($m){ Write-Host "ok   $m" }
$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($RES,[ref]$t,[ref]$e)
if($e.Count){ Red "parse: $($e[0].Message)"; Write-Host "GUARD FAILED"; exit 1 }
$d = ($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-Interrupted'},$true))
if($d.Count -ne 1){ Red "Test-Interrupted not defined"; Write-Host "GUARD FAILED"; exit 1 }
$d[0].Extent.Text | Invoke-Expression
# the watch must gate the flip on 'its >= thinking epoch' (the race fix) -- static assert
$watch = $ast.Extent.Text
if($watch -match "Test-Interrupted \`$tpI" -and $watch -match "\`$its -ge \`$tep"){ Grn "watch gates flip on interrupt-ts >= thinking epoch" } else { Red "watch missing the its>=epoch race gate" }

$u8=New-Object Text.UTF8Encoding($false); $tmp=Join-Path $env:TEMP ("iguard_"+[Guid]::NewGuid().ToString('N')+'.jsonl')
$markTs='2026-07-11T00:30:00.000Z'; $markMs=[DateTimeOffset]::Parse($markTs).ToUnixTimeMilliseconds()
$mark='{"type":"user","timestamp":"'+$markTs+'","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]","interruptedMessageId":"m"}]}}'
try {
  [IO.File]::WriteAllText($tmp, $mark+"`n", $u8)
  $r = Test-Interrupted $tmp
  if($r -eq $markMs){ Grn "Test-Interrupted returns mark timestamp" } else { Red "returns $r, expected $markMs" }
  if($r -ge ($markMs-10000)){ Grn "genuine interrupt (mark >= epoch) would flip" } else { Red "genuine interrupt would not flip" }
  if($r -lt ($markMs+10000)){ Grn "stale interrupt (epoch newer, new prompt) would NOT flip" } else { Red "stale interrupt would re-flip = the bug" }
  [IO.File]::WriteAllText($tmp, '{"type":"user","timestamp":"'+$markTs+'","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}'+"`n", $u8)
  if((Test-Interrupted $tmp) -eq 0){ Grn "non-interrupt tail -> 0" } else { Red "false positive on normal tail" }
  # interrupt mark buried under injected records (queued task-notification attachments / snapshots)
  $att='{"type":"attachment","timestamp":"'+$markTs+'","content":"<task-notification>...</task-notification>"}'
  [IO.File]::WriteAllText($tmp, ($mark+"`n"+$att+"`n"+$att+"`n"), $u8)
  if((Test-Interrupted $tmp) -eq $markMs){ Grn "interrupt mark under trailing attachments -> still detected" } else { Red "interrupt mark masked by trailing attachments (the bug)" }
  # a genuine new prompt after the interrupt supersedes it -> 0
  $newp='{"type":"user","timestamp":"'+$markTs+'","message":{"role":"user","content":[{"type":"text","text":"a new question"}]}}'
  [IO.File]::WriteAllText($tmp, ($mark+"`n"+$newp+"`n"), $u8)
  if((Test-Interrupted $tmp) -eq 0){ Grn "new prompt after interrupt -> 0 (superseded)" } else { Red "stale interrupt not cleared by a new prompt" }
} finally { Remove-Item $tmp -Force -EA SilentlyContinue }
if($fail.Count){ Write-Host "`nGUARD FAILED: $($fail.Count) red"; exit 1 } else { Write-Host "`nGUARD PASS (interrupt race)"; exit 0 }
