# Makes "Restart to Update" in Cursor always end with the new Cursor open.
#
# Cursor's updater (inno_updater.exe) does three things after you click the
# button: waits for every Cursor process to exit, swaps the program files, and
# (through a second copy of itself, the "supervisor") starts Cursor again. On
# this PC each of those can stall. This script watches for an update in
# progress and gives it a push where it sticks:
#
#  1. Cursor does not fully close. Background Cursor processes with no window
#     are left running, and the updater waits on them. Once the updater has
#     been waiting a while and no Cursor window is open, those leftovers are
#     closed so the update can go ahead.
#  2. The "Updating Cursor..." window freezes after the update has finished.
#     It is closed once the updater's log says the update succeeded.
#  3. The update finishes but Cursor is not started again (Cursor 3.29+ updates
#     silently and leaves the restart to the supervisor, which often does not
#     do it). Cursor is started.
#  4. The update fails. Cursor is started again on the version it has.
#
# "Cursor is open" means a Cursor window exists. Leftover background processes
# do not count; they used to make this script think Cursor was already back.
#
# A plain quit (no restart asked for) is left alone: Cursor only arms the
# supervisor when you click "Restart to Update".
#
# Lives in Scripts rather than AppData on purpose: files the Claude desktop app
# writes under AppData land in its private package folder, where the Startup
# shortcut cannot find them. Started at sign-in by CursorUpdateFix.lnk.
param(
    [string]$TempDir = $env:TEMP,
    [string]$CursorExe = (Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe'),
    [string]$AppProcess = 'Cursor',               # process name of the app (the tests use a stand-in)
    [string]$UpdaterProcess = 'inno_updater',
    [int]$CloseWaitSeconds = 20,      # how long the updater may wait for Cursor to close before leftovers are closed
    [int]$FrozenWindowSeconds = 20,   # how long a finished updater window may stay up
    [int]$RelaunchSeconds = 8,        # how long Cursor gets to come back by itself after an update
    [int]$MaxLogAgeMinutes = 10,      # ignore old updates (a supervisor left over from an earlier day)
    [int]$PollSeconds = 2,
    [switch]$Once
)

$ErrorActionPreference = 'SilentlyContinue'
$logFile = Join-Path $PSScriptRoot 'cursor-update-fix.log'

function Write-Log([string]$Message) {
    Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
}

# Keep the log from growing without limit.
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 200KB) {
    $keep = Get-Content $logFile -Tail 400
    Set-Content -Path $logFile -Value $keep
}

function Get-Updaters {
    @(Get-Process $UpdaterProcess | Where-Object {
        $_.Path -like '*\Programs\cursor\tools\*' -or $_.Path -like '*\Cursor\update-supervisor\*'
    })
}

function Get-AppProcesses { @(Get-Process $AppProcess) }
function Test-AppWindowOpen { @(Get-AppProcesses | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0 }

# The newest updater log written since this update began.
function Get-UpdaterLog([datetime]$Since) {
    Get-ChildItem $TempDir -Filter 'cursor-inno-updater-*.log' |
        Where-Object { $_.LastWriteTime -ge $Since.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Close-Leftovers([string]$Why, [datetime]$OlderThan) {
    $left = @(Get-AppProcesses | Where-Object { $_.MainWindowHandle -eq 0 -and $_.StartTime -lt $OlderThan })
    if ($left.Count -eq 0) { return 0 }
    Write-Log "$Why; closing $($left.Count) leftover $AppProcess process(es) that have no window."
    $left | Stop-Process -Force
    return $left.Count
}

function Start-App([string]$Why) {
    if (Test-AppWindowOpen) { return }
    Write-Log "$Why; starting Cursor."
    Start-Process $CursorExe
}

Write-Log "Watcher started (pid $PID)."
$update = $null      # what is known about the update in progress
do {
    $updaters = Get-Updaters
    if ($updaters.Count -eq 0) {
        if ($update -and -not $update.Finished) { Write-Log 'The updater exited.' }
        $update = $null
    } else {
        if (-not $update) {
            $began = ($updaters | Sort-Object StartTime | Select-Object -First 1).StartTime
            $update = @{ Began = $began; Seen = Get-Date; Restart = $false; Pushed = $false; Finished = $false; Announced = $false }
        }
        # Cursor only arms the supervisor when a restart was asked for.
        if (@($updaters | Where-Object { $_.Path -like '*\Cursor\update-supervisor\*' }).Count -gt 0) { $update.Restart = $true }

        $log   = Get-UpdaterLog $update.Began
        # An update whose last sign of life is long ago is a supervisor left over from an earlier day.
        $lastSign = $update.Began
        if ($log) { $lastSign = $log.LastWriteTime }
        $stale = ((Get-Date) - $lastSign).TotalMinutes -gt $MaxLogAgeMinutes
        $tail  = ''
        $first = ''
        if ($log) { $tail = [string](Get-Content $log.FullName -Tail 1); $first = [string](Get-Content $log.FullName -TotalCount 1) }
        $silent  = $first -match ', true, '
        $visible = @($updaters | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0
        if ($visible -or ($log -and -not $silent)) { $update.Restart = $true }      # a visible update is always a restart
        $quietFor = 0
        if ($log) { $quietFor = ((Get-Date) - $log.LastWriteTime).TotalSeconds }
        $running  = ((Get-Date) - $update.Seen).TotalSeconds

        if (-not $update.Announced -and $log) {
            $kind = 'visible'; if ($silent) { $kind = 'silent' }
            Write-Log "Update in progress ($kind, restart asked for: $($update.Restart)); updater log $($log.Name)."
            $update.Announced = $true
        }

        if ($stale -or $update.Finished) {
            # nothing more to do for this one
        }
        elseif ($tail -match 'Update was successful') {
            if ($update.Restart) {
                # A window that stays up after the work is done is the frozen "Updating Cursor..." window.
                $frozen = @($updaters | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -like '*\Programs\cursor\tools\*' })
                if ($frozen.Count -gt 0 -and $quietFor -ge $FrozenWindowSeconds) {
                    Write-Log "The updater window is still up $([int]$quietFor)s after a successful update; closing it."
                    $frozen | Stop-Process -Force
                }
                if ($quietFor -ge $RelaunchSeconds -and -not (Test-AppWindowOpen)) {
                    # Anything older than the update is not the new Cursor.
                    [void](Close-Leftovers 'Update finished' $log.LastWriteTime)
                    Start-App "Update finished $([int]$quietFor)s ago and Cursor was not started again"
                    $update.Finished = $true
                } elseif (Test-AppWindowOpen) {
                    Write-Log 'Update finished and Cursor is open again.'
                    $update.Finished = $true
                }
            } else {
                $update.Finished = $true        # plain quit: the user closed Cursor on purpose
            }
        }
        elseif ($tail -match 'Failed to install Cursor update|promotion_failed|rollback') {
            Write-Log "The update failed: $tail"
            if ($update.Restart) { Start-App 'The update failed' }
            $update.Finished = $true
        }
        elseif (-not $update.Pushed -and $running -ge $CloseWaitSeconds -and -not (Test-AppWindowOpen) -and
                ((-not $log) -or $tail -match 'is running, wait a bit|Checking for running|Gave up waiting|attempting to kill|Failed to kill|still executing')) {
            # The updater is waiting for Cursor to exit, and what is left of Cursor has no window.
            # (Only processes more than a few seconds old: a Cursor that is just starting has no window yet either.)
            $closed = Close-Leftovers "The updater has waited $([int]$running)s for Cursor to close" (Get-Date).AddSeconds(-10)
            if ($closed -gt 0) { $update.Pushed = $true }
        }
    }
    if (-not $Once) { Start-Sleep -Seconds $PollSeconds }
} while (-not $Once)
