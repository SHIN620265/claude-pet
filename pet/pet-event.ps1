# Hook -> pet per-session state bridge (run under pwsh, UTF-8 safe).
# Each Claude Code session (session_id) gets its own file under sessions\<id>:
#   key<TAB>label<TAB>title<TAB>detail<TAB>epochMillis<TAB>model<TAB>claudePid
# The resident renders one card per live session.
# Event: prompt | attention | permreq | busy | done | idle | end | answered
param([string]$Event = 'done')
$ErrorActionPreference = 'SilentlyContinue'
$dir = Join-Path $env:USERPROFILE '.claude\pet-data'
$sessDir = Join-Path $dir 'sessions'
if (-not (Test-Path $sessDir)) { New-Item -ItemType Directory -Path $sessDir | Out-Null }
$collapse = Join-Path $dir 'collapsed.flag'

# read stdin as UTF-8 (Claude pipes UTF-8 JSON; [Console]::In would use the GBK code page)
$raw = ''
try {
  $sr = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
  $raw = $sr.ReadToEnd(); $sr.Dispose()
} catch {}
$j = $null; try { $j = $raw | ConvertFrom-Json } catch {}

$sid = 'default'; if ($j -and $j.session_id) { $sid = [string]$j.session_id }
$sid = ($sid -replace '[^A-Za-z0-9_\-]', '_')
$cwd = ''; if ($j) { $cwd = [string]$j.cwd }
$proj = ''; if ($cwd) { $proj = Split-Path $cwd -Leaf }
$file = Join-Path $sessDir $sid

# claude PID (our parent; hooks are exec'd directly by claude.exe) -- stored as field 7
# so the resident can jump to this session's host window when its card row is clicked
$cpid = 0
try { $cpid = [int](Get-Process -Id $PID -ErrorAction Stop).Parent.Id } catch {}
if ($cpid -le 0) { try { $cpid = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch {} }

function RU($p) { if (Test-Path $p) { try { return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } catch {} } return '' }
function ExistingTitle { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 3) { return $p[2] } } return '' }
function ExistingDetail { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 4) { return $p[3] } } return '' }
function ExistingModel { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 6) { return $p[5] } } return '' }
function ExistingPid { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 7) { return $p[6] } } return '' }
function ExistingFp  { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 8) { return $p[7] } } return '' }
function ExistingTp  { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 9) { return $p[8] } } return '' }
function ExistingCwd { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 10) { return $p[9] } } return '' }

# scrub every control char (incl. TAB/CR/LF/ESC/BEL) so a value can never corrupt the
# single-line TAB-separated record; cap length so a pathological title can't bloat it
function CleanRec($s) {
  if (-not $s) { return '' }
  $s = [string]$s -replace '[\x00-\x1F\x7F]', ' '
  if ($s.Length -gt 200) { $s = $s.Substring(0, 200) }
  return $s
}
# This session's WT tab Name == its console title. Hooks run as children of claude.exe
# and share its console, so [Console]::Title reads the tab title directly -- no P/Invoke,
# no Add-Type, the common path. Fallback for a hook spawned without an inherited console:
# attach to claude's console explicitly (kernel32 lazily compiled so the fast path never
# pays the ~400ms). Best-effort: an empty result just keeps the previous fingerprint.
function Get-HostTitle {
  $t = ''; try { $t = [string][Console]::Title } catch {}
  if ($t) { return $t }
  if ($cpid -le 0) { return '' }
  try {
    if (-not ('PetCon.K' -as [type])) {
      Add-Type -Namespace PetCon -Name K -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool FreeConsole();
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetConsoleTitle(System.Text.StringBuilder sb, int n);
'@
    }
    [void][PetCon.K]::FreeConsole()
    if ([PetCon.K]::AttachConsole([uint32]$cpid)) {
      $sb = New-Object System.Text.StringBuilder 512
      [void][PetCon.K]::GetConsoleTitle($sb, 512)
      $t = $sb.ToString()
    }
    [void][PetCon.K]::FreeConsole()
  } catch {}
  return $t
}

# model shown on the card = the model of this session's LAST reply, parsed from the
# transcript tail. Honest per-session semantics: never claims "current model" (hooks
# don't expose one), so multiple sessions on different models each show their own;
# after /model the badge catches up with the next assistant message. The resident
# renders the badge only for post-turn states (done/idle) -- mid-turn it would read
# as "the model currently thinking", which nothing can truthfully claim.
function ModelShortName($id) {
  $m = [regex]::Match([string]$id, 'claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?!\d)')   # (?!\d) keeps date suffixes out
  if (-not $m.Success) { return '' }
  $fam = $m.Groups[1].Value; $fam = $fam.Substring(0,1).ToUpper() + $fam.Substring(1)
  $v = $m.Groups[2].Value; if ($m.Groups[3].Success) { $v = "$v.$($m.Groups[3].Value)" }
  return "$fam $v"
}
function ReadTranscriptTail($tp) {
  if (-not $tp -or -not (Test-Path $tp)) { return $null }
  try {
    $fs = [IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
    $flen = $fs.Length
    $take = [Math]::Min($flen, 262144)
    if ($take -le 0) { $fs.Dispose(); return $null }
    [void]$fs.Seek(-$take, 'End')
    $buf = New-Object byte[] $take; [void]$fs.Read($buf, 0, $take); $fs.Dispose()
    return @{ text = [Text.Encoding]::UTF8.GetString($buf); windowed = ($take -lt $flen) }
  } catch { return $null }
}
function ModelFromTranscript($tp) {
  $tail = ReadTranscriptTail $tp
  if (-not $tail) { return '' }
  $ms = [regex]::Matches($tail.text, '"model"\s*:\s*"([^"]*claude-[a-z0-9.-]+)"')   # anchored to the JSON field, not free text
  if ($ms.Count -eq 0) { return '' }
  return ModelShortName $ms[$ms.Count - 1].Groups[1].Value
}
# The done card shows the reply's first line + the model of the SAME assistant entry,
# so the badge always labels the text it actually produced. Skips sidechain (subagent)
# entries and tool_use-only entries; returns $null when nothing usable is in the tail.
function LastReplyFromTranscript($tp) {
  $tail = ReadTranscriptTail $tp
  if (-not $tail) { return $null }
  $lines = $tail.text -split "`n"
  $start = $(if ($tail.windowed) { 1 } else { 0 })   # windowed read: first line may be cut mid-JSON
  for ($i = $lines.Count - 1; $i -ge $start; $i--) {
    $ln = $lines[$i]
    if ($ln -notmatch '"type"\s*:\s*"assistant"') { continue }
    if ($ln -match '"isSidechain"\s*:\s*true') { continue }
    $o = $null; try { $o = $ln | ConvertFrom-Json } catch { continue }
    if (-not $o -or -not $o.message -or -not $o.message.content) { continue }
    $tb = @($o.message.content) | Where-Object { $_.type -eq 'text' -and $_.text } | Select-Object -First 1
    if (-not $tb) { continue }
    $line = ''
    foreach ($cand in ($tb.text -split "`n")) {
      if ($cand -match '^\s*#') { continue }   # headings label sections, they are not the lede
      $t = ($cand -replace '\s+', ' ').Trim()
      $t = ($t -replace '^(?:>\s*|[-*]\s+|\d+\.\s+)+', '') -replace '[`*]+', ''   # shed markdown lead-ins/emphasis
      $t = $t.Trim()
      if ($t) { $line = $t; break }
    }
    if (-not $line) { continue }
    if ($line.Length -gt 60) { $line = $line.Substring(0, 60) + [char]0x2026 }
    return @{ text = $line; model = (ModelShortName ([string]$o.message.model)) }
  }
  return $null
}
$tp = ''; if ($j) { $tp = [string]$j.transcript_path }
$mdl = ModelFromTranscript $tp
if (-not $mdl) { $mdl = ExistingModel }   # events without transcript_path keep the badge

function WriteSession($key, $label, $title, $detail, $model) {
  if (-not $model) { $model = $mdl }
  $cp = "$cpid"; if ($cpid -le 0) { $cp = ExistingPid }   # one flaky capture must not wipe a good pid
  # field 8 = WT tab fingerprint (this session's console/tab title, for tab-level jump);
  # a flaky/empty read keeps the old value so it is never wiped
  $fp = CleanRec (Get-HostTitle); if (-not $fp) { $fp = ExistingFp }
  # field 9 = transcript path (the resident tails it to catch Esc-interrupts, which fire
  # no Stop hook); events without a transcript_path keep the old value
  $tpF = CleanRec $tp; if (-not $tpF) { $tpF = ExistingTp }
  # field 10 = this session's cwd (workspace hint: disambiguates which VS Code window to
  # jump to, since all windows share one Code.exe and MainWindowHandle can't tell them apart)
  $cwdF = CleanRec $cwd; if (-not $cwdF) { $cwdF = ExistingCwd }
  $epoch = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $rec = ($key, $label, $title, $detail, "$epoch", $model, $cp, $fp, $tpF, $cwdF) -join "`t"
  [IO.File]::WriteAllText($file, $rec, (New-Object Text.UTF8Encoding($false)))
}
$projOr = $proj   # may be empty; the resident localizes an empty title to "new session"
function TitleOr { $t = ExistingTitle; if ($t) { return $t } else { return $projOr } }

# approved-command watch sidecar (sessions\<id>.pending): armed by permreq, consumed by
# the resident (see MAINTAINERS). Any event other than the two attention writers means
# the dialog is no longer pending -> disarm so a stale snippet can never match later.
$pend = "$file.pending"
if ($Event -ne 'permreq' -and $Event -ne 'attention') { Remove-Item $pend -Force -ErrorAction SilentlyContinue }

switch ($Event) {
  'prompt' {
    $pRaw = ''; if ($j) { $pRaw = [string]$j.prompt }
    # take the first meaningful line; skip leading file-reference / path lines like  & 'C:\...png'
    $clean = ''
    foreach ($ln in ($pRaw -split "`n")) {
      $t = ($ln -replace '\s+', ' ').Trim()
      if (-not $t) { continue }
      if ($t -match "^&?\s*['""].*['""]$") { continue }   # a quoted path (optionally & prefixed)
      if ($t -match '^[A-Za-z]:\\') { continue }           # a bare Windows path
      $clean = $t; break
    }
    if (-not $clean) { $clean = ($pRaw -replace '\s+', ' ').Trim() }
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60) + [char]0x2026 }
    if (Test-Path "$file.titlelock") {
      # user manually renamed this card -> keep their title
      $title = ExistingTitle; if (-not $title) { $title = $projOr }
    } else {
      # keep the FIRST real prompt as a stable title; but self-heal a stale path-like title
      $existing = ExistingTitle
      $bad = ($existing -match '[A-Za-z]:\\') -or ($existing -match '(?i)Screenshots')
      if ($existing -and $existing -ne $projOr -and -not $bad) { $title = $existing }
      elseif ($clean) { $title = $clean }
      else { $title = $projOr }
    }
    Remove-Item $collapse -Force -ErrorAction SilentlyContinue
    WriteSession 'thinking' '正在思考' $title $clean
  }
  'attention' {
    $msg = ''; if ($j) { $msg = [string]$j.message }
    $ntype = ''; if ($j) { foreach ($k in 'type','notification_type','notificationType') { if ($j.$k) { $ntype = [string]$j.$k; break } } }
    $log = Join-Path $dir 'events.log'
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt 262144)) { Remove-Item $log -Force -ErrorAction SilentlyContinue }   # debug log: cap at 256KB
    try { Add-Content $log -Value ('{0}  {1}  type={2}  msg={3}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $Event, $ntype, $msg) -Encoding UTF8 } catch {}
    $cleared = ($ntype -match '(?i)elicitation_(complete|response)')   # user answered -> drop attention
    $ignore = ($msg -match '(?i)waiting for') -or ($ntype -eq 'idle_prompt') -or ($ntype -eq 'auth_success')
    if ($cleared) {
      $cur = RU $file; $k0 = ''; if ($cur) { $k0 = ($cur -split "`t")[0] }
      if ($k0 -eq 'attention') { Remove-Item $pend -Force -ErrorAction SilentlyContinue; WriteSession 'thinking' '正在思考' (TitleOr) (ExistingDetail) }
      return
    }
    if ($ignore) { return }
    Remove-Item $collapse -Force -ErrorAction SilentlyContinue
    WriteSession 'attention' '需要你确认 / 选择' (TitleOr) (ExistingDetail)
  }
  'permreq' {
    # PermissionRequest hook: fires the moment a permission dialog is shown -- ~6s earlier
    # than the Notification path (Claude Code delays that one by design, ZTc=6000ms).
    # The later Notification rewrites the same key, which is idempotent (no second chime).
    Remove-Item $collapse -Force -ErrorAction SilentlyContinue
    WriteSession 'attention' '需要你确认 / 选择' (TitleOr) (ExistingDetail)
    # Arm the approved-command watch: the platform emits nothing between "user approved"
    # and "tool finished", but for command-shaped tools the approval's direct consequence
    # IS observable -- that very command appears as a child process of this claude.exe.
    # Store the normalized command + the claude PID (our parent; hooks are exec'd directly)
    # so the resident can flip attention->thinking on proof, never on a guess. Commands
    # too short to be unambiguous, or tools without a command, stay unarmed (= today's
    # behavior: the card recovers when the tool finishes). This hook is async -- the CIM
    # parent lookup does not delay the dialog.
    $cmd = ''
    if ($j -and $j.tool_input) { foreach ($k in 'command','script') { if ($j.tool_input.$k) { $cmd = [string]$j.tool_input.$k; break } } }
    $normCmd = $cmd -replace '[\s\\"''`]+', ''   # keep in sync with pet-resident.ps1
    if ($normCmd.Length -ge 6) {
      if ($cpid -gt 0) {   # captured once at the top (with CIM fallback), reused here
        if ($normCmd.Length -gt 200) { $normCmd = $normCmd.Substring(0, 200) }
        $armEpoch = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        [IO.File]::WriteAllText($pend, (("$cpid", "$armEpoch", $normCmd) -join "`t"), (New-Object Text.UTF8Encoding($false)))
      }
    }
    # debug trail (tool name + armed flag only -- the command text itself is never logged)
    $log = Join-Path $dir 'events.log'
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt 262144)) { Remove-Item $log -Force -ErrorAction SilentlyContinue }
    $tn = ''; if ($j) { $tn = [string]$j.tool_name }
    try { Add-Content $log -Value ('{0}  permreq  tool={1}  armed={2}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $tn, $(if (Test-Path $pend) { 1 } else { 0 })) -Encoding UTF8 } catch {}
  }
  'answered' {
    # ElicitationResult hook: the user just answered an elicitation (question dialog).
    # If the card still says attention it is stale by definition -> back to thinking.
    # ($pend was already disarmed by the top-of-switch cleanup.)
    $cur = RU $file; $k0 = ''; if ($cur) { $k0 = ($cur -split "`t")[0] }
    if ($k0 -eq 'attention') { WriteSession 'thinking' '正在思考' (TitleOr) (ExistingDetail) }
  }
  'done' {
    # turn is over -> swap "your words" for the reply's first line, badge from the same
    # entry; on extraction failure fall back to the v1.0.6 behavior (no regression)
    $r = LastReplyFromTranscript $tp
    if ($r -and $r.text) { WriteSession 'done' '已完成' (TitleOr) $r.text $r.model }
    else { WriteSession 'done' '已完成' (TitleOr) (ExistingDetail) }
  }
  'busy' {
    # a tool ran (e.g. right after you approved) -> back to thinking, keep the title
    $cur = RU $file; $k = ''; if ($cur) { $k = ($cur -split "`t")[0] }
    if ($k -ne 'thinking') { WriteSession 'thinking' '正在思考' (TitleOr) (ExistingDetail) }
  }
  'idle' {
    WriteSession 'idle' '空闲' (TitleOr) (ExistingDetail)
  }
  'end' {
    # clean exit: hide the card NOW (aged epoch rides the resident's display TTL) but keep
    # the memory -- first-prompt title and rename must survive a later `claude --resume`;
    # the resident's 7-day storage TTL does the eventual purge of truly dead sessions
    $c = RU $file
    if ($c) {
      $p = $c -split "`t"; while ($p.Count -lt 6) { $p += '' }
      $p[0] = 'idle'
      $p[4] = "$([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) - 1860000)"
      [IO.File]::WriteAllText($file, ($p -join "`t"), (New-Object Text.UTF8Encoding($false)))
    }
    Remove-Item "$file.dismiss" -Force -ErrorAction SilentlyContinue
  }
}
