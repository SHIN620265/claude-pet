# Hook -> pet per-session state bridge (run under pwsh, UTF-8 safe).
# Each Claude Code session (session_id) gets its own file under sessions\<id>:
#   key<TAB>label<TAB>title<TAB>detail<TAB>epochMillis
# The resident renders one card per live session. Event: prompt | attention | done | idle | end
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

function RU($p) { if (Test-Path $p) { try { return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } catch {} } return '' }
function ExistingTitle { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 3) { return $p[2] } } return '' }
function ExistingDetail { $c = RU $file; if ($c) { $p = $c -split "`t"; if ($p.Count -ge 4) { return $p[3] } } return '' }
function WriteSession($key, $label, $title, $detail) {
  $epoch = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $rec = ($key, $label, $title, $detail, "$epoch") -join "`t"
  [IO.File]::WriteAllText($file, $rec, (New-Object Text.UTF8Encoding($false)))
}
$projOr = $proj   # may be empty; the resident localizes an empty title to "new session"
function TitleOr { $t = ExistingTitle; if ($t) { return $t } else { return $projOr } }

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
    try { Add-Content (Join-Path $dir 'events.log') -Value ('{0}  {1}  type={2}  msg={3}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $Event, $ntype, $msg) -Encoding UTF8 } catch {}
    $cleared = ($ntype -match '(?i)elicitation_(complete|response)')   # user answered -> drop attention
    $ignore = ($msg -match '(?i)waiting for') -or ($ntype -eq 'idle_prompt') -or ($ntype -eq 'auth_success')
    if ($cleared) {
      $cur = RU $file; $k0 = ''; if ($cur) { $k0 = ($cur -split "`t")[0] }
      if ($k0 -eq 'attention') { WriteSession 'thinking' '正在思考' (TitleOr) (ExistingDetail) }
      return
    }
    if ($ignore) { return }
    Remove-Item $collapse -Force -ErrorAction SilentlyContinue
    WriteSession 'attention' '需要你确认 / 选择' (TitleOr) (ExistingDetail)
  }
  'done' {
    WriteSession 'done' '已完成' (TitleOr) (ExistingDetail)
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
    Remove-Item $file, "$file.dismiss", "$file.titlelock" -Force -ErrorAction SilentlyContinue
  }
}
