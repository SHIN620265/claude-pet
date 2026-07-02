# Toggle the resident Claude spark desktop pet on/off, and remember the choice in pet-state.txt.
# Invoked by the /my-pet slash command.
$ErrorActionPreference = 'SilentlyContinue'
$code  = $PSScriptRoot
$dir   = Join-Path $env:USERPROFILE '.claude\pet-data'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$pf    = Join-Path $dir 'pet.pid'
$state = Join-Path $dir 'pet-state.txt'

# verify the recorded PID really is the pet before trusting (or killing) it:
# after a crash/reboot the PID can be reused by an unrelated process, and a blind
# Stop-Process would kill that innocent process
function Test-PetProcess([int]$procId) {
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $p -or $p.ProcessName -ne 'powershell') { return $false }
  $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
  return [bool]($ci -and $ci.CommandLine -match 'pet-resident\.ps1')
}

$running = $false
$id = $null
if (Test-Path $pf) {
  $id = Get-Content $pf | Select-Object -First 1
  if ($id -match '^\d+$' -and (Test-PetProcess ([int]$id))) { $running = $true }
}

if ($running) {
  Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
  Remove-Item $pf -Force -ErrorAction SilentlyContinue
  Set-Content -Path $state -Value 'off'
  'off'
} else {
  Remove-Item $pf -Force -ErrorAction SilentlyContinue
  $res = Join-Path $code 'pet-resident.ps1'
  $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File', $res
  )
  if ($p) { $p.Id | Set-Content $pf }
  Set-Content -Path $state -Value 'on'
  'on'
}
