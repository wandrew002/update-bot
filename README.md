# Windows update bot

Verified on wandrew002's Windows 11 PC with Windows PowerShell 5.1 on November 16, 2026. This is a portable source snapshot; review app choices and paths before installing elsewhere.

## Contents and behavior

- `Update-AllApps.ps1`: discovers winget updates, runs independent installers concurrently (MSI installers share a serial lane), and retries installer-lock conflicts. Steam, NVIDIA, Defender/Windows Update, and VS Code extensions run alongside. Also checks Store apps, npm globals, Python packages, vendor updaters, every installed Ollama model, and the G HUB background updater service when present. G HUB controls its own update timing; running its service does not prove an immediate check or installation. Windows updates require the IDs recorded in `UpdateBot/approved-windows-updates.json`; it never automatically reboots.
- `cursor-update-fix.ps1`: watches Cursor's update logs, closes windowless leftovers blocking an explicitly requested update, and reopens Cursor when the updater fails to do so. A normal quit stays closed.
- `mascot.json` (1,307,829 bytes) and `mascot.sixel.json` (3,887,245 bytes): the mascot frames, bundled so the bot works without Python. The Sixel image displays in compatible Windows Terminal; other terminals use text. Run startup moves a classic console into Terminal unless Terminal itself needs updating.

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

Use `Get-Help .\Update-AllApps.ps1 -Full` for details. Public switches: `-SelfTest`, `-DryRun`, `-IncludeStore`, `-SkipDevTools`, `-SkipSelfUpdaters`, `-SelfUpdatersOnly`, `-ReinstallNvidia`, `-NoClaude`, `-NoAnimation`, `-NoEmoji`, `-NoMascot`, `-NoRehost`, `-NoElevate`, `-MaxParallel <n>`, and `-Demo`. Internal process coordination uses `-RehostPidFile`, `-ChildStep` (Steam/Nvidia/Windows/CodeExt), and `-ChildOut`. Dry run skips installs but still checks sources and writes local status files. Demo animates fake progress.

The main run writes `UpdateBot/update-*.log`, `needs-attention.md/json`, `installed-versions.json`, and `no-change-versions.json`. No-change package releases are suppressed for 21 days. An installed version shorter than winget's advertised build suffix can denote the same release (MEGAsync 6.7.0 versus 6.7.0.3). Apps with unreadable versions get a program-file presence check; missing files trigger one forced reinstall, then an attention entry.


## Validation and limitations

Final elevated scheduled run on November 16 returned Ready/result 0: 13/13 steps, 0 updated, 0 failed, no attention items or quiet errors. Ollama pull and G HUB service checks logged successfully. Cleanup removed 19 old installer folders (about 2.3 MiB); no logs were deleted. The compact fallback drew half-blocks and app text in a classic 120x30 console, with Sixel off.

Steam deferred Wallpaper Engine startup remains unproven because no patch was pending. The prior elevated run restored Iriun Webcam (1 updated, 0 failed).

From this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-AllApps.ps1 -SelfTest
```

The scheduler test performs a real NVIDIA version lookup; other operations use fixtures.

Each suite must print `ALL CHECKS PASSED`; the overall command exits 0 and prints `SELF-TEST PASSED`. The early self-test branch performs parse checks and runs every `Test-*.ps1` in `tests/` (or `_work/tests/` for the installed live layout) without elevation or update startup. These tests create isolated temporary fixtures. The Cursor test's default watcher path refers to the original PC, so pass `-Watcher` as shown elsewhere.



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

`make-sixel.py` generates the Sixel file. `make-fallback.py` losslessly regenerates the compact text fallback from an existing fallback JSON file, keeping tiers up to 44 columns. The 88- and 60-column tiers were removed; 44/32/22-column frames remain unchanged. To regenerate safely, write a separate output file:

```powershell
python -I .\mascot\make-fallback.py .\mascot.json .\mascot.compact.json
```


## Safe promotion and retention

For the installed layout, stage edits and tests under `_work/`, then run `_work/Promote-Bot.ps1`. It parses the candidate, invokes its full self-test, verifies it did not change while testing, backs up live, and copies only after success. It refuses promotion during a running scheduled task. Explicit `-WorkScript` and `-LiveScript` paths are supported. To initialize a work copy from this portable snapshot:

```powershell
Copy-Item .\Update-AllApps.ps1 .\_work\Update-AllApps.ps1
Copy-Item .\tests .\_work\tests -Recurse
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_work\Promote-Bot.ps1
```

At the end of a completed real run, package/version installer folders under `%TEMP%\WinGet` older than 14 days are removed only if all their contents are also old. Shared caches, links and recently used folders are retained. Logs older than 90 days are listed but preserved until the user decides; no automatic log deletion is enabled. Dry run skips cleanup.

On this PC, WSL reports not installed, so no WSL update or distro installation was added. GIGABYTE's `GCC` task runs `GCC.exe -b`, a background application launcher; no verified quiet updater command was found, so it is not started by this addition. G HUB's existing `LGHUBUpdaterService` is checked and started only if stopped, without service restart or configuration changes. The requested Ollama `qwen3.5:4b-q8_0` pull completed successfully.

Vendor references: [Logitech background updater service guidance](https://support.logi.com/hc/en-au/articles/35644288645655-G-HUB-Service-restart-guide) and [GIGABYTE Update Center overview](https://www.gigabyte.com/Consumer/Software/GIGABYTE-Control-Center/). Neither establishes a supported headless forced-check command.

## Where this came from

This repository was split out of `projects/update-bot` in the private `wandrew002/agent-knowledge` notes repository on November 16, 2026. The running copy on the PC is in `C:\Users\yeet\Scripts`; this repository is the published source, so copy changes here after they are tested and promoted there.
