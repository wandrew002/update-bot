# Windows update bot

Verified on wandrew002's Windows 11 PC with Windows PowerShell 5.1 on November 16, 2026. This is a portable source snapshot; review app choices and paths before installing elsewhere.

## Contents and behavior

- `Update-AllApps.ps1`: discovers winget updates, runs independent installers concurrently (MSI installers share a serial lane), and retries installer-lock conflicts. Steam, NVIDIA, Defender/Windows Update, and VS Code extensions run alongside. Also checks Store apps, npm globals, Python packages, and vendor updaters. Windows updates require the IDs recorded in `UpdateBot/approved-windows-updates.json`; it never automatically reboots.
- `cursor-update-fix.ps1`: watches Cursor's update logs, closes windowless leftovers blocking an explicitly requested update, and reopens Cursor when the updater fails to do so. A normal quit stays closed.
- `mascot.json` (5,471,034 bytes) and `mascot.sixel.json` (3,887,245 bytes): the mascot frames, bundled so the bot works without Python. The Sixel image displays in compatible Windows Terminal; other terminals use text. Run startup moves a classic console into Terminal unless Terminal itself needs updating.

Logs, attention lists, version memos, local launchers, and installed-app inventories stay outside Git. There is no scheduled Claude routine. The main script can launch a local Claude handoff when items remain; `-NoClaude` disables that behavior. Steam updates are limited to Steam itself and Wallpaper Engine (appid 431960); other Steam titles are set to update when launched, with their previous settings recorded locally.

## Install on another PC

Prerequisites: Windows 11, PowerShell 5.1, working `winget`/App Installer, and optionally Windows Terminal with Sixel support. Optional app checks use installed Steam, NVIDIA tools, Node/npm, Python/pip, and VS Code. A signed-in interactive account is required for the tray apps. Do not schedule these as SYSTEM.


Copy this directory to a stable location such as `$env:USERPROFILE\Scripts`, keeping the mascot data beside the script. Review the app lists near the top of the script.

First run the tests below. Then, in an **administrator PowerShell** opened once by the user, register the weekly task (adjust `$botRoot` if needed):

```powershell
$botRoot = Join-Path $env:USERPROFILE 'Scripts'
$account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\Update-AllApps.ps1" -IncludeStore' -f $botRoot)
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '10:00'
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)
Register-ScheduledTask -TaskName 'Update All Apps' -Action $action -Trigger $trigger -Principal $principal -Settings $settings
# To run it now:
Start-ScheduledTask -TaskName 'Update All Apps'
```

Create Cursor's hidden sign-in launcher from normal PowerShell:

```powershell
$botRoot = Join-Path $env:USERPROFILE 'Scripts'
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'CursorUpdateFix.lnk'))
$shortcut.TargetPath = "$env:SystemRoot\System32\conhost.exe"
$shortcut.Arguments = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $botRoot 'cursor-update-fix.ps1') + '"'
$shortcut.WorkingDirectory = $botRoot
$shortcut.Save()
```

## Switches and output

Use `Get-Help .\Update-AllApps.ps1 -Full` for details. Public switches: `-DryRun`, `-IncludeStore`, `-SkipDevTools`, `-SkipSelfUpdaters`, `-SelfUpdatersOnly`, `-ReinstallNvidia`, `-NoClaude`, `-NoAnimation`, `-NoEmoji`, `-NoMascot`, `-NoRehost`, `-NoElevate`, `-MaxParallel <n>`, and `-Demo`. Internal process coordination uses `-RehostPidFile`, `-ChildStep` (Steam/Nvidia/Windows/CodeExt), and `-ChildOut`. Dry run skips installs but still checks sources and writes local status files. Demo animates fake progress.

The main run writes `UpdateBot/update-*.log`, `needs-attention.md/json`, `installed-versions.json`, and `no-change-versions.json`. No-change package releases are suppressed for 21 days. An installed version shorter than winget's advertised build suffix can denote the same release (MEGAsync 6.7.0 versus 6.7.0.3). Apps with unreadable versions get a program-file presence check; missing files trigger one forced reinstall, then an attention entry.


## Validation and limitations

Steam deferred Wallpaper Engine startup remains unproven because no patch was pending. The prior elevated run restored Iriun Webcam (1 updated, 0 failed).

From this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Scheduler.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CursorWatcher.ps1 -Watcher "$PWD\cursor-update-fix.ps1"
```

The scheduler test performs a real NVIDIA version lookup; other operations use fixtures.

Both must print `ALL CHECKS PASSED` and exit 0. These tests create isolated temporary fixtures. The Cursor test's default watcher path refers to the original PC, so pass `-Watcher` as shown elsewhere.



## Lessons

- PowerShell 5.1: use generic-list `.ToArray()` instead of `@($genericList)`; wrap format expressions passed to methods in parentheses, and test paths before removing optional files to avoid quiet-error noise.

- The user wants Riot software left alone, so the bot does not manage it.

- OBS cannot replace its virtual-camera DLL while Chrome or the Claude app has it loaded. Close the owning app for an update; never rename in-use DLLs to force installation.
- Iriun's installer once reported success while leaving its entire program directory missing. Validate actual files when a version cannot be read.
- The weekly bot already handles NVIDIA drivers. A separate daily elevated driver task would require one user-approved UAC setup; it was not created.

## Mascot regeneration

The bundled data works without Python. To regenerate the Sixel data, supply the original dance GIF (the PC source is `_work/mascot/zero-two-hd.gif`; source media is not included here), install Pillow and NumPy, and run:

```powershell
python -m pip install pillow numpy
python -I .\mascot\make-sixel.py .\zero-two-hd.gif .\mascot.sixel.json
```

`make-sixel.py` generates only the Sixel file. The text fallback `mascot.json` is supplied prebuilt; no text-fallback generator is included.

## Where this came from

This repository was split out of `projects/update-bot` in the private `wandrew002/agent-knowledge` notes repository on November 16, 2026. The running copy on the PC is in `C:\Users\yeet\Scripts`; this repository is the published source, so copy changes here after they are tested there.
