# Guard: background-running knife. Behavioral tests on the resident's own detection functions
# (extracted via AST, no GUI) + static wiring/never-lie asserts. Exit 1 on any red. Run under pwsh.
$ErrorActionPreference = 'Stop'
$RES = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent)) 'claude-pet\pet\pet-resident.ps1'
if (-not (Test-Path $RES)) { $RES = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\pet-resident.ps1' }
$STR = Join-Path (Split-Path $RES) 'strings.json'
$fail = @(); function Red($m){ $script:fail += $m; Write-Host "RED  $m" }; function Grn($m){ Write-Host "ok   $m" }

# ---- extract the detection functions from the resident (AST extents) and define them here ----
$t=$null;$e=$null; $ast=[System.Management.Automation.Language.Parser]::ParseFile($RES,[ref]$t,[ref]$e)
if($e.Count){ Red "resident parse error: $($e[0].Message)"; Write-Host "GUARD FAILED"; exit 1 }
$defs = @($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($fn in 'BgHeld','BgTaskId','BgScanN','BgRunning'){
  $d = $defs | Where-Object { $_.Name -eq $fn } | Select-Object -First 1
  if(-not $d){ Red "function $fn not defined in resident"; continue }
  Invoke-Expression $d.Extent.Text
}
function LogEv($m){}                        # stub (BgRunning logs shape drift)
$script:bgState=@{}; $script:bgShape=@{}
if($fail.Count){ Write-Host "`nGUARD FAILED (functions missing)"; exit 1 }
Grn "BgHeld/BgTaskId/BgScanN/BgRunning extracted + defined"

# ---- behavioral fixtures ----
$tmp = Join-Path $env:TEMP ("bgguard_"+[Guid]::NewGuid().ToString('N'))
$script:bgTasksRoot = Join-Path $tmp 'tasksroot'
$slug='gslug'; $sid='gsid'
$tasksDir = Join-Path $script:bgTasksRoot (Join-Path $slug (Join-Path $sid 'tasks'))
New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
$proj = Join-Path $tmp (Join-Path 'proj' $slug); New-Item -ItemType Directory -Force -Path $proj | Out-Null
$tp = Join-Path $proj "$sid.jsonl"; [IO.File]::WriteAllText($tp,'',(New-Object Text.UTF8Encoding($false)))
$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$pid0=$PID
try {
  # BgHeld: held vs free
  $hf = Join-Path $tasksDir 'bHELD.output'; [IO.File]::WriteAllText($hf,'x',(New-Object Text.UTF8Encoding($false)))
  if(-not (BgHeld $hf)){ Grn "BgHeld free file = false" } else { Red "BgHeld reported a free file as held" }
  $fs=[IO.File]::Open($hf,'Open','ReadWrite','None')
  if(BgHeld $hf){ Grn "BgHeld held file = true" } else { Red "BgHeld missed a held file" }
  # BgTaskId extraction
  if((BgTaskId 'Async agent launched ... agentId: aabbccddee1122') -eq 'aabbccddee1122'){ Grn "BgTaskId agentId" } else { Red "BgTaskId agentId parse" }
  if((BgTaskId 'Command running in background with ID: bhn9vrsr5') -eq 'bhn9vrsr5'){ Grn "BgTaskId bg-bash ID" } else { Red "BgTaskId bg ID parse" }
  # BgRunning: old 7-field record (no transcript) -> honest false, never lie
  if(-not (BgRunning $sid '' $pid0 $now)){ Grn "BgRunning old-record(no field9) = false" } else { Red "BgRunning lied on a record with no transcript" }
  # BgRunning: a held b*.output in the session's tasks dir -> running (B path)
  $script:bgState=@{}; $script:bgShape=@{}
  if(BgRunning $sid $tp $pid0 $now){ Grn "BgRunning held b*.output = true (B path)" } else { Red "BgRunning missed a held background bash" }
  # release -> not running
  $fs.Close(); $fs=$null
  $script:bgState=@{}; $script:bgShape=@{}
  if(-not (BgRunning $sid $tp $pid0 $now)){ Grn "BgRunning after release = false (recovers)" } else { Red "BgRunning stuck running after handle released" }
  # N-path: TaskStop terminates without a <task-notification> -> must clear pending (real regression)
  $u8=New-Object Text.UTF8Encoding($false); $ts=(Get-Date).ToString('o')
  $agLaunch='{"type":"user","timestamp":"'+$ts+'","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_AG1","content":[{"type":"text","text":"Async agent launched successfully. agentId: adeadbeef012345678"}]}]}}'
  $agUse='{"type":"assistant","timestamp":"'+$ts+'","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_AG1","name":"Agent","input":{}}]}}'
  $stop='{"type":"assistant","timestamp":"'+$ts+'","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_ST1","name":"TaskStop","input":{"task_id":"adeadbeef012345678"}}]}}'
  [IO.File]::WriteAllText($tp, ($agUse+"`n"+$agLaunch+"`n"), $u8)
  $script:bgState=@{}; $st1=BgScanN $sid $tp
  if($st1.pending.Count -eq 1){ Grn "N tracks a live agent launch (pending=1)" } else { Red "N did not track an agent launch (pending=$($st1.pending.Count))" }
  [IO.File]::WriteAllText($tp, ($agUse+"`n"+$agLaunch+"`n"+$stop+"`n"), $u8)
  $script:bgState=@{}; $st2=BgScanN $sid $tp
  if($st2.pending.Count -eq 0){ Grn "N clears on TaskStop (no <task-notification>)" } else { Red "N stuck pending after TaskStop -- the false-positive regression" }
  # N must NOT track background Bash (that is B's job; N-tracked bash goes stale on TaskStop/miss)
  $bashUse='{"type":"assistant","timestamp":"'+$ts+'","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_BS1","name":"Bash","input":{"run_in_background":true}}]}}'
  $bashRes='{"type":"user","timestamp":"'+$ts+'","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_BS1","content":[{"type":"text","text":"Command running in background with ID: bdeadbeef1"}]}]}}'
  [IO.File]::WriteAllText($tp, ($bashUse+"`n"+$bashRes+"`n"), $u8)
  $script:bgState=@{}; $st3=BgScanN $sid $tp
  if($st3.pending.Count -eq 0){ Grn "N does NOT track background bash (left to B)" } else { Red "N tracked a bash launch (should be B-only): pending=$($st3.pending.Count)" }
} finally { if($fs){ try{$fs.Close()}catch{} }; Remove-Item $tmp -Recurse -Force -EA SilentlyContinue }

# ---- static never-lie + wiring asserts on the resident text ----
$raw = [IO.File]::ReadAllText($RES)
$br = ($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'BgRunning'},$true))[0].Extent.Text
if($br -match "if \(-not \`$tp\)"){ Grn "never-lie: no-transcript -> early false" } else { Red "BgRunning missing no-transcript guard" }
if($br -match "notlike 'claude"){ Grn "never-lie: claude-dead -> pending cleared" } else { Red "BgRunning missing claude-liveness guard" }
if($br -match "birthMs -lt 0"){ Grn "never-lie: metadata-miss -> false" } else { Red "BgRunning missing metadata-miss guard" }
if($br -match "lt \`$birthMs"){ Grn "birth-time guard (PID-reuse / pre-restart)" } else { Red "BgRunning missing birth-time comparison" }
foreach($w in '\$script:rowBg','\.bg','bgRunning'){ if($raw -match $w){ Grn "wired: $w present" } else { Red "render not wired: $w missing" } }
# i18n
try { $j=Get-Content $STR -Raw | ConvertFrom-Json; foreach($lc in 'zh','en','ja'){ if($j.$lc.bgRunning){ Grn "strings.$lc.bgRunning = $($j.$lc.bgRunning)" } else { Red "strings.$lc.bgRunning missing" } } } catch { Red "strings.json invalid: $_" }

if($fail.Count){ Write-Host "`nGUARD FAILED: $($fail.Count) red"; exit 1 } else { Write-Host "`nGUARD PASS (bg-running knife)"; exit 0 }
