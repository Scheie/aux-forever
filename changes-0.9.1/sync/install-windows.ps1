# auxForever price history sync, Windows install. Run in PowerShell from this folder:
#   powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 [-WoW "<WoW>\_forever_"]
# Turn off:
#   Unregister-ScheduledTask -TaskName 'auxForever sync' -Confirm:$false
param(
    [string]$WoW = 'C:\Program Files (x86)\World of Warcraft\_forever_'
)
$ErrorActionPreference = 'Stop'

$accounts = Join-Path $WoW 'WTF\Account'
if (-not (Test-Path $accounts)) {
    throw "Not found: $accounts. Pass your WoW folder: -WoW '<path>\_forever_'"
}

# Lua 5.3 or newer (sync.lua uses math.type and load with an environment)
$lua = Get-Command lua, lua54, lua5.4, lua53, lua5.3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $lua) {
    throw 'Lua 5.3 or newer was not found. Install it (for example: winget install DEVCOM.Lua), open a new PowerShell, and run this again.'
}
$version = & $lua.Source -v 2>&1 | Out-String
if ($version -notmatch 'Lua 5\.[34]') {
    throw "Lua 5.3 or newer is needed; found: $version"
}

$dir = Join-Path $env:APPDATA 'auxForever-sync'
New-Item -ItemType Directory -Force (Join-Path $dir 'backups') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'sync.lua'), (Join-Path $PSScriptRoot 'watch.ps1') $dir -Force

$arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\watch.ps1`" -Accounts `"$accounts`" -Lua `"$($lua.Source)`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'auxForever sync' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'auxForever sync'

Write-Host "auxForever sync installed and running."
Write-Host "  accounts: $accounts"
Write-Host "  lua:      $($lua.Source)"
Write-Host "  files:    $dir (sync.log, backups)"
