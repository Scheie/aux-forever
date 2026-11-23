# auxForever price history sync, Windows: runs sync.lua whenever a game saves auxForever.lua.
# Started at logon by the "auxForever sync" scheduled task (install-windows.ps1); runs hidden.
param(
    [Parameter(Mandatory = $true)][string]$Accounts, # <WoW>\_forever_\WTF\Account
    [Parameter(Mandatory = $true)][string]$Lua,      # lua.exe, 5.3 or newer
    [string]$Script = (Join-Path $PSScriptRoot 'sync.lua')
)

function Invoke-Sync {
    & $Lua $Script $Accounts
}

# one watcher for every account: WoW writes <account>\SavedVariables\auxForever.lua (it renames the
# old one to .bak and writes a new one, so creations and renames count as well as changes)
$watcher = New-Object System.IO.FileSystemWatcher $Accounts, 'auxForever.lua'
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'

Invoke-Sync # catch up with saves made while this was not running
while ($true) {
    $change = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 60000)
    if (-not $change.TimedOut) {
        # a save comes as several events: wait until they stop, then sync once (sync.lua waits
        # for the files to settle too, and ignores its own writes)
        do {
            $more = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 5000)
        } while (-not $more.TimedOut)
        Invoke-Sync
    }
}
