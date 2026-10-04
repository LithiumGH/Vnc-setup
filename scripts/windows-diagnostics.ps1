<#
.SYNOPSIS
  Dump Windows VNC diagnostics after a run.

.DESCRIPTION
  Prints the TightVNC service state, the listening ports, and the tails of the
  pip, websockify and cloudflared logs, so a failure can be read from the job
  summary rather than guessed at.

.ENVIRONMENT
  WINVNC_WORK  the work directory the server script used
#>
$ErrorActionPreference = 'Continue'

Write-Host "--- tvnserver ---"
Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue |
  Format-List Name, Status, StartType | Out-String | Write-Host
Write-Host "--- listening ports ---"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in @(5900, 6080) } |
  Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table | Out-String | Write-Host
$w = "$env:WINVNC_WORK"
foreach ($f in @("pip.log", "cloudflared.log", "cf.err", "websockify.log", "websockify.err")) {
  if (Test-Path "$w\$f") {
    Write-Host "--- $f ---"
    Get-Content "$w\$f" -Tail 25 | Write-Host
  }
}

