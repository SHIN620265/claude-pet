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

# Register this window's card WITHOUT clobbering an ongoing session's real title/state.
#   clear   -> conversation reset: fresh idle card + drop the rename lock
#   new sid -> idle placeholder card
#   resume / compact / re-register of an existing session -> leave its card untouched
$epoch = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$idleRec = (('idle', '空闲', $projOr, '', "$epoch") -join "`t")
if ($src -eq 'clear') {
  Remove-Item "$file.titlelock" -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText($file, $idleRec, (New-Object Text.UTF8Encoding($false)))
} elseif (-not (Test-Path $file)) {
  [IO.File]::WriteAllText($file, $idleRec, (New-Object Text.UTF8Encoding($false)))
}
Remove-Item (Join-Path $dir 'collapsed.flag') -Force -ErrorAction SilentlyContinue

$statePath = Join-Path $dir 'pet-state.txt'
$state = (Get-Content $statePath -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $state) { $state = 'on'; Set-Content -Path $statePath -Value 'on' -Encoding ascii }   # first run -> default on
if ($state -eq 'on') {
  $running = $false
  if (Test-Path $pf) {
    $id = Get-Content $pf | Select-Object -First 1
    if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) { $running = $true }
  }
  if (-not $running) {
    Remove-Item $pf -Force -ErrorAction SilentlyContinue
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $code 'pet-resident.ps1')
    )
    if ($p) { $p.Id | Set-Content $pf }
  }
}
