# Toggle the resident Claude spark desktop pet on/off, and remember the choice in pet-state.txt.
# Invoked by the /my-pet slash command.
$ErrorActionPreference = 'SilentlyContinue'
$code  = $PSScriptRoot
$dir   = Join-Path $env:USERPROFILE '.claude\pet-data'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$pf    = Join-Path $dir 'pet.pid'
$state = Join-Path $dir 'pet-state.txt'

$running = $false
$id = $null
if (Test-Path $pf) {
  $id = Get-Content $pf | Select-Object -First 1
  if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) { $running = $true }
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
