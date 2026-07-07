# WT tab-jump nonce helper (knife 2). Pure ASCII. Runs as its own short-lived process so
# the FreeConsole/AttachConsole console juggling is isolated from the long-lived resident.
# Attaches to the target session's console (shared with its Windows Terminal tab), stamps
# a unique nonce as the tab title so the resident can pick THAT tab out of same-named
# siblings, holds it, then conditionally restores. Args: shellPid nonce holdMs.
param([int]$ShellPid, [string]$Nonce, [int]$HoldMs = 2000)
$ErrorActionPreference = 'SilentlyContinue'
if ($ShellPid -le 0 -or -not $Nonce) { return }
try {
  Add-Type -Namespace PetN -Name Con -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool FreeConsole();
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern bool SetConsoleTitle(string t);
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetConsoleTitle(System.Text.StringBuilder sb, int n);
'@
} catch { return }
[void][PetN.Con]::FreeConsole()
if (-not [PetN.Con]::AttachConsole([uint32]$ShellPid)) { return }
# remember the current title to put back later; but if it is already a leftover nonce (a
# prior helper that never restored), refuse to treat it as the real title -- restoring it
# would write a stale nonce back (design G2, PETNONCE_ prefix guard)
$sb = New-Object System.Text.StringBuilder 512
[void][PetN.Con]::GetConsoleTitle($sb, 512)
$old = $sb.ToString()
if ($old -like 'PETNONCE_*') { $old = '' }
[void][PetN.Con]::SetConsoleTitle($Nonce)
Start-Sleep -Milliseconds $HoldMs
# conditional restore: only revert if the tab title is STILL our nonce. If the app
# legitimately re-titled in the meantime, respect that and leave it alone.
$sb2 = New-Object System.Text.StringBuilder 512
[void][PetN.Con]::GetConsoleTitle($sb2, 512)
if ($sb2.ToString() -eq $Nonce) { [void][PetN.Con]::SetConsoleTitle($old) }
[void][PetN.Con]::FreeConsole()
