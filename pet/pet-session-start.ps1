# SessionStart: register this Claude Code window as its own session card (idle),
# re-show the reminder, and launch the pet if its last remembered state was 'on'.
# Invoked via `pwsh -File` so the hook JSON (session_id) is available on stdin.
$ErrorActionPreference = 'SilentlyContinue'
$code = $PSScriptRoot
$dir = Join-Path $env:USERPROFILE '.claude\pet-data'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$sessDir = Join-Path $dir 'sessions'
if (-not (Test-Path $sessDir)) { New-Item -ItemType Directory -Path $sessDir | Out-Null }
$pf = Join-Path $dir 'pet.pid'

# verify the recorded PID really is the pet (PID reuse after crash/reboot would
# otherwise make us think it is still running and never relaunch it)
function Test-PetProcess([int]$procId) {
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $p -or $p.ProcessName -ne 'powershell') { return $false }
  $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
  return [bool]($ci -and $ci.CommandLine -match 'pet-resident\.ps1')
}

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
$projOr = $proj   # may be empty; the resident localizes an empty title to "new session"
$src = ''; if ($j) { $src = [string]$j.source }   # startup | resume | clear | compact
$file = Join-Path $sessDir $sid

# claude PID (our parent; hooks are exec'd directly by claude.exe) -- session record
# field 7, the click-to-jump target. Captured on every SessionStart so a resumed
# session's card follows it into the new claude.exe window.
$cpid = 0
try { $cpid = [int](Get-Process -Id $PID -ErrorAction Stop).Parent.Id } catch {}
if ($cpid -le 0) { try { $cpid = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch {} }

# session record field 8 = WT tab fingerprint (this session's console/tab title, for
# tab-level jump), field 9 = transcript path (interrupt detection). Both best-effort at
# SessionStart and self-heal on the next real event; see pet-event.ps1 for the rationale.
$tp = ''; if ($j) { $tp = [string]$j.transcript_path }
function CleanRec($s) {
  if (-not $s) { return '' }
  $s = [string]$s -replace '[\x00-\x1F\x7F]', ' '
  if ($s.Length -gt 200) { $s = $s.Substring(0, 200) }
  return $s
}
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
$fp = CleanRec (Get-HostTitle)
$tpF = CleanRec $tp
$cwdF = CleanRec $cwd   # field 10: workspace hint for VS Code multi-window jump

# Register this window's card WITHOUT clobbering an ongoing session's real title/state.
#   clear   -> conversation reset: fresh idle card + drop the rename lock
#   new sid -> idle placeholder card
#   resume / compact / re-register of an existing session -> leave its card untouched
$epoch = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$idleRec = (('idle', '空闲', $projOr, '', "$epoch", '', "$cpid", $fp, $tpF, $cwdF) -join "`t")
if ($src -eq 'clear') {
  Remove-Item "$file.titlelock", "$file.pending" -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText($file, $idleRec, (New-Object Text.UTF8Encoding($false)))
} elseif (-not (Test-Path $file)) {
  [IO.File]::WriteAllText($file, $idleRec, (New-Object Text.UTF8Encoding($false)))
} elseif ($cpid -gt 0) {
  # resume / compact / re-register: the card itself stays untouched (title, state and
  # epoch are the session's memory -- see MAINTAINERS pitfall 8), but the claude PID
  # (field 7) must follow the session into its new claude.exe; field 8 (tab fingerprint)
  # and field 9 (transcript path) are refreshed too so tab-jump and the interrupt watch
  # track the resumed window. This also back-fills records written before these fields.
  try {
    $c = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    if ($c) {
      $p = $c -split "`t"; while ($p.Count -lt 10) { $p += '' }
      $dirty = $false
      if ($p[6] -ne "$cpid") { $p[6] = "$cpid"; $dirty = $true }
      if ($fp -and $p[7] -ne $fp) { $p[7] = $fp; $dirty = $true }      # never wipe a good fingerprint with an empty read
      if ($tpF -and $p[8] -ne $tpF) { $p[8] = $tpF; $dirty = $true }
      if ($cwdF -and $p[9] -ne $cwdF) { $p[9] = $cwdF; $dirty = $true }
      if ($dirty) { [IO.File]::WriteAllText($file, ($p -join "`t"), (New-Object Text.UTF8Encoding($false))) }
    }
  } catch {}
}
Remove-Item (Join-Path $dir 'collapsed.flag') -Force -ErrorAction SilentlyContinue

$statePath = Join-Path $dir 'pet-state.txt'
$state = (Get-Content $statePath -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $state) { $state = 'on'; Set-Content -Path $statePath -Value 'on' -Encoding ascii }   # first run -> default on
if ($state -eq 'on') {
  $running = $false
  if (Test-Path $pf) {
    $id = Get-Content $pf | Select-Object -First 1
    if ($id -match '^\d+$' -and (Test-PetProcess ([int]$id))) { $running = $true }
  }
  if (-not $running) {
    Remove-Item $pf -Force -ErrorAction SilentlyContinue
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $code 'pet-resident.ps1')
    )
    if ($p) { $p.Id | Set-Content $pf }
  }
}
