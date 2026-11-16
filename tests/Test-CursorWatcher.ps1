<#
    Rehearses the Cursor update watcher (Scripts\cursor-update-fix.ps1) with
    stand-ins, without touching the real Cursor:

      - a pretend updater (a copy of ping.exe named inno_updater.exe, in a
        folder shaped like Cursor's update-supervisor folder),
      - pretend leftover Cursor processes with no window,
      - a pretend Cursor.exe that just drops a marker file when started.

    Act 1: the updater is "waiting for Cursor to close" while leftovers linger.
           Expect: the watcher closes the leftovers.
    Act 2: the updater log then says the update succeeded and nothing reopens.
           Expect: the watcher starts "Cursor".

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File Test-CursorWatcher.ps1
#>
param([string]$Watcher = 'C:\Users\yeet\Scripts\cursor-update-fix.ps1')

$root = Join-Path $env:TEMP 'cursorwatch-test'
Get-Process FakeCursorApp, inno_updater -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\*" } | Stop-Process -Force
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
$supDir = Join-Path $root 'Cursor\update-supervisor\test'
$logDir = Join-Path $root 'temp'
New-Item -ItemType Directory -Force $supDir, $logDir | Out-Null
$ping = Join-Path $env:SystemRoot 'System32\ping.exe'
Copy-Item $ping (Join-Path $supDir 'inno_updater.exe')
Copy-Item $ping (Join-Path $root 'FakeCursorApp.exe')
Copy-Item $Watcher (Join-Path $root 'watcher.ps1')
$marker = Join-Path $root 'relaunched.txt'
Set-Content (Join-Path $root 'FakeCursor.cmd') "@echo started > `"$marker`"" -Encoding ascii

$bad = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  PASS  $what" } else { "  FAIL  $what"; $script:bad++ } }

# The leftovers have to be older than a few seconds before the watcher will touch them.
$left = 1..2 | ForEach-Object { Start-Process (Join-Path $root 'FakeCursorApp.exe') -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru }
Start-Sleep -Seconds 11

$log = Join-Path $logDir 'cursor-inno-updater-1.log'
Set-Content $log @(
    'Nov 15 23:00:00.000 INFO Starting: C:\fake\Cursor.exe, true, Updating Cursor...'
    'Nov 15 23:00:00.001 INFO Checking for running Cursor.exe processes... (attempt 1)'
    'Nov 15 23:00:00.002 INFO Cursor.exe is running, wait a bit'
)
$updater = Start-Process (Join-Path $supDir 'inno_updater.exe') -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
$watch = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $root 'watcher.ps1')),
    '-TempDir', ('"{0}"' -f $logDir), '-CursorExe', ('"{0}"' -f (Join-Path $root 'FakeCursor.cmd')),
    '-AppProcess', 'FakeCursorApp', '-CloseWaitSeconds', '3', '-RelaunchSeconds', '3', '-PollSeconds', '1')

'Act 1: updater waiting for Cursor to close, leftovers lingering'
$until = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $until -and @(Get-Process FakeCursorApp -ErrorAction SilentlyContinue).Count -gt 0) { Start-Sleep -Milliseconds 500 }
Check 'leftover processes were closed' (@(Get-Process FakeCursorApp -ErrorAction SilentlyContinue).Count -eq 0)
Check 'the updater itself was left running' (-not $updater.HasExited)
Check 'nothing was started yet' (-not (Test-Path $marker))

'Act 2: the update succeeds and nothing reopens Cursor'
Add-Content $log 'Nov 15 23:00:05.000 INFO Update was successful!'
$until = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $until -and -not (Test-Path $marker)) { Start-Sleep -Milliseconds 500 }
Check 'Cursor was started again' (Test-Path $marker)

'--- what the watcher wrote ---'
Get-Content (Join-Path $root 'cursor-update-fix.log') -ErrorAction SilentlyContinue
Stop-Process -Id $watch.Id, $updater.Id -Force -ErrorAction SilentlyContinue
Get-Process FakeCursorApp -ErrorAction SilentlyContinue | Stop-Process -Force
if ($bad -eq 0) { 'ALL CHECKS PASSED' } else { "$bad CHECK(S) FAILED" }
exit $bad
