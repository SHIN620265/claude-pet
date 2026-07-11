# Guard: background "what is running" S1 (data core). Behavioral tests on the resident's OWN functions
# (AST-extracted, no GUI) for the never-lie invariants: Clean-BgLabel never fabricates a label, the
# kind-gated result branches never route a bash id into N, shape-drift promotion emits an 'unknown'
# evidence item (even alongside a b* hold), a single observation yields boolean+evidence consistently,
# and PS-5.1 cardinality is array-safe. Exit 1 on any red. MUST pass under BOTH pwsh and Windows
# PowerShell 5.1 (G7/F13).
$ErrorActionPreference = 'Stop'
$RES = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent)) 'claude-pet\pet\pet-resident.ps1'
if (-not (Test-Path $RES)) { $RES = Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\pet-resident.ps1' }
$fail = @(); function Red($m){ $script:fail += $m; Write-Host "RED  $m" }; function Grn($m){ Write-Host "ok   $m" }

$t=$null;$e=$null; $ast=[System.Management.Automation.Language.Parser]::ParseFile($RES,[ref]$t,[ref]$e)
if($e.Count){ Red "resident parse error: $($e[0].Message)"; Write-Host "GUARD FAILED"; exit 1 }
$defs = @($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($fn in 'Clean-BgLabel','BgAgentId','BgBashId','BgHeld','BgScanN','Get-BgObservation','BgEvidenceEq','Get-BgWhat'){
  $d = $defs | Where-Object { $_.Name -eq $fn } | Select-Object -First 1
  if(-not $d){ Red "function $fn not defined in resident"; continue }
  Invoke-Expression $d.Extent.Text
}
function LogEv($m){}
$script:bgState=@{}; $script:bgShape=@{}; $script:bgEvidence=@{}
if($fail.Count){ Write-Host "`nGUARD FAILED (functions missing)"; exit 1 }
Grn "S1 functions extracted + defined"

# ---- Clean-BgLabel: never fabricate a 'currently-executing subcommand' (G5/F6) ----
if((Clean-BgLabel 'start backend server' '$env:X=1; mvn spring-boot:run') -eq 'start backend server'){ Grn "label: description wins" } else { Red "label: description not preferred" }
$lc = Clean-BgLabel $null 'npm start && echo done'
if($lc -eq 'npm start && echo done'){ Grn "label: compound shown WHOLE (job spec)" } else { Red "label: compound mangled -> '$lc'" }
if($lc -ne 'echo done'){ Grn "label: NOT the not-yet-run trailing segment (never-lie)" } else { Red "label LIED: running job labeled as its tail 'echo done'" }
if((Clean-BgLabel $null 'cd /srv && ./server') -eq './server'){ Grn "label: safe cd-preamble stripped" } else { Red "label: cd-preamble strip -> '$(Clean-BgLabel $null 'cd /srv && ./server')'" }
if((Clean-BgLabel $null '$env:PORT=8080 && node app.js') -eq 'node app.js'){ Grn "label: safe env-preamble stripped" } else { Red "label: env-preamble -> '$(Clean-BgLabel $null '$env:PORT=8080 && node app.js')'" }
if((Clean-BgLabel $null '$env:A=1; cd /x && server') -eq 'server'){ Grn "label: multi-preamble -> server" } else { Red "label: multi-preamble -> '$(Clean-BgLabel $null '$env:A=1; cd /x && server')'" }
$lq = Clean-BgLabel $null "`$env:X='a;b'; server"
if($lq -like '*server*' -and $lq -like '*env*'){ Grn "label: quoted-semicolon -> whole (no bad split)" } else { Red "label: quoted split mangled -> '$lq'" }
$lsub = Clean-BgLabel $null '( cd x && server )'
if($lsub -like '(*server*'){ Grn "label: subshell -> whole" } else { Red "label: subshell -> '$lsub'" }
$lnest = Clean-BgLabel $null 'cd "$(pwd)" && server'
if($lnest -like 'cd *'){ Grn "label: nested `$() -> whole (not stripped)" } else { Red "label: nested mangled -> '$lnest'" }
if((Clean-BgLabel $null '$env:ONLY=1') -eq '$env:ONLY=1'){ Grn "label: standalone assignment kept whole" } else { Red "label: standalone assignment -> '$(Clean-BgLabel $null '$env:ONLY=1')'" }
if((Clean-BgLabel $null $null) -eq ''){ Grn "label: empty -> '' (UI degrades to generic)" } else { Red "label: empty not empty" }
$llong = Clean-BgLabel $null ('a' * 100)
if($llong.Length -le 64){ Grn "label: capped <=64 ($($llong.Length))" } else { Red "label: not capped ($($llong.Length))" }

# ---- kind-gated result branches never contaminate N (G2/F5) ----
$u8=New-Object Text.UTF8Encoding($false); $ts=(Get-Date).ToString('o')
$tmp = Join-Path $env:TEMP ("bgs1_"+[Guid]::NewGuid().ToString('N'))
$script:bgTasksRoot = Join-Path $tmp 'tasksroot'
$slug='cslug'; $sid='csid'
$tasksDir = Join-Path $script:bgTasksRoot (Join-Path $slug (Join-Path $sid 'tasks'))
New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
$proj = Join-Path $tmp (Join-Path 'proj' $slug); New-Item -ItemType Directory -Force -Path $proj | Out-Null
$ctp = Join-Path $proj "$sid.jsonl"; [IO.File]::WriteAllText($ctp,'',$u8)
$handles = @()
try {
  $bashUse='{"type":"assistant","timestamp":"'+$ts+'","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_BS9","name":"Bash","input":{"run_in_background":true,"command":"mvn spring-boot:run","description":"start backend"}}]}}'
  $bashRes='{"type":"user","timestamp":"'+$ts+'","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_BS9","content":[{"type":"text","text":"Command running in background with ID: bkindtest1"}]}]}}'
  [IO.File]::WriteAllText($ctp, ($bashUse+"`n"+$bashRes+"`n"), $u8)
  $script:bgState=@{}; $st=BgScanN 'ksid' $ctp
  if($st.launchIds.Count -eq 0 -and $st.pending.Count -eq 0 -and $st.known.Count -eq 0){ Grn "bash launch/result: launchIds/pending/known all empty (F5)" } else { Red "bash contaminated N: L=$($st.launchIds.Count) P=$($st.pending.Count) K=$($st.known.Count)" }
  if($st.desc['bkindtest1'] -eq 'start backend'){ Grn "bash desc resolved via shell branch" } else { Red "bash desc missing -> '$($st.desc['bkindtest1'])'" }

  $agUse='{"type":"assistant","timestamp":"'+$ts+'","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_AG9","name":"Agent","input":{"description":"review"}}]}}'
  $agBad='{"type":"user","timestamp":"'+$ts+'","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_AG9","content":[{"type":"text","text":"Command running in background with ID: bshouldnotpend"}]}]}}'
  [IO.File]::WriteAllText($ctp, ($agUse+"`n"+$agBad+"`n"), $u8)
  $script:bgState=@{}; $st2=BgScanN 'ksid2' $ctp
  if($st2.pending.Count -eq 0 -and $st2.known.Count -eq 0){ Grn "malformed agent result (no agentId) -> pending stays 0 (G2)" } else { Red "G2 BROKEN: pending=$($st2.pending.Count) known=$($st2.known.Count)" }

  $agGood='{"type":"user","timestamp":"'+$ts+'","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_AG9","content":[{"type":"text","text":"Async agent launched successfully. agentId: aa112233445566"}]}]}}'
  [IO.File]::WriteAllText($ctp, ($agUse+"`n"+$agGood+"`n"), $u8)
  $script:bgState=@{}; $st3=BgScanN 'ksid3' $ctp
  if($st3.pending.ContainsKey('aa112233445566') -and $st3.desc['aa112233445566'] -eq 'review'){ Grn "agent launch resolves pending + desc" } else { Red "agent branch: pending=$($st3.pending.Keys -join ',') desc='$($st3.desc['aa112233445566'])'" }

  # ---- single observation: boolean + evidence, cardinality 0/1/2 (F7/G1) ----
  [IO.File]::WriteAllText($ctp,'',$u8)   # empty transcript so pending stays 0 (no CIM)
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $script:bgState=@{}; $script:bgShape=@{}
  $o0 = Get-BgObservation $sid $ctp $PID $now
  if(-not $o0.running -and @($o0.evidence).Count -eq 0){ Grn "0 held -> not running, 0 evidence" } else { Red "0-case: running=$($o0.running) ev=$(@($o0.evidence).Count)" }

  $f1 = Join-Path $tasksDir 'b0001.output'; [IO.File]::WriteAllText($f1,'x',$u8); $handles += ,([IO.File]::Open($f1,'Open','ReadWrite','None'))
  $script:bgState=@{}; $script:bgShape=@{}
  $o1 = Get-BgObservation $sid $ctp $PID $now; $e1=@($o1.evidence)
  if($o1.running -and $e1.Count -eq 1 -and $e1[0].kind -eq 'shell' -and $e1[0].id -eq 'b0001'){ Grn "1 held b* -> running + 1 shell evidence (array-wrapped, F7)" } else { Red "1-case: running=$($o1.running) count=$($e1.Count) kind=$($e1[0].kind)" }
  $script:bgEvidence=@{ $sid = $o1.evidence }
  if(@(Get-BgWhat $sid).Count -eq 1){ Grn "Get-BgWhat single item -> Count 1 (no scalar unwrap, F7)" } else { Red "Get-BgWhat cardinality-1 broke: $(@(Get-BgWhat $sid).Count)" }

  $f2 = Join-Path $tasksDir 'b0002.output'; [IO.File]::WriteAllText($f2,'x',$u8); $handles += ,([IO.File]::Open($f2,'Open','ReadWrite','None'))
  $script:bgState=@{}; $script:bgShape=@{}
  $o2 = Get-BgObservation $sid $ctp $PID $now
  if($o2.running -and @($o2.evidence).Count -eq 2){ Grn "2 held b* -> 2 evidence" } else { Red "2-case: count=$(@($o2.evidence).Count)" }
  $script:bgEvidence=@{ $sid = $o2.evidence }
  if(@(Get-BgWhat $sid).Count -eq 2){ Grn "Get-BgWhat 2 -> Count 2" } else { Red "Get-BgWhat cardinality-2 broke" }

  # ---- shape-drift promotion emits 'unknown' (G1) ----
  $fd = Join-Path $tasksDir 'aDRIFT.output'; [IO.File]::WriteAllText($fd,'x',$u8); $handles += ,([IO.File]::Open($fd,'Open','ReadWrite','None'))
  # release the two b* first so this case is drift-only
  $handles[0].Close(); $handles[1].Close()
  $script:bgState=@{}; $script:bgShape=@{ 'aDRIFT' = ($now - 5000) }   # already aged past the 3s promotion
  $od = Get-BgObservation $sid $ctp $PID $now; $ed=@($od.evidence)
  if($od.running -and @($ed | Where-Object { $_.kind -eq 'unknown' -and $_.id -eq 'aDRIFT' }).Count -ge 1){ Grn "shape-drift promotion -> running + 'unknown' evidence (G1)" } else { Red "drift: running=$($od.running) kinds=$(($ed|ForEach-Object{$_.kind}) -join ',')" }
  # unknown STILL emitted when a b* hold also set B, and shells come before unknown
  $fb = Join-Path $tasksDir 'b0003.output'; [IO.File]::WriteAllText($fb,'x',$u8); $handles += ,([IO.File]::Open($fb,'Open','ReadWrite','None'))
  $script:bgState=@{}; $script:bgShape=@{ 'aDRIFT' = ($now - 5000) }
  $od2 = Get-BgObservation $sid $ctp $PID $now; $ed2=@($od2.evidence)
  $kinds = @($ed2 | ForEach-Object { $_.kind })
  if((@($ed2|Where-Object{$_.kind -eq 'shell'}).Count -ge 1) -and (@($ed2|Where-Object{$_.kind -eq 'unknown'}).Count -ge 1)){ Grn "unknown emitted even with a b* hold already setting B (G1)" } else { Red "G1: kinds=$($kinds -join ',')" }
  if(([array]::IndexOf($kinds,'shell')) -ge 0 -and ([array]::IndexOf($kinds,'shell')) -lt ([array]::IndexOf($kinds,'unknown'))){ Grn "evidence order: shells before unknown" } else { Red "order wrong: $($kinds -join ',')" }

  # ---- released -> not running + empty (single-observation consistency) ----
  foreach($h in $handles){ try{$h.Close()}catch{} }; $handles=@()
  $script:bgState=@{}; $script:bgShape=@{}
  $orel = Get-BgObservation $sid $ctp $PID $now
  if(-not $orel.running -and @($orel.evidence).Count -eq 0){ Grn "all released -> not running + 0 evidence (consistent)" } else { Red "released: running=$($orel.running) ev=$(@($orel.evidence).Count)" }
} finally {
  foreach($h in $handles){ try{$h.Close()}catch{} }
  Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
}

# ---- BgEvidenceEq exact compare (feeds the generation counter, G4) ----
$a = @([pscustomobject]@{kind='shell';id='x';label='foo'})
$b = @([pscustomobject]@{kind='shell';id='x';label='foo'})
$cc = @([pscustomobject]@{kind='shell';id='x';label='bar'})
if(BgEvidenceEq $a $b){ Grn "BgEvidenceEq equal -> true" } else { Red "BgEvidenceEq equal broke" }
if(-not (BgEvidenceEq $a $cc)){ Grn "BgEvidenceEq diff label -> false" } else { Red "BgEvidenceEq missed a label change" }
if(-not (BgEvidenceEq $a @())){ Grn "BgEvidenceEq diff count -> false" } else { Red "BgEvidenceEq missed a count change" }

if($fail.Count){ Write-Host "`nGUARD FAILED: $($fail.Count) red"; exit 1 } else { Write-Host "`nGUARD PASS (bg-what S1)"; exit 0 }
