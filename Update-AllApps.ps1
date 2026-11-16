<#
.SYNOPSIS
    Updates every app winget can update, scans the other update sources on this
    PC, and writes a hand-off list for anything it could not do itself.

.DESCRIPTION
    Enumerates installed packages at run time, so apps installed after this
    script was written are picked up automatically. Nothing is hardcoded
    except the optional exclusion list below.

    With a real console it draws a live status block with a progress bar. In a
    redirected or hidden run it falls back to plain log lines.

    Anything it finds but cannot (or should not) update on its own goes into
    needs-attention.md and needs-attention.json in the log folder.

.PARAMETER DryRun
    List what would be updated, then stop. Changes nothing.

.PARAMETER IncludeStore
    Also sweep Microsoft Store apps.

.PARAMETER SkipDevTools
    Leave npm global packages, Python packages and VS Code extensions alone.

.PARAMETER SkipSelfUpdaters
    Leave the apps that update themselves alone (Discord, NVIDIA driver, Steam).

.PARAMETER SelfUpdatersOnly
    Check only the apps that update themselves and skip everything else.

.PARAMETER ReinstallNvidia
    Install NVIDIA's current driver even when it is already installed (a repair).

.PARAMETER NoClaude
    Do not start Claude when the run ends with updates it could not handle.

.PARAMETER NoAnimation
    Plain log lines only, no live status block.

.PARAMETER NoEmoji
    ASCII marks and bars instead of emoji and block characters.

.PARAMETER NoMascot
    Do not draw the dancing mascot beside the status block.

.PARAMETER NoRehost
    Stay in the console the script was started in. Without this, a run that
    starts in the classic console (which cannot draw pictures) moves itself
    into a Windows Terminal window, where the mascot is drawn as a real image.

.PARAMETER RehostPidFile
    Internal. Set on the copy of the script that runs inside Windows Terminal.

.PARAMETER ChildStep
    Internal. Runs one slow step (Steam, Nvidia, CodeExt) on its own, so the
    main run can do it alongside the app updates.

.PARAMETER ChildOut
    Internal. Where a -ChildStep run writes its result.

.PARAMETER MaxParallel
    How many app installs may run at once. 0 (default) auto-sizes to the CPU
    (logical cores, capped at 8). Installers that take the machine-wide Windows
    Installer lock (MSI/WiX/exe wrappers) still run one at a time no matter what
    this is, because Windows serialises them; the rest run up to this many
    together. Past roughly the core count, more lanes do not help: downloads
    saturate the connection and the MSI lock is the real limit.

.PARAMETER NoElevate
    Do not relaunch as administrator when started unelevated.

.PARAMETER Demo
    Play the live status block against a fake update list. Changes nothing.

.EXAMPLE
    .\Update-AllApps.ps1 -DryRun
    .\Update-AllApps.ps1 -IncludeStore
    .\Update-AllApps.ps1 -Demo
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$DryRun,
    [switch]$IncludeStore,
    [switch]$SkipDevTools,
    [switch]$SkipSelfUpdaters,
    [switch]$SelfUpdatersOnly,
    [switch]$ReinstallNvidia,
    [switch]$NoClaude,
    [switch]$NoAnimation,
    [switch]$NoEmoji,
    [switch]$NoMascot,
    [switch]$NoRehost,
    [switch]$NoElevate,
    [int]$MaxParallel = 0,
    [switch]$Demo,
    [string]$RehostPidFile,
    [string]$ChildStep,
    [string]$ChildOut
)

if ($SelfTest) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { $parseErrors | Write-Output; exit 1 }
    $testRoot = Join-Path $PSScriptRoot 'tests'
    if (-not (Test-Path -LiteralPath $testRoot)) { $testRoot = Join-Path $PSScriptRoot '_work\tests' }
    $tests = @(Get-ChildItem -LiteralPath $testRoot -Filter 'Test-*.ps1' -File -ErrorAction Stop | Sort-Object Name)
    if ($tests.Count -eq 0) { throw 'No test scripts found; self-test cannot pass.' }
    $watcher = Join-Path $PSScriptRoot 'cursor-update-fix.ps1'
    if (-not (Test-Path -LiteralPath $watcher)) { $watcher = Join-Path (Split-Path $PSScriptRoot) 'cursor-update-fix.ps1' }
    foreach ($test in $tests) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($test.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { $parseErrors | Write-Output; exit 1 }
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $test.FullName)
        $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        if ($parameters -contains 'Script') { $arguments += @('-Script', $PSCommandPath) }
        if ($parameters -contains 'Watcher') { $arguments += @('-Watcher', $watcher) }
        Write-Output ('Testing {0}' -f $test.Name)
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments
        if ($LASTEXITCODE -ne 0) { Write-Output ('FAILED: {0} (exit {1})' -f $test.Name, $LASTEXITCODE); exit 1 }
    }
    Write-Output ('SELF-TEST PASSED ({0} suites plus parse checks)' -f $tests.Count)
    exit 0
}

# --- Apps to never auto-update. Match on winget Id. Add as needed. ---
$Exclude = @(
    'EpicGames.EpicOnlineServices'   # bundled by Epic Games Launcher; install tech differs, launcher updates it
)

# --- winget's upgrade check rejects these ("does not apply to your system"), but the
#     publisher's installer upgrades them in place, so run it with install --force.
#     Only add an app here after checking it does not end up installed twice.
$ForceInstall = @(
    'Mega.MEGASync'                  # per-user install; the winget package declares no matching scope
)

# --- winget has a package for these but cannot link it to the installed copy, so it
#     never offers their updates. The script compares the versions itself and installs
#     the newer package over the top. Left: winget Id. Right: the app's name in Windows'
#     installed-apps list (wildcards allowed).
$Adopt = [ordered]@{
    'qBittorrent.qBittorrent' = 'qBittorrent*'
    'OpenJS.NodeJS'           = 'Node.js'
    'AnalogDevices.LTspice'   = 'LTspice*'
}

# --- Updated last: replacing these can close the console this script runs in. ---
$UpdateLast = @(
    'Microsoft.WindowsTerminal', 'Microsoft.WindowsTerminal.Preview',
    'Microsoft.AppInstaller', 'Microsoft.PowerShell', 'Microsoft.PowerShell.Preview'
)

# --- Steam apps this script may update when it starts Steam itself. Every other
#     game is held back for that moment, so a run never pulls down a big game patch.
#     Match on Steam app id.
$SteamKeepUpdated = @(
    '431960'                         # Wallpaper Engine
)

# --- A new NVIDIA driver is installed only once it has been out this many days,
#     and never while the graphics card is busier than this (a game is running).
$NvidiaMinAgeDays    = 3
$NvidiaMaxGpuPercent = 30

# Kept beside the script rather than under AppData. The Claude desktop app is a
# packaged app, and Windows gives packaged apps a private copy of whatever they
# write under AppData, so a folder there is not the same folder for this script
# and for Claude. This one is.
$LogDir      = Join-Path $PSScriptRoot 'UpdateBot'
$LogFile     = Join-Path $LogDir ('update-' + (Get-Date -Format 'yyyy-MM-dd_HHmmss') + '.log')
if ($ChildStep -and $ChildOut) { $LogFile = "$ChildOut.log" }   # a step run alongside logs to its own file; the main run copies it in
$HandoffMd   = Join-Path $LogDir 'needs-attention.md'
$HandoffJson = Join-Path $LogDir 'needs-attention.json'
$MemoFile    = Join-Path $LogDir 'installed-versions.json'

# Windows Update ids that may be installed on the next elevated run. Windows updates
# are never installed on this script's own judgment: Claude reads the hand-off list,
# decides, and writes the ids it approves here as a JSON array of strings.
$ApprovedFile = Join-Path $LogDir 'approved-windows-updates.json'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# The switches this run was started with, for the places that start another copy of it.
$script:BoundNames = @($PSBoundParameters.Keys)
$script:Rehosted   = $false

# --- Elevation -------------------------------------------------------------
$isAdmin =([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $NoElevate -and -not $DryRun -and -not $Demo) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-NoElevate')
    foreach ($name in 'IncludeStore', 'SkipDevTools', 'SkipSelfUpdaters', 'SelfUpdatersOnly', 'ReinstallNvidia', 'NoClaude', 'NoAnimation', 'NoEmoji', 'NoMascot', 'NoRehost') {
        if ($PSBoundParameters.ContainsKey($name)) { $relaunch += "-$name" }
    }
    if ($PSBoundParameters.ContainsKey('MaxParallel')) { $relaunch += @('-MaxParallel', $MaxParallel) }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs | Out-Null
        exit 0
    } catch {
        # UAC was declined: carry on unelevated and report what gets skipped.
    }
}

# The copy that runs inside Windows Terminal (see Invoke-Rehost) tells the copy
# that started it which process to wait for.
if ($RehostPidFile) {
    if (Test-Path "$RehostPidFile.cancel") { exit 0 }   # the starter stopped waiting and is doing the run itself
    Set-Content -Path $RehostPidFile -Value "pid=$PID" -Encoding ascii
}

# Windows PowerShell does not offer TLS 1.2 to web servers unless asked to.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Live display ----------------------------------------------------------
# Everything the live block draws is built as one string of ANSI escapes and
# written in a single call, so the dancer's per-pixel truecolour sits beside
# the status text without the console fighting us over colours.
$E = [char]27
$script:Ansi = @{
    Reset = "$E[0m"; Bold = "$E[1m"; Dim = "$E[90m"; White = "$E[97m"; Gray = "$E[37m"
    Cyan  = "$E[96m"; Green = "$E[92m"; Red = "$E[91m"; Yellow = "$E[93m"; DarkYellow = "$E[33m"; Magenta = "$E[95m"
}
function Get-AnsiColor([string]$Name) { if ($script:Ansi.ContainsKey($Name)) { $script:Ansi[$Name] } else { $script:Ansi.Gray } }

function ConvertFrom-CodePoint([int]$CodePoint) { [char]::ConvertFromUtf32($CodePoint) }

# Marks used in the item list and the plain log. Emoji by default, ASCII with -NoEmoji.
if ($NoEmoji) {
    $Glyph = @{ Ok = '+'; Fail = 'x'; Skip = '~'; Info = '>'; Party = '*'; Run = '>'; Wait = '.'; FullCh = '#'; EmptyCh = '-' }
} else {
    $Glyph = @{
        Ok   = ConvertFrom-CodePoint 0x2713      # check mark (the text one: the heavy check is drawn as a fixed-colour emoji)
        Fail = ConvertFrom-CodePoint 0x2717      # ballot x
        Skip = '~'
        Info = ConvertFrom-CodePoint 0x2022      # bullet
        Party = ConvertFrom-CodePoint 0x1F389
        Run  = ConvertFrom-CodePoint 0x25B6      # right triangle
        Wait = ConvertFrom-CodePoint 0x00B7      # middle dot
        FullCh  = ConvertFrom-CodePoint 0x2588   # full block
        EmptyCh = ConvertFrom-CodePoint 0x2591   # light shade
    }
}

$script:Live = $false
if (-not $NoAnimation) {
    try {
        $script:Live = ($Host.Name -eq 'ConsoleHost') -and
                       (-not [Console]::IsOutputRedirected) -and
                       ($Host.UI.RawUI.WindowSize.Width -ge 60)
    } catch { $script:Live = $false }
}

# conhost needs virtual-terminal processing turned on before it honours the
# colour and cursor codes; Windows Terminal already has it on.
function Enable-VtProcessing {
    try {
        if (-not ('Native.Vt' -as [type])) {
            Add-Type -Namespace Native -Name Vt -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int n);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr h, out uint mode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr h, uint mode);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr h, int cmd);
'@
        }
        $h = [Native.Vt]::GetStdHandle(-11)
        [uint32]$mode = 0
        if ([Native.Vt]::GetConsoleMode($h, [ref]$mode)) {
            return [Native.Vt]::SetConsoleMode($h, $mode -bor 0x0004)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        }
    } catch {}
    return $false
}

# Can this console draw pictures? Asks the terminal for its device attributes;
# a 4 in the reply means Sixel graphics. Windows Terminal says yes, the classic
# console host says no.
function Test-SixelSupport {
    try {
        $in = [Native.Vt]::GetStdHandle(-10)
        [uint32]$old = 0
        if (-not [Native.Vt]::GetConsoleMode($in, [ref]$old)) { return $false }
        [void][Native.Vt]::SetConsoleMode($in, 0x0200)   # raw input, so the reply is not echoed or held for Enter
        try {
            while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
            [Console]::Write("$E[c")
            $reply = New-Object System.Text.StringBuilder
            $until = (Get-Date).AddMilliseconds(700)
            while ((Get-Date) -lt $until) {
                if ([Console]::KeyAvailable) {
                    $ch = [Console]::ReadKey($true).KeyChar
                    [void]$reply.Append($ch)
                    if ($ch -eq 'c') { break }
                } else { Start-Sleep -Milliseconds 10 }
            }
            return ($reply.ToString() -match ';4[;c]')
        } finally {
            [void][Native.Vt]::SetConsoleMode($in, $old)
        }
    } catch { return $false }
}

if ($script:Live) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; [Console]::CursorVisible = $false } catch {}
    if (-not (Enable-VtProcessing)) { $script:Live = $false }   # no VT means the escapes would print as text
}

# How often the live block redraws. Faster when the mascot is a real image, so
# the dance plays at the GIF's own speed.
$script:TickMs = 250

# The dancing mascot, as a real image where the console can draw one (Sixel:
# Windows Terminal). The frames come from mascot.sixel.json beside this script,
# made from the GIF by _work\mascot\make-sixel.py, and are shown at the GIF's own
# resolution. Cosmetic; the run is identical without it.
$script:Sixel = $null
$script:SixelSupported = $false
if ($script:Live -and -not $NoMascot) {
    $sixelFile = Join-Path $PSScriptRoot 'mascot.sixel.json'
    if (Test-Path $sixelFile) {
        $script:SixelSupported = Test-SixelSupport
        if ($script:SixelSupported) {
            try {
                $s = Get-Content $sixelFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $frames = @($s.frames)
                if ($frames.Count -gt 0) {
                    $script:Sixel = @{ Cols = [int]$s.cols; Rows = [int]$s.rows; DelayMs = [math]::Max(40, [int]$s.delayMs); Frames = $frames; Shown = -1 }
                    $script:TickMs = [math]::Max(60, [math]::Min(250, $script:Sixel.DelayMs))
                }
            } catch {}
        }
    }
}

# Where the console can only draw text, the mascot is built from half-block
# characters instead (mascot.json). It ships in a few resolution tiers, largest
# first; the biggest one that fits the window is used. A text "pixel" is half a
# character cell, so a bigger grid is the only way to get more detail there.
$script:MascotTiers = @()
if ($script:Live -and -not $NoMascot -and -not $script:Sixel) {
    $mascotFile = Join-Path $PSScriptRoot 'mascot.json'
    if (Test-Path $mascotFile) {
        try {
            $m = Get-Content $mascotFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($t in $m.tiers) {
                $frames = @($t.frames | ForEach-Object { , @($_) })
                if ($frames.Count -gt 0) {
                    $script:MascotTiers += , @{ Cols = [int]$t.cols; Rows = [int]$t.rows; MinW = [int]$t.minW; MinH = [int]$t.minH; Frames = $frames }
                }
            }
        } catch {}
    }
}

function Format-Bytes([double]$n) {
    if ($n -ge 1GB) { '{0:N1} GB' -f ($n / 1GB) }
    elseif ($n -ge 1MB) { '{0:N1} MB' -f ($n / 1MB) }
    elseif ($n -ge 1KB) { '{0:N0} KB' -f ($n / 1KB) }
    else { '{0:N0} B' -f $n }
}

# An item is one line in the list: an app with a bar, or a step that just reports.
$script:UI = @{
    Phase     = 'Starting'
    Total     = 0
    Done      = 0
    Frame     = 0
    Beat      = 0
    Drawn     = 0
    LastW     = 0
    LastH     = 0
    Started   = Get-Date
    Items     = New-Object System.Collections.Generic.List[object]
    ByKey     = @{}
    Speed     = 0.0
    LastBytes = 0.0
    LastTick  = Get-Date
    LastPoll  = Get-Date
}

# Slow steps that run as their own process alongside the app updates (see Start-ChildStep).
$script:Children  = New-Object System.Collections.Generic.List[object]
$script:Receiving = $false

function Add-Item {
    param([string]$Key, [string]$Label, [string]$State = 'queued')
    $it = [pscustomobject]@{ Key = $Key; Label = $Label; State = $State; Pct = $null; Note = ''; Mark = ''; Color = 'Gray' }
    $script:UI.Items.Add($it)
    if ($Key) { $script:UI.ByKey[$Key] = $it }
    $it
}

function Set-Item {
    param([string]$Key, [string]$State, $Pct, [string]$Note, [string]$Label)
    $it = $null
    if ($script:UI.ByKey.ContainsKey($Key)) { $it = $script:UI.ByKey[$Key] }
    if (-not $it) { $lbl = $Label; if (-not $lbl) { $lbl = $Key }; $it = Add-Item -Key $Key -Label $lbl }
    if ($PSBoundParameters.ContainsKey('State')) { $it.State = $State }
    if ($PSBoundParameters.ContainsKey('Pct'))   { $it.Pct = $Pct }
    if ($PSBoundParameters.ContainsKey('Note'))  { $it.Note = $Note }
    if ($PSBoundParameters.ContainsKey('Label') -and $Label) { $it.Label = $Label }
    Show-Status
}

# A filled bar (download or done).
function New-Bar([double]$Pct, [int]$Width) {
    $p = [math]::Max(0.0, [math]::Min(1.0, $Pct))
    $f = [int][math]::Round($p * $Width)
    '{0}{1}{2}{3}{4}' -f $script:Ansi.Green, ($Glyph.FullCh * $f), $script:Ansi.Dim, ($Glyph.EmptyCh * ($Width - $f)), $script:Ansi.Reset
}

# A bar with no known total: a bright block bounces along it while installing.
function New-Pulse([int]$Width, [int]$Frame) {
    $pos = $Frame % (2 * $Width)
    if ($pos -ge $Width) { $pos = 2 * $Width - 1 - $pos }
    $s = $script:Ansi.Dim
    for ($i = 0; $i -lt $Width; $i++) {
        if ([math]::Abs($i - $pos) -le 1) { $s += $script:Ansi.Cyan + $Glyph.FullCh + $script:Ansi.Dim } else { $s += $Glyph.EmptyCh }
    }
    $s + $script:Ansi.Reset
}

function Format-ItemLine($it) {
    $A = $script:Ansi
    $label = $it.Label
    if ($label.Length -gt 18) { $label = $label.Substring(0, 17) + [char]0x2026 }
    $label = $label.PadRight(18)
    switch ($it.State) {
        'queued'   { '  {0}{1} {2}  {3}queued{4}'      -f $A.Dim, $Glyph.Wait, $label, '', $A.Reset }
        'download' {
            $note = 'downloading'
            if ($null -ne $it.Pct) { $note = '{0,3}% {1}' -f [int]($it.Pct * 100), ([char]0x2193) }
            '  {0}{1}{2} {3} {4}{5}{6}' -f $A.Cyan, $Glyph.Run, $A.Reset, $label, (New-Bar ([double]($it.Pct)) 12), ' ', $note
        }
        'install'  { '  {0}{1}{2} {3} {4} {5}installing{6}' -f $A.Yellow, $Glyph.Run, $A.Reset, $label, (New-Pulse 12 $script:UI.Beat), $A.Yellow, $A.Reset }
        'busy'     { '  {0}{1}{2} {3} {4} {5}{6}{7}'        -f $A.Cyan, $Glyph.Run, $A.Reset, $label, (New-Pulse 12 $script:UI.Beat), $A.Cyan, $it.Note, $A.Reset }
        'done'     { '  {0}{1}{2} {3}  {4}{5}{6}'           -f $A.Green, $Glyph.Ok, $A.Reset, $label, $A.Green, $it.Note, $A.Reset }
        'failed'   { '  {0}{1} {2}  {3}{4}'                 -f $A.Red, $Glyph.Fail, $label, $it.Note, $A.Reset }
        'skip'     { '  {0}{1} {2}  {3}{4}'                 -f $A.DarkYellow, $Glyph.Skip, $label, $it.Note, $A.Reset }
        default    { '  {0}{1} {2}{3}'                      -f (Get-AnsiColor $it.Color), $it.Mark, $it.Label, $A.Reset }   # 'msg'
    }
}

# Picks which items to show when the list is taller than the window: always the
# ones still working, then the most recent finished ones to fill the budget.
function Select-VisibleItems([int]$Budget) {
    $items = $script:UI.Items
    if ($Budget -lt 1) { $Budget = 1 }
    if ($items.Count -le $Budget) { return $items.ToArray() }
    $live   = 'download', 'install', 'busy', 'failed'
    $active = @($items | Where-Object { $live -contains $_.State })
    $rest   = @($items | Where-Object { $live -notcontains $_.State })
    $room   = $Budget - $active.Count - 1
    if ($room -lt 0) { $room = 0 }
    $tail   = @($rest | Select-Object -Last $room)
    $hidden = $items.Count - $active.Count - $tail.Count
    $out = New-Object System.Collections.Generic.List[object]
    if ($hidden -gt 0) {
        $note = [pscustomobject]@{ Key = $null; Label = ('... and {0} more' -f $hidden); State = 'msg'; Pct = $null; Note = ''; Mark = ' '; Color = 'Dim' }
        $out.Add($note)
    }
    foreach ($x in $tail)   { $out.Add($x) }
    foreach ($x in $active) { $out.Add($x) }
    $out.ToArray()
}

# Builds the right-hand content: header, the overall bar, stats, then the list.
function Get-StatusContent([int]$MaxItems) {
    $ui = $script:UI; $A = $script:Ansi
    $pct = 0.0
    if ($ui.Total -gt 0) { $pct = [math]::Min(1.0, $ui.Done / $ui.Total) }
    $elapsed = (Get-Date) - $ui.Started
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}{1}Update All Apps{2}' -f $A.Bold, $A.White, $A.Reset))
    $lines.Add(('{0} {1,3}%' -f (New-Bar $pct 24), [int]($pct * 100)))
    $stat = '{0}{1}/{2} apps   {3:mm\:ss}' -f $A.Gray, $ui.Done, $ui.Total, $elapsed
    if ($pct -gt 0.02 -and $pct -lt 1.0) {
        $rem = [timespan]::FromSeconds([math]::Max(0, $elapsed.TotalSeconds * (1 - $pct) / $pct))
        if ($rem.TotalMinutes -ge 1) { $stat += '   ~{0}m left' -f [int]$rem.TotalMinutes } else { $stat += '   ~{0}s left' -f [int]$rem.TotalSeconds }
    }
    if ($ui.Speed -gt 0) { $stat += '   {0}{1} {2}/s{3}' -f $A.Cyan, ([char]0x2193), (Format-Bytes $ui.Speed), $A.Gray }
    $lines.Add($stat + $A.Reset)
    $lines.Add(('{0}{1}{2}' -f $A.Dim, $ui.Phase, $A.Reset))
    $lines.Add('')
    foreach ($it in (Select-VisibleItems $MaxItems)) { $lines.Add((Format-ItemLine $it)) }
    $lines.ToArray()
}

function Show-Status {
    # Every wait loop calls this, so it is also where steps running alongside get collected.
    if ($script:Children.Count -gt 0 -and -not $script:Receiving) {
        $script:Receiving = $true
        try { Receive-ChildSteps } finally { $script:Receiving = $false }
    }
    if (-not $script:Live) { return }
    $ui = $script:UI
    try {
        $size = $Host.UI.RawUI.WindowSize
        $w = $size.Width; $h = $size.Height
        $ui.Beat = [int][math]::Floor(((Get-Date) - $ui.Started).TotalMilliseconds / 250)   # animation clock, 4 steps a second

        # The mascot: a real image when the console can draw one and the window
        # has room, otherwise the biggest half-block tier that fits, otherwise none.
        $sixel = $script:Sixel
        if ($sixel -and ($w -lt ($sixel.Cols + 48) -or $h -lt ($sixel.Rows + 3))) { $sixel = $null }
        $mascot = $null
        if (-not $sixel) {
            foreach ($t in $script:MascotTiers) { if ($w -ge $t.MinW -and $h -ge $t.MinH) { $mascot = $t; break } }
        }
        $gutter = 0; $mrows = 0; $frame = $null
        if ($sixel) {
            $gutter = $sixel.Cols + 4
            $mrows  = $sixel.Rows
        } elseif ($mascot) {
            $gutter = $mascot.Cols + 4
            $mrows  = $mascot.Rows
            $frame  = $mascot.Frames[$ui.Beat % $mascot.Frames.Count]
        }
        $budget = $h - 7
        $content = Get-StatusContent $budget
        $n = [math]::Max($mrows, $content.Count)

        $sb = New-Object System.Text.StringBuilder
        # A resized window reflows what was on it, leaving scraps where the block
        # used to be. Start again from a clean screen when the size changes.
        if ($ui.Drawn -gt 0 -and ($w -ne $ui.LastW -or $h -ne $ui.LastH)) {
            [void]$sb.Append("$E[2J$E[3J$E[H")
            $ui.Drawn = 0
        }
        $ui.LastW = $w; $ui.LastH = $h
        $fresh = ($ui.Drawn -eq 0)
        if ($ui.Drawn -gt 0) { [void]$sb.Append("$E[$($ui.Drawn)A") }
        for ($i = 0; $i -lt $n; $i++) {
            [void]$sb.Append("`r")
            if ($sixel) {
                # Jump over the picture instead of writing spaces, which would erase it.
                # (On a first draw there is no picture yet, so the whole line is cleared.)
                if ($fresh) { [void]$sb.Append("$E[2K") }
                [void]$sb.Append("$E[$($gutter + 1)G")
            } elseif ($mascot) {
                if ($i -lt $mrows) { [void]$sb.Append('  '); [void]$sb.Append($frame[$i]); [void]$sb.Append('  ') }
                else { [void]$sb.Append(' ' * $gutter) }
            }
            if ($i -lt $content.Count) { [void]$sb.Append($content[$i]) }
            [void]$sb.Append("$E[K`n")
        }
        # If the block shrank, wipe the lines left over from last time.
        $extra = $ui.Drawn - $n
        if ($extra -gt 0) {
            for ($i = 0; $i -lt $extra; $i++) { [void]$sb.Append("`r$E[K`n") }
            [void]$sb.Append("$E[${extra}A")
        }
        if ($sixel) {
            # The frame is chosen by the clock, so the dance keeps the GIF's speed
            # however often this is called. It is only redrawn when it changes.
            $index = [int]([math]::Floor(((Get-Date) - $ui.Started).TotalMilliseconds / $sixel.DelayMs) % $sixel.Frames.Count)
            if ($index -ne $sixel.Shown -or $fresh -or $ui.Drawn -ne $n) {
                # Remember the cursor, go to the block's top-left corner, draw, come back.
                [void]$sb.Append("${E}7$E[${n}A`r$E[3G")
                [void]$sb.Append($sixel.Frames[$index])
                [void]$sb.Append("${E}8")
                $sixel.Shown = $index
            }
        }
        [Console]::Write($sb.ToString())
        $ui.Drawn = $n
        $ui.Frame++
    } catch {
        $script:Live = $false
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    if ($script:Live) { return }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Set-Phase([string]$Text) { $script:UI.Phase = $Text; Show-Status }

# Kept for the many callers that just report a finished step. Appends one line.
function Add-Row {
    param([string]$Mark, [string]$Text, [string]$Color = 'Gray')
    $it = [pscustomobject]@{ Key = $null; Label = $Text; State = 'msg'; Pct = $null; Note = ''; Mark = $Mark; Color = $Color }
    $script:UI.Items.Add($it)
    Show-Status
}

# Runs a native command while the status block keeps animating.
function Invoke-Animated {
    param([string]$File, [string[]]$Arguments, [int]$TimeoutSec = 1800)
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -PassThru `
                              -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $proc.Handle   # keeps ExitCode readable after the process ends
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $timedOut = $false
        while (-not $proc.HasExited) {
            Show-Status
            Start-Sleep -Milliseconds $script:TickMs
            if ((Get-Date) -gt $deadline) { $timedOut = $true; try { $proc.Kill() } catch {}; break }
        }
        $proc.WaitForExit()
        $stdout = [string](Get-Content -Path $out -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        $stderr = [string](Get-Content -Path $err -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $stdout + $stderr; StdOut = $stdout; TimedOut = $timedOut }
    } catch {
        [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message; StdOut = ''; TimedOut = $false }
    } finally {
        Remove-Item $out, $err -ErrorAction SilentlyContinue
    }
}

# Runs a script block in a background job while the status block keeps animating.
function Invoke-AnimatedJob {
    param([scriptblock]$ScriptBlock, [int]$TimeoutSec = 180, [object[]]$ArgumentList = @())
    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) {
        Show-Status
        Start-Sleep -Milliseconds $script:TickMs
    }
    if ($job.State -eq 'Running') {
        Stop-Job $job; Remove-Job $job -Force
        return [pscustomobject]@{ Ok = $false; Result = @(); Error = 'timed out' }
    }
    $failed = $job.State -eq 'Failed'
    $result = @(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobError)
    Remove-Job $job -Force
    [pscustomobject]@{ Ok = (-not $failed -and -not $jobError); Result = $result; Error = ("$jobError").Trim() }
}

# winget draws a spinner and progress bar even when redirected; keep the text only.
function Format-NativeOutput([string]$Text) {
    if (-not $Text) { return '' }
    $block = '[' + (ConvertFrom-CodePoint 0x2588) + (ConvertFrom-CodePoint 0x2592) + ']'
    $keep = $Text -split "`r`n|`n|`r" | Where-Object {
        $_.Trim() -and $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch $block
    }
    ($keep | ForEach-Object { $_.TrimEnd() }) -join "`r`n"
}

# --- Hand-off list ---------------------------------------------------------
$script:Handoff = New-Object System.Collections.Generic.List[object]

function Add-Handoff {
    param([string]$Source, [string]$Name, [string]$Reason, [string]$Suggestion, [string]$Id = '', [string]$Detail = '')
    $script:Handoff.Add([pscustomobject]@{
        source = $Source; name = $Name; id = $Id; reason = $Reason; suggestion = $Suggestion; detail = $Detail
    })
    Write-Log ('  NEEDS ATTENTION [{0}] {1}: {2}' -f $Source, $Name, $Reason) 'WARN'
}

function Write-Handoff {
    $items = $script:Handoff.ToArray()
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    ConvertTo-Json -InputObject @{ generated = $stamp; log = $LogFile; items = $items } -Depth 5 |
        Set-Content -Path $HandoffJson -Encoding utf8

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('# Updates that need attention')
    $md.Add('')
    $md.Add("Generated $stamp by Update-AllApps.ps1. Full log: $LogFile")
    $md.Add('')
    if ($items.Count -eq 0) {
        $md.Add('Nothing needs attention. Everything this run found was updated.')
    } else {
        foreach ($group in ($items | Group-Object source)) {
            $md.Add("## $($group.Name)")
            $md.Add('')
            foreach ($item in $group.Group) {
                $md.Add("- **$($item.name)**: $($item.reason). $($item.suggestion)")
                if ($item.detail) { $md.Add("  - $($item.detail)") }
            }
            $md.Add('')
        }
    }
    Set-Content -Path $HandoffMd -Value $md -Encoding utf8
}

# Starts Claude Code on the hand-off list, so nobody has to ask it to.
$script:ClaudeStarted = $false
function Start-ClaudeHandoff {
    $lock = Join-Path $LogDir 'claude-handling.lock'
    $link = Join-Path $PSScriptRoot 'Handle leftovers with Claude.lnk'

    # Claude reruns this script while it works. The lock stops those runs starting Claude again.
    if (Test-Path $lock) {
        if (((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 90) {
            Write-Log 'Claude is already working on the list.'
            return
        }
        Remove-Item -LiteralPath $lock -ErrorAction SilentlyContinue   # left behind by a run that died
    }
    if (-not (Test-Path $link)) {
        Write-Log 'The Claude hand-off shortcut is missing, so the list stays as it is.' 'WARN'
        return
    }

    Set-Content -Path $lock -Value (Get-Date -Format o) -Encoding ascii
    # Opened through the desktop shell on purpose: that starts Claude as the normal
    # user even though this script is running as administrator.
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $link)
    $script:ClaudeStarted = $true
    Write-Log 'Started Claude to work through the list.' 'OK'
    Add-Row $Glyph.Info 'Claude is working through the list' 'Cyan'
}

# --- Versions this script installed -----------------------------------------
# winget cannot read the version of some apps ("Unknown"), so it offers them the
# same update on every run. Remembering what was installed breaks that loop.
function Get-InstalledMemo {
    $memo = @{}
    if (Test-Path $MemoFile) {
        try {
            (Get-Content $MemoFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $memo[$_.Name] = [string]$_.Value }
        } catch {}
    }
    $memo
}

function Save-InstalledVersion([string]$Id, [string]$Version) {
    if (-not $Version) { return }
    $memo = Get-InstalledMemo
    $memo[$Id] = $Version
    $memo | ConvertTo-Json | Set-Content -Path $MemoFile -Encoding utf8
}

# winget sometimes offers a version whose installer puts nothing new on the disk
# (MEGAsync "6.7.0.3" installed 6.7.0 again on 2026-10-25 and again a week
# later). Such a version is remembered for three weeks, so the same download is
# not repeated every Sunday; after that it gets one more try.
$NoChangeFile = Join-Path $LogDir 'no-change-versions.json'

function Get-NoChangeMemo {
    $memo = @{}
    if (Test-Path $NoChangeFile) {
        try {
            $cutoff = (Get-Date).AddDays(-21)
            (Get-Content $NoChangeFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
                if ([datetime]$_.Value.date -gt $cutoff) { $memo[$_.Name] = @{ version = [string]$_.Value.version; date = [string]$_.Value.date } }
            }
        } catch {}
    }
    $memo
}

function Save-NoChange([string]$Id, [string]$Version) {
    if (-not $Version) { return }
    $memo = Get-NoChangeMemo
    $memo[$Id] = @{ version = $Version; date = (Get-Date -Format 'yyyy-MM-dd') }
    $memo | ConvertTo-Json | Set-Content -Path $NoChangeFile -Encoding utf8
}

# --- winget ----------------------------------------------------------------
function Get-WingetUpgrades {
    $run = Invoke-Animated -File $script:Winget -TimeoutSec 300 -Arguments @(
        'upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity')

    # winget has no stable machine-readable upgrade list, so parse the table.
    $lines  = $run.Output -split "`r`n|`n|`r"
    $header = $lines | Where-Object { $_ -match '^Name\s+Id\s+Version' } | Select-Object -First 1
    $found  = @()
    if ($header) {
        $idCol    = $header.IndexOf('Id')
        $verCol   = $header.IndexOf('Version')
        $availCol = $header.IndexOf('Available')
        $srcCol   = $header.IndexOf('Source')
        $start    = [array]::IndexOf($lines, $header) + 2

        for ($i = $start; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($l)) { break }
            if ($l -match 'upgrades? available' -or $l -match '^\s*-+\s*$') { continue }
            if ($l.Length -le $verCol) { continue }

            $version = ''; $available = ''
            if ($availCol -gt $verCol -and $l.Length -gt $availCol) {
                $version = $l.Substring($verCol, $availCol - $verCol).Trim()
                $end = $l.Length
                if ($srcCol -gt $availCol -and $l.Length -gt $srcCol) { $end = $srcCol }
                $available = $l.Substring($availCol, $end - $availCol).Trim()
            }
            $found += [pscustomobject]@{
                Name      = $l.Substring(0, $idCol).Trim()
                Id        = $l.Substring($idCol, $verCol - $idCol).Trim()
                Version   = $version
                Available = $available
            }
        }
    }
    @($found | Where-Object { $_.Id -and $_.Id -notmatch '\s' })
}

function Get-FailureReason {
    param([string]$Output, [int]$ExitCode)
    if ($Output -match '\b404\b|Not found \(') { return 'the publisher''s download link is dead (404)' }
    if ($Output -match 'hash does not match')  { return 'the installer does not match its published hash' }
    if ($Output -match 'No applicable|No available upgrade|No newer package') {
        return 'winget lists an update but has no installer that fits this install'
    }
    if ($Output -match 'in use|currently running') { return 'the app was running and could not be replaced' }
    if ($Output -match 'administrator')            { return 'it needs administrator rights' }
    'winget exit code {0}' -f $ExitCode
}

# The version winget now lists as installed for one package, or $null if it cannot tell.
function Get-WingetInstalledVersion([string]$Id) {
    $run = Invoke-Animated -File $script:Winget -TimeoutSec 120 -Arguments @(
        'list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $lines  = $run.Output -split "`r`n|`n|`r"
    $header = $lines | Where-Object { $_ -match '^Name\s+Id\s+Version' } | Select-Object -First 1
    if (-not $header) { return $null }
    $verCol = $header.IndexOf('Version')
    $row = $lines | Select-Object -Skip ([array]::IndexOf($lines, $header) + 2) | Where-Object { $_.Trim() } | Select-Object -First 1
    if (-not $row -or $row.Length -le $verCol) { return $null }
    # The version column ends where the Available (or else the Source) column starts.
    $end = $row.Length
    foreach ($name in 'Available', 'Source') {
        $col = $header.IndexOf($name)
        if ($col -gt $verCol -and $col -lt $end) { $end = $col; break }
    }
    $row.Substring($verCol, $end - $verCol).Trim()
}

# Returns 'ok', 'failed', or 'unchanged' (winget said yes, but the version did not move).
# Reads a file another process is still writing (winget's redirected output),
# without taking a lock that would stop it writing.
function Read-FileShared([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { '' }
}

# --- Parallel winget scheduler ---------------------------------------------
# Updates run several at once so one slow installer (VirtualBox's wrapper sat for
# 33 minutes on 2026-10-25) no longer holds up everything behind it. Installers
# that take the machine-wide Windows Installer lock (msi/wix/burn, and exe
# wrappers that may contain an MSI) are kept to one at a time; the rest run up to
# MaxParallel together. A clash with the installer lock is retried, not failed.
$script:SerialFirstWords = @('msi', 'wix', 'burn', 'exe')
function Test-SerialType([string]$Type) {
    if (-not $Type) { return $true }                 # unknown: assume it might take the lock
    $script:SerialFirstWords -contains (($Type -split '\s+')[0])
}

# Asks winget for each app's installer type and url, all at once (each winget
# show is a second or so, so firing them together keeps the wait short).
function Get-InstallerInfoMany([string[]]$Ids) {
    $map = @{}
    if (-not $Ids -or $Ids.Count -eq 0) { return $map }
    $procs = @()
    foreach ($id in $Ids) {
        $o = [IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $script:Winget -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError "$o.e" `
             -ArgumentList @('show', '--id', $id, '--exact', '--accept-source-agreements', '--disable-interactivity')
        $null = $p.Handle
        $procs += [pscustomobject]@{ Id = $id; Out = $o; P = $p }
    }
    $deadline = (Get-Date).AddSeconds(90)
    while (@($procs | Where-Object { -not $_.P.HasExited }).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Show-Status; Start-Sleep -Milliseconds 200
    }
    foreach ($x in $procs) {
        try { if (-not $x.P.HasExited) { $x.P.Kill() } } catch {}
        $txt = [string](Get-Content $x.Out -Raw -ErrorAction SilentlyContinue)
        $type = ([regex]::Match($txt, '(?m)^\s*Installer Type:\s*(.+)$').Groups[1].Value).Trim().ToLower()
        $url  = ([regex]::Match($txt, '(?m)^\s*Installer Url:\s*(.+)$').Groups[1].Value).Trim()
        $map[$x.Id] = @{ Type = $type; Url = $url }
        Remove-Item $x.Out, "$($x.Out).e" -ErrorAction SilentlyContinue
    }
    $map
}

function New-WingetTasks($Apps) {
    if (-not $Apps -or @($Apps).Count -eq 0) { return @() }
    $info = Get-InstallerInfoMany @($Apps | ForEach-Object { $_.Id })
    @($Apps | ForEach-Object {
        $meta = $info[$_.Id]; $type = ''; $url = ''
        if ($meta) { $type = $meta.Type; $url = $meta.Url }
        [pscustomobject]@{
            Id = $_.Id; Name = $_.Name; Version = $_.Version; Available = $_.Available
            Type = $type; Url = $url; Serial = (Test-SerialType $type)
            TotalBytes = 0.0; Staged = 0.0; State = 'queued'; Pct = $null
            Tries = 0; Force = $false
            Proc = $null; OutFile = $null; ErrFile = $null; Started = $null
        }
    })
}

# The newest winget staging folder for an app, and how many bytes it holds now.
function Get-StagedBytes([string]$Id) {
    try {
        $dir = Get-ChildItem (Join-Path $env:TEMP "WinGet\$Id.*") -Directory -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $dir) { return 0.0 }
        $f = Get-ChildItem $dir.FullName -File -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -notmatch '\.(yaml|json|txt)$' } |
             Sort-Object Length -Descending | Select-Object -First 1
        if ($f) { return [double]$f.Length }
    } catch {}
    0.0
}

function Start-WingetTask($t) {
    $t.OutFile = [IO.Path]::GetTempFileName()
    $t.ErrFile = [IO.Path]::GetTempFileName()
    $verb = @('upgrade', '--include-unknown')
    if ($ForceInstall -contains $t.Id -or $t.Force) { $verb = @('install', '--force') }
    $args = $verb + @('--id', $t.Id, '--exact', '--silent',
        '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    $t.Proc = Start-Process -FilePath $script:Winget -ArgumentList $args -NoNewWindow -PassThru `
                            -RedirectStandardOutput $t.OutFile -RedirectStandardError $t.ErrFile
    $null = $t.Proc.Handle
    $t.Started = Get-Date
    $t.State = 'download'
    # A real download bar needs the total size; a quick HEAD gets it (skipped if slow).
    if ($t.TotalBytes -le 0 -and $t.Url -match '^https?://') {
        try {
            $r = Invoke-WebRequest -Method Head -Uri $t.Url -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 5
            $t.TotalBytes = [double]($r.Headers.'Content-Length')
        } catch {}
    }
    Set-Item -Key $t.Id -State 'download' -Pct $null -Label $t.Name
    Write-Log ('Updating {0} ...' -f $t.Name)
}

# Updates the live bars from the growing staging files, flips a task to
# "installing" once its download is in, and works out the overall speed.
function Update-TaskProgress($running) {
    $now = Get-Date
    # The display may tick many times a second; the disk only needs looking at a few times.
    if (($now - $script:UI.LastPoll).TotalMilliseconds -lt 350) { return }
    $script:UI.LastPoll = $now
    $total = 0.0
    foreach ($t in $running) {
        $staged = Get-StagedBytes $t.Id
        $t.Staged = $staged
        $total += $staged
        $it = $null
        if ($script:UI.ByKey.ContainsKey($t.Id)) { $it = $script:UI.ByKey[$t.Id] }
        if ($t.State -eq 'download') {
            $installing = $false
            if ((Read-FileShared $t.OutFile) -match 'Starting package install|Installing') { $installing = $true }
            if ($t.TotalBytes -gt 0) {
                if ($staged -ge $t.TotalBytes * 0.98) { $installing = $true }
                elseif ($it) { $it.Pct = [math]::Min(0.99, $staged / $t.TotalBytes) }
            }
            if ($installing) { $t.State = 'install'; if ($it) { $it.State = 'install' } }
        }
    }
    $dt = ($now - $script:UI.LastTick).TotalSeconds
    if ($dt -ge 0.4) {
        $delta = $total - $script:UI.LastBytes
        if ($delta -lt 0) { $delta = 0 }
        $script:UI.Speed = $delta / $dt
        $script:UI.LastBytes = $total
        $script:UI.LastTick = $now
    }
}

# Where an installed app lives, so its locked files can be found by name. Many
# apps leave InstallLocation blank (OBS does), so fall back to the folder the
# uninstaller sits in, which for NSIS/Inno installers is the install root.
function Get-InstallLocation([string]$Name) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $short = ($Name -replace '\s*\(.*\)\s*$', '').Trim()
    $cands = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*$short*" } | Sort-Object { $_.DisplayName.Length })

    foreach ($c in $cands) {
        if ($c.InstallLocation) {
            $d = ([string]$c.InstallLocation).Trim('"').TrimEnd('\')
            if ($d -and (Test-Path $d)) { return $d }
        }
    }
    foreach ($c in $cands) {
        foreach ($src in @($c.UninstallString, $c.DisplayIcon)) {
            if (-not $src) { continue }
            $p = [string]$src
            if ($p -match '^"([^"]+)"') { $p = $Matches[1] } elseif ($p -match '^([^\s,]+\.exe)') { $p = $Matches[1] }
            $p = ($p -replace ',\s*-?\d+\s*$', '').Trim('"')
            if ($p -match '(?i)msiexec') { continue }
            $dir = $null; try { $dir = Split-Path $p -Parent } catch {}
            if ($dir -and (Test-Path $dir) -and $dir -notmatch '(?i)\\Windows(\\|$)|\\system32') { return $dir.TrimEnd('\') }
        }
    }
    $null
}

# winget could not replace a file because another process has it open. Find out
# whether the app itself is running, and which other processes hold its files,
# so the hand-off can name exactly what to close. Renaming the files aside does
# NOT help: installers use the Windows Restart Manager, which still sees the
# module loaded in the other process (OBS's virtual camera, loaded by Chrome and
# Claude whenever they list cameras, is the classic case) and refuses either way.
function Get-InUseHolders([string]$Name) {
    $dir = Get-InstallLocation $Name
    $info = @{ Dir = $dir; AppRunning = $false; Holders = @() }
    if (-not $dir) { return $info }
    if (@(Get-Process | Where-Object { $_.Path -and $_.Path -like "$dir\*" }).Count -gt 0) { $info.AppRunning = $true }
    $holders = @{}
    foreach ($p in Get-Process) {
        try {
            foreach ($m in $p.Modules) { if ($m.FileName -like "$dir\*") { $holders[$p.ProcessName] = $true; break } }
        } catch {}
    }
    $info.Holders = @($holders.Keys | Sort-Object)
    $info
}

# Is the app really on the disk? Goes by where Windows says its uninstaller is:
# $false only when Windows has such a path for the app and nothing is there.
# Used for apps whose version winget cannot read, where "Successfully installed"
# is all there is to go on. Iriun Webcam's 2.9.9 installer reported success on
# 2026-11-01 and deleted its own program folder in the same second; the app was
# simply gone for two weeks and nothing noticed.
function Test-AppFilesPresent([string]$Name) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $short = ($Name -replace '\s*\(.*\)\s*$', '').Trim().TrimEnd([char]0x2026)
    if (-not $short) { return $true }
    $found = 0; $missing = 0
    foreach ($entry in @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "$short*" })) {
        $path = [string]$entry.UninstallString
        if ($path -match '^"([^"]+)"') { $path = $Matches[1] } elseif ($path -match '^(.+?\.exe)') { $path = $Matches[1] }
        if (-not $path -or $path -match '(?i)msiexec' -or -not [IO.Path]::IsPathRooted($path)) { continue }
        $found++
        if (-not (Test-Path -LiteralPath $path)) { $missing++ }
    }
    -not ($found -gt 0 -and $missing -eq $found)
}

# Looks at a finished winget process and decides what happened. Returns one of
# ok / unchanged / failed, or retry-mutex / retry-missing for the scheduler.
function Complete-WingetTask($t) {
    $output = (Read-FileShared $t.OutFile) + (Read-FileShared $t.ErrFile)
    Add-Content -Path $LogFile -Value (Format-NativeOutput $output) -Encoding utf8
    $exit = $t.Proc.ExitCode
    Remove-Item $t.OutFile, $t.ErrFile -ErrorAction SilentlyContinue

    if ($exit -eq 0) {
        # winget's word is not enough: a package can be labelled newer than the installer it
        # downloads (VS Code "1.142.0" fetched the 1.141.2 installer on 2026-10-19).
        $now = Get-WingetInstalledVersion $t.Id
        # Windows can list a shorter form of the same version: MEGAsync is "6.7.0" there and
        # "6.7.0.3" in winget, and 6.7.0 is what MEGA itself calls current. The number cannot
        # move in that case, so it is not evidence that nothing was installed.
        $sameRelease = $now -and $t.Available.StartsWith("$now.")
        if ($sameRelease) {
            Write-Log ('  {0}: Windows lists {1} for what winget calls {2}; it is the same release.' -f $t.Name, $now, $t.Available)
        }
        # With no version to read, at least make sure the program is there.
        if ((-not $now -or $now -eq 'Unknown') -and -not (Test-AppFilesPresent $t.Name)) {
            if ($t.Tries -lt 1) {
                Write-Log ('  winget reported success, but the program files of {0} are missing. Installing it again.' -f $t.Name) 'WARN'
                return 'retry-missing'
            }
            Write-Log ('  FAILED: {0} was installed twice and its program files are still missing.' -f $t.Name) 'ERROR'
            Set-Item -Key $t.Id -State 'failed' -Note 'installer leaves no program files'
            Add-Handoff -Source 'winget' -Name $t.Name -Id $t.Id -Reason 'winget reports success, but the installer leaves no program files behind' `
                -Suggestion 'Download the installer from the publisher and run it by hand, then check the app starts.' `
                -Detail ('{0} -> {1}' -f $t.Version, $t.Available)
            return 'failed'
        }
        if ($now -and $t.Version -match '^\d' -and $now -eq $t.Version -and -not $sameRelease) {
            Write-Log ('  winget reported success, but {0} is still on {1}.' -f $t.Name, $now) 'WARN'
            Save-NoChange -Id $t.Id -Version $t.Available
            Set-Item -Key $t.Id -State 'skip' -Note ('still {0} (winget package mislabelled)' -f $now)
            Add-Handoff -Source 'this run' -Name $t.Name -Id $t.Id `
                -Reason ('winget reported success but it is still on {0}; its package for {1} installs an older build' -f $now, $t.Available) `
                -Suggestion 'Nothing to fix here. It is usually corrected in winget within days, and the next run retries. VS Code and browsers also update themselves when opened.'
            return 'unchanged'
        }
        Save-InstalledVersion -Id $t.Id -Version $t.Available
        Write-Log ('  OK: {0}  {1}' -f $t.Name, $t.Available) 'OK'
        Set-Item -Key $t.Id -State 'done' -Note $t.Available
        return 'ok'
    }

    # Two installs reached the Windows Installer lock at once: wait and retry.
    if (($output -match 'another (package )?installation is (already )?in progress|0x80070642|\b1618\b') -and $t.Tries -lt 3) {
        Write-Log ('  {0}: the Windows Installer was busy; will retry.' -f $t.Name)
        return 'retry-mutex'
    }

    # A file is open in another app. Say which, so the user knows what to close;
    # we never update underneath a running app or move its files aside.
    if ($output -match 'in use|currently (in use|running)|being used|modified by the installer are currently') {
        $info = Get-InUseHolders $t.Name
        if ($info.AppRunning) {
            Write-Log ('  {0} is running, so it was left alone.' -f $t.Name) 'WARN'
            Set-Item -Key $t.Id -State 'skip' -Note 'the app is running'
            Add-Handoff -Source 'this run' -Name $t.Name -Id $t.Id -Reason 'the app was running during the update' `
                -Suggestion 'Close it and rerun the bot; it updates in place once the app is closed.' `
                -Detail ('{0} -> {1}' -f $t.Version, $t.Available)
            return 'failed'
        }
        $who = 'another app'
        if ($info.Holders.Count -gt 0) { $who = ($info.Holders -join ', ') }
        Write-Log ('  {0} could not be replaced; its files are in use by: {1}.' -f $t.Name, $who) 'WARN'
        Set-Item -Key $t.Id -State 'skip' -Note ('in use by {0}' -f $who)
        Add-Handoff -Source 'this run' -Name $t.Name -Id $t.Id `
            -Reason ('its files are open in {0}, so the installer could not replace them' -f $who) `
            -Suggestion ('Close {0} (or reboot) and run the bot again - it installs in place once the files are free. A scheduled run when those apps are closed also catches it.' -f $who) `
            -Detail ('{0} -> {1}' -f $t.Version, $t.Available)
        return 'failed'
    }

    $reason = Get-FailureReason -Output $output -ExitCode $exit
    Write-Log ('  FAILED (exit {0}): {1}' -f $exit, $t.Name) 'ERROR'
    Set-Item -Key $t.Id -State 'failed' -Note $reason
    Add-Handoff -Source 'winget' -Name $t.Name -Id $t.Id -Reason $reason `
        -Suggestion 'Ask Claude to find a working installer, or wait for the winget manifest to be fixed.' `
        -Detail ('{0} -> {1}' -f $t.Version, $t.Available)
    return 'failed'
}

# Runs a list of winget tasks, up to MaxParallel at once, one serial-lane task
# at a time. Returns a count of ok / failed / unchanged.
function Invoke-WingetBatch($Tasks, [int]$Max = 3) {
    $result = @{ ok = 0; failed = 0; unchanged = 0 }
    $tasks = @($Tasks)
    if ($tasks.Count -eq 0) { return $result }
    if ($Max -lt 1) { $Max = 1 }

    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($t in $tasks) { $queue.Enqueue($t) }
    $running = New-Object System.Collections.Generic.List[object]
    $retryAt = @{}

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        # Fill free slots with whatever may start now.
        while ($running.Count -lt $Max -and $queue.Count -gt 0) {
            $cand = $null
            $serialRunning = @($running | Where-Object { $_.Serial }).Count
            for ($k = 0; $k -lt $queue.Count; $k++) {
                $x = $queue.Dequeue()
                $held = $retryAt.ContainsKey($x.Id) -and (Get-Date) -lt $retryAt[$x.Id]
                if (-not $held -and (-not $x.Serial -or $serialRunning -eq 0)) { $cand = $x; break }
                $queue.Enqueue($x)
            }
            if (-not $cand) { break }
            Start-WingetTask $cand
            $running.Add($cand)
            if ($cand.Serial) { break }   # re-evaluate before starting another serial task
        }

        Update-TaskProgress $running

        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $t = $running[$i]
            if (-not $t.Proc.HasExited) { continue }
            $r = Complete-WingetTask $t
            $running.RemoveAt($i)
            switch ($r) {
                'ok'          { $result.ok++;        $script:UI.Done++ }
                'unchanged'   { $result.unchanged++; $script:UI.Done++ }
                'failed'      { $result.failed++;    $script:UI.Done++ }
                'retry-mutex'   { $t.Tries++; $retryAt[$t.Id] = (Get-Date).AddSeconds(6); $t.State = 'queued'; $queue.Enqueue($t) }
                'retry-missing' { $t.Tries++; $t.Force = $true; $t.State = 'queued'; $queue.Enqueue($t) }
            }
        }

        Show-Status
        Start-Sleep -Milliseconds $script:TickMs
    }
    $result
}

# --- Apps winget cannot link to its package ($Adopt) -------------------------
function Get-InstalledEntries([string]$NamePattern) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $NamePattern -and -not $_.SystemComponent } |
        ForEach-Object { [pscustomobject]@{ Name = [string]$_.DisplayName; Version = [string]$_.DisplayVersion } })
}

function ConvertTo-VersionOrNull([string]$Text) {
    $match = [regex]::Match($Text, '\d+(\.\d+){1,3}')
    if ($match.Success) { try { return [version]$match.Value } catch {} }
    $null
}

function Update-AdoptedApps {
    $script:AdoptedOk = 0; $script:AdoptedFailed = 0
    foreach ($id in $Adopt.Keys) {
        $before = @(Get-InstalledEntries $Adopt[$id])
        if ($before.Count -eq 0) { continue }                       # not installed
        # Two generations can be installed side by side (LTspice XVII and LTspice): name the newest.
        $name = ($before | Sort-Object { ConvertTo-VersionOrNull $_.Version } | Select-Object -Last 1).Name

        $show = Invoke-Animated -File $script:Winget -TimeoutSec 120 -Arguments @(
            'show', '--id', $id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
        $latestText = [regex]::Match($show.Output, '(?m)^Version:\s*(.+)$').Groups[1].Value.Trim()
        $latest     = ConvertTo-VersionOrNull $latestText
        if (-not $latest) {
            Write-Log ('Could not get the latest version of {0} ({1}) from winget.' -f $name, $id) 'WARN'
            continue
        }

        # Some installers record no version at all; for those, go by what this script last installed.
        $have = $before | ForEach-Object { ConvertTo-VersionOrNull $_.Version } | Where-Object { $_ } | Sort-Object | Select-Object -Last 1
        $memo = Get-InstalledMemo
        if (($have -and $have -ge $latest) -or (-not $have -and $memo[$id] -eq $latestText)) {
            Write-Log ('{0} is up to date ({1}).' -f $name, $latestText) 'OK'
            continue
        }
        $from = 'an unrecorded version'
        if ($have) { $from = [string]$have }
        if ($DryRun) {
            Write-Log ('Would update {0} from {1} to {2}.' -f $name, $from, $latestText)
            continue
        }

        Set-Phase ('Updating {0}' -f $name)
        Write-Log ('Updating {0} from {1} to {2} ...' -f $name, $from, $latestText)
        $run = Invoke-Animated -File $script:Winget -Arguments @(
            'install', '--id', $id, '--exact', '--silent', '--force',
            '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        Add-Content -Path $LogFile -Value (Format-NativeOutput $run.Output) -Encoding utf8

        $after = @(Get-InstalledEntries $Adopt[$id])
        $now   = $after | ForEach-Object { ConvertTo-VersionOrNull $_.Version } | Where-Object { $_ } | Sort-Object | Select-Object -Last 1
        if ($run.ExitCode -eq 0 -and (-not $now -or $now -ge $latest)) {
            Save-InstalledVersion -Id $id -Version $latestText
            $script:AdoptedOk++
            Write-Log ('  OK: {0} is now on {1}' -f ($name -replace '\s+[\d.]+$', ''), $latestText) 'OK'
            Add-Row $Glyph.Ok ('{0}  {1}' -f ($name -replace '\s+[\d.]+$', ''), $latestText) 'Green'
            if ($after.Count -gt $before.Count) {
                Add-Handoff -Source 'winget' -Name $name -Id $id -Reason 'the new version was installed beside the old one instead of replacing it' `
                    -Suggestion 'Check both copies work, then remove the older one with its own uninstaller.' `
                    -Detail (($after | ForEach-Object { '{0} {1}' -f $_.Name, $_.Version }) -join '; ')
            }
        } else {
            $reason = Get-FailureReason -Output $run.Output -ExitCode $run.ExitCode
            $script:AdoptedFailed++
            Write-Log ('  FAILED (exit {0}): {1}' -f $run.ExitCode, $name) 'ERROR'
            Add-Row $Glyph.Fail ('{0}  ({1})' -f $name, $reason) 'Red'
            Add-Handoff -Source 'winget' -Name $name -Id $id -Reason $reason `
                -Suggestion 'Close the app if it is open and rerun the bot. It is updated with: winget install --id <id> --exact --silent --force' `
                -Detail ('{0} -> {1}' -f $from, $latestText)
        }
    }
}

# --- Apps that update themselves ---------------------------------------------
# Many apps bring their own updater as a scheduled task (Zoom, OneDrive, Office,
# MEGA, PDF-XChange ...). Running those tasks makes each one check right now.
function Start-VendorUpdaters {
    Set-Phase 'Asking apps to check for their own updates'
    $own = Split-Path $PSCommandPath -Leaf
    $tasks = @(Get-ScheduledTask | Where-Object {
        ($_.TaskName + $_.TaskPath + (($_.Actions | ForEach-Object { $_.Execute; $_.Arguments }) -join ' ')) -notmatch '(?i)riot|leagueoflegends|teamfight' -and
        $_.State -eq 'Ready' -and $_.TaskPath -notlike '\Microsoft\Windows\*' -and
        ($_.TaskName -match 'Updat' -or (($_.Actions | ForEach-Object { $_.Execute }) -join ' ') -match 'Updat') -and
        (($_.Actions | ForEach-Object { $_.Arguments }) -join ' ') -notlike "*$own*" -and
        # Only the ones meant to run on a timer; a task that waits for an event may open a window.
        ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Daily|Weekly|Time' })
    })
    # "BraveSoftwareUpdateTaskMachineUA{3AF4...}" and "ZoomUpdateTaskUser-S-1-5-21-..." read better as "BraveSoftwareUpdate" and "ZoomUpdate".
    $names = @($tasks | ForEach-Object {
        $_.TaskName -replace '\{[0-9A-Fa-f-]{36}\}', '' -replace '[-_ ]*S-1-5-[\d-]+$', '' -replace '\d+(\.\d+){2,}', '' -replace 'Task(Machine|User|System)?(Core|UA)?$', '' -replace '\s*Task\s*$', ''
    } | Select-Object -Unique)
    if ($tasks.Count -eq 0) { return }
    if ($DryRun) {
        Write-Log ('Would ask {0} app updater(s) to check now: {1}.' -f $tasks.Count, ($names -join ', '))
        return
    }
    $started = 0
    foreach ($task in $tasks) {
        try { Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop; $started++ } catch {}
    }
    Write-Log ('Asked {0} app updater(s) to check now: {1}.' -f $started, ($names -join ', ')) 'OK'
    Add-Row $Glyph.Ok ('App updaters checked  ({0})' -f $started) 'Green'
}

# Discord, the NVIDIA driver and Steam are not winget's to update:
# each has its own updater. This section checks each one against its publisher
# and gives it a push when it has fallen behind.

# Starts a program as the normal user. This script runs as administrator, and a
# program started directly from it would run as administrator too. Opening a
# shortcut through the desktop shell avoids that.
function Start-AsUser {
    param([string]$Name, [string]$Target, [string]$Arguments = '')
    $folder = Join-Path $LogDir 'launchers'
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $path = Join-Path $folder "$Name.lnk"
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $link.TargetPath = $Target
    $link.Arguments = $Arguments
    $link.WorkingDirectory = Split-Path $Target
    $link.WindowStyle = 7
    $link.Save()
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $path)
}

function Test-Running([string]$Name) { [bool](Get-Process | Where-Object { $_.Name -eq $Name }) }

# Keeps the status block moving while waiting on something outside this script.
function Wait-Animated([int]$Seconds) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) { Show-Status; Start-Sleep -Milliseconds $script:TickMs }
}

# Discord updates itself each time it starts.
function Test-DiscordUpdate {
    $root    = Join-Path $env:LOCALAPPDATA 'Discord'
    $updater = Join-Path $root 'Update.exe'
    if (-not (Test-Path $updater)) { return }
    Set-Phase 'Checking Discord'

    $installed = Get-ChildItem $root -Directory -Filter 'app-*' |
        ForEach-Object { [version]($_.Name -replace '^app-', '') } | Sort-Object | Select-Object -Last 1
    $latest = $null
    try {
        $manifest = Invoke-RestMethod -TimeoutSec 20 -Uri 'https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=win&arch=x64'
        $latest = [version]($manifest.full.host_version -join '.')
    } catch {}

    if (-not $installed -or -not $latest) {
        Write-Log 'Could not compare Discord with its latest release.' 'WARN'
        Add-Row $Glyph.Skip 'Discord  (could not check)' 'DarkYellow'
    } elseif ($installed -ge $latest) {
        Write-Log ('Discord {0} is the latest.' -f $installed) 'OK'
        Add-Row $Glyph.Ok ('Discord  {0}' -f $installed) 'Green'
    } elseif (Test-Running 'Discord') {
        # Discord has the update ready and swaps to it the next time it starts.
        Write-Log ('Discord {0} is running; {1} installs when Discord next restarts.' -f $installed, $latest)
        Add-Row $Glyph.Info ('Discord  ({0} installs when it restarts)' -f $latest) 'Yellow'
    } elseif ($DryRun) {
        Write-Log ('Would start Discord so it updates itself to {0}.' -f $latest)
    } else {
        Start-AsUser 'Start Discord quietly' $updater '--processStart Discord.exe --process-start-args "--start-inactive"'
        Write-Log ('Started Discord in the tray so it updates itself from {0} to {1}.' -f $installed, $latest) 'OK'
        Add-Row $Glyph.Ok ('Discord  (started, updating itself to {0})' -f $latest) 'Green'
    }
}

function Get-NvidiaLatest([string]$GpuName) {
    # The catalogue is keyed by series id and product id. Find them by name once and remember them.
    $cacheFile = Join-Path $LogDir 'nvidia-product.json'
    $ids = $null
    if (Test-Path $cacheFile) {
        try { $saved = Get-Content $cacheFile -Raw | ConvertFrom-Json; if ($saved.gpu -eq $GpuName) { $ids = $saved } } catch {}
    }
    if (-not $ids) {
        $lookup  = 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx'
        $pattern = '<Name>([^<]*)</Name>\s*<Value>(\d+)</Value>'
        $page    = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri ($lookup + '?TypeID=2&ParentID=1')).Content
        $series  = @([regex]::Matches($page, $pattern) | ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Id = $_.Groups[2].Value } } |
            Where-Object { $_.Name -notmatch 'Notebook' })

        # Try the likeliest series first: an "RTX 5060" belongs to the "RTX 50 Series".
        $hint = ''
        if ($GpuName -match '(RTX|GTX|GT)\s*(\d{2})\d{2}') { $hint = '{0} {1} Series' -f $Matches[1], $Matches[2] }
        $ordered = @($series | Where-Object { $hint -and $_.Name -like "*$hint*" }) + @($series | Where-Object { -not ($hint -and $_.Name -like "*$hint*") })

        foreach ($one in $ordered | Select-Object -First 12) {
            $page  = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri ($lookup + '?TypeID=3&ParentID=' + $one.Id)).Content
            $match = [regex]::Matches($page, $pattern) | Where-Object {
                $name = $_.Groups[1].Value
                $name -eq $GpuName -or "NVIDIA $name" -eq $GpuName
            } | Select-Object -First 1
            if ($match) { $ids = [pscustomobject]@{ gpu = $GpuName; psid = $one.Id; pfid = $match.Groups[2].Value }; break }
        }
        if (-not $ids) { return $null }
        $ids | ConvertTo-Json | Set-Content -Path $cacheFile -Encoding utf8
    }

    $os = 57                                                         # Windows 10
    if ([Environment]::OSVersion.Version.Build -ge 22000) { $os = 135 }   # Windows 11
    $query = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup' +
             "&psid=$($ids.psid)&pfid=$($ids.pfid)&osID=$os&languageCode=1033&beta=0&isWHQL=0&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=1&numberOfResults=1"
    $info = (Invoke-RestMethod -TimeoutSec 30 -Uri $query).IDS[0].downloadInfo
    [pscustomobject]@{
        Version  = [string]$info.Version
        Released = [datetime]::ParseExact([string]$info.ReleaseDateTime, 'ddd MMM dd, yyyy', [Globalization.CultureInfo]::InvariantCulture)
        Url      = [string]$info.DownloadURL
        Size     = [string]$info.DownloadURLFileSize
    }
}

function Get-NvidiaInstalled {
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if (-not $gpu) { return $null }
    # Windows reports 32.0.16.1742 for what NVIDIA calls 617.42: it is the last five digits.
    $digits = $gpu.DriverVersion -replace '\D', ''
    [pscustomobject]@{ Name = $gpu.Name; Version = '{0}.{1}' -f $digits.Substring($digits.Length - 5, 3), $digits.Substring($digits.Length - 2) }
}

# Installs a new NVIDIA driver from NVIDIA's own server, once it is a few days old,
# and only while nothing is using the graphics card.
function Update-NvidiaDriver {
    $gpu = Get-NvidiaInstalled
    if (-not $gpu) { return }
    Set-Phase 'Checking the NVIDIA driver'

    $latest = $null
    try { $latest = Get-NvidiaLatest $gpu.Name } catch {}
    if (-not $latest -or -not $latest.Version) {
        Write-Log 'Could not get the latest NVIDIA driver version from NVIDIA.' 'WARN'
        Add-Row $Glyph.Skip 'NVIDIA driver  (could not check)' 'DarkYellow'
        return
    }

    $newer = ([version]$latest.Version) -gt ([version]$gpu.Version)
    if (-not $newer -and -not $ReinstallNvidia) {
        Write-Log ('NVIDIA driver {0} is the latest.' -f $gpu.Version) 'OK'
        Add-Row $Glyph.Ok ('NVIDIA driver  {0}' -f $gpu.Version) 'Green'
        return
    }

    $age = [int][math]::Floor(((Get-Date) - $latest.Released).TotalDays)
    if ($newer -and $age -lt $NvidiaMinAgeDays) {
        Write-Log ('NVIDIA driver {0} came out {1} day(s) ago. It is installed once it has been out {2} days.' -f $latest.Version, $age, $NvidiaMinAgeDays)
        Add-Row $Glyph.Info ('NVIDIA driver  ({0} is new; waiting until it is {1} days old)' -f $latest.Version, $NvidiaMinAgeDays) 'Yellow'
        return
    }
    if ($DryRun) {
        Write-Log ('Would install NVIDIA driver {0} ({1}), replacing {2}.' -f $latest.Version, $latest.Size, $gpu.Version)
        return
    }
    if (-not $isAdmin) {
        Write-Log ('NVIDIA driver {0} is available, but installing it needs an elevated run.' -f $latest.Version) 'WARN'
        return
    }

    # Never in the middle of a game: the screen blanks while the driver is swapped.
    $load = 0
    try {
        $load = ((Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop).CounterSamples |
            Measure-Object CookedValue -Sum).Sum / 3
    } catch {}
    if ($load -gt $NvidiaMaxGpuPercent) {
        Write-Log ('NVIDIA driver {0} is available, but the graphics card is busy ({1:N0}%). Trying again on the next run.' -f $latest.Version, $load)
        Add-Row $Glyph.Info ('NVIDIA driver  ({0} waiting: a game is running)' -f $latest.Version) 'Yellow'
        return
    }

    $address = [uri]$latest.Url
    if ($address.Scheme -ne 'https' -or $address.Host -notlike '*.download.nvidia.com') {
        Add-Row $Glyph.Fail 'NVIDIA driver  (unexpected download address)' 'Red'
        Add-Handoff -Source 'NVIDIA' -Name ('Driver {0}' -f $latest.Version) -Reason 'the download address is not on NVIDIA''s download server' `
            -Suggestion 'Do not download it. Check the address in the log; install through the NVIDIA App if it looks wrong.' -Detail $latest.Url
        return
    }

    $folder = Join-Path $LogDir 'nvidia'
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $package = Join-Path $folder (Split-Path $address.AbsolutePath -Leaf)

    Set-Phase ('Downloading NVIDIA driver {0} ({1})' -f $latest.Version, $latest.Size)
    Write-Log ('Downloading NVIDIA driver {0} from {1} ...' -f $latest.Version, $latest.Url)
    $download = Invoke-Animated -File (Join-Path $env:SystemRoot 'System32\curl.exe') -TimeoutSec 3600 -Arguments @(
        '--location', '--fail', '--silent', '--show-error', '--output', ('"{0}"' -f $package), $latest.Url)
    if ($download.ExitCode -ne 0 -or -not (Test-Path $package)) {
        Write-Log ('  Download failed (curl exit {0}): {1}' -f $download.ExitCode, $download.Output.Trim()) 'ERROR'
        Add-Row $Glyph.Fail ('NVIDIA driver  ({0} download failed)' -f $latest.Version) 'Red'
        Add-Handoff -Source 'NVIDIA' -Name ('Driver {0}' -f $latest.Version) -Reason 'the download failed' `
            -Suggestion 'Usually temporary. Rerun the bot; do not download the driver any other way.' -Detail $latest.Url
        return
    }

    # Only run it if NVIDIA signed it.
    $signature = Get-AuthenticodeSignature -FilePath $package
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=NVIDIA Corporation') {
        Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
        Write-Log ('  The downloaded file is not signed by NVIDIA (status {0}). It was deleted, not run.' -f $signature.Status) 'ERROR'
        Add-Row $Glyph.Fail 'NVIDIA driver  (signature check failed)' 'Red'
        Add-Handoff -Source 'NVIDIA' -Name ('Driver {0}' -f $latest.Version) -Reason 'the downloaded file was not signed by NVIDIA, so it was deleted' `
            -Suggestion 'Do not retry by other means. Report it to the user.' -Detail $latest.Url
        return
    }

    Set-Phase ('Installing NVIDIA driver {0} (the screen may flicker)' -f $latest.Version)
    Write-Log ('Installing NVIDIA driver {0} over {1} ...' -f $latest.Version, $gpu.Version)
    $day     = Get-Date -Format 'yyyyMMdd'
    $install = Invoke-Animated -File $package -Arguments @('-s', '-noreboot', '-noeula') -TimeoutSec 2400
    Wait-Animated 8

    # Go by what is installed, not by the installer's exit code: NVIDIA's installer can
    # return an error (seen: 0x80070005) after the driver itself has gone in cleanly.
    $now        = (Get-NvidiaInstalled).Version
    $registered = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'NVIDIA Graphics Driver*' } | Select-Object -First 1).InstallDate
    $healthy    = [bool](Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'NVIDIA' -and $_.Status -eq 'OK' })

    if ($now -eq $latest.Version -and $registered -ge $day -and $healthy -and -not $install.TimedOut) {
        Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
        Write-Log ('  OK: NVIDIA driver is now {0}, installed today, and the card reports OK (installer exit {1}).' -f $now, $install.ExitCode) 'OK'
        Add-Row $Glyph.Ok ('NVIDIA driver  {0}' -f $now) 'Green'
        if ($install.ExitCode -eq 1) {
            Add-Handoff -Source 'this run' -Name 'Restart needed' -Reason 'the NVIDIA driver finishes installing at the next restart' `
                -Suggestion 'Restart the PC when convenient. Nothing restarts it automatically.'
        }
    } else {
        $note = 'installer exit {0}; the driver is on {1}, last installed {2}, card healthy: {3}' -f $install.ExitCode, $now, $registered, $healthy
        if ($install.TimedOut) { $note = 'the installer did not finish in 40 minutes and was stopped; the driver is on {0}' -f $now }
        Write-Log ('  FAILED: {0}.' -f $note) 'ERROR'
        Add-Row $Glyph.Fail ('NVIDIA driver  ({0} did not install)' -f $latest.Version) 'Red'
        Add-Handoff -Source 'NVIDIA' -Name ('Driver {0}' -f $latest.Version) -Reason $note `
            -Suggestion ('The signed installer is kept at {0}. Check Device Manager shows the card working, then rerun the bot.' -f $package)
    }
}

# --- Steam ---
function Get-SteamApps([string]$SteamRoot) {
    $libraries = @(Join-Path $SteamRoot 'steamapps')
    $index = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path $index) {
        $libraries = @([regex]::Matches([IO.File]::ReadAllText($index), '"path"\s+"([^"]+)"') |
            ForEach-Object { Join-Path ($_.Groups[1].Value -replace '\\\\', '\') 'steamapps' })
    }
    foreach ($library in $libraries | Select-Object -Unique) {
        foreach ($file in Get-ChildItem $library -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $text = [IO.File]::ReadAllText($file.FullName)
            [pscustomobject]@{
                File       = $file.FullName
                Id         = [regex]::Match($text, '"appid"\s+"(\d+)"').Groups[1].Value
                Name       = [regex]::Match($text, '"name"\s+"([^"]+)"').Groups[1].Value
                State      = [int][regex]::Match($text, '"StateFlags"\s+"(\d+)"').Groups[1].Value
                AutoUpdate = [regex]::Match($text, '"AutoUpdateBehavior"\s+"(\d+)"').Groups[1].Value
                Scheduled  = [int64]('0' + [regex]::Match($text, '"ScheduledAutoUpdate"\s+"(\d+)"').Groups[1].Value)   # Unix time Steam plans to update at; 0 = not put off
                Folder     = Join-Path $library ('common\' + [regex]::Match($text, '"installdir"\s+"([^"]+)"').Groups[1].Value)
            }
        }
    }
}

# 0 = always keep updated, 1 = update only when launched, 2 = update before other games.
function Set-SteamAutoUpdate([string]$File, [string]$Value) {
    $text = [IO.File]::ReadAllText($File)
    $new  = [regex]::Replace($text, '("AutoUpdateBehavior"\s+")\d+(")', ('${1}' + $Value + '${2}'))
    if ($new -ne $text) { [IO.File]::WriteAllText($File, $new) }      # UTF-8 without a signature, as Steam writes it
}

function Restore-SteamHold([string]$HoldFile) {
    $held = @()
    try { $held = @((Get-Content $HoldFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) } catch {}
    foreach ($item in $held) {
        if (Test-Path $item.file) { Set-SteamAutoUpdate $item.file ([string]$item.original) }
    }
    Remove-Item -LiteralPath $HoldFile -Force -ErrorAction SilentlyContinue
    $held.Count
}

function Get-SteamClientVersion([string]$SteamRoot) {
    $manifest = Join-Path $SteamRoot 'package\steam_client_win64.manifest'
    if (Test-Path $manifest) { return [regex]::Match([IO.File]::ReadAllText($manifest), '"version"\s+"(\d+)"').Groups[1].Value }
    (Get-Item (Join-Path $SteamRoot 'steam.exe')).VersionInfo.FileVersion
}

# Steam updates itself and its apps only while it is running. When it is closed,
# start it for a few minutes so Steam and the apps in $SteamKeepUpdated update,
# with every other game held back, then close it again.
function Update-SteamQuietly {
    $steamExe = [string](Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamExe
    if (-not $steamExe) { $steamExe = Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe' }
    $steamExe = $steamExe -replace '/', '\'
    if (-not (Test-Path $steamExe)) { return }
    $root     = Split-Path $steamExe
    $holdFile = Join-Path $LogDir 'steam-held.json'
    $script:SteamReopen = @()
    Set-Phase 'Checking Steam'

    # A run that died while games were held would leave them on "update only when launched".
    if ((Test-Path $holdFile) -and -not (Test-Running 'steam')) {
        $count = Restore-SteamHold $holdFile
        Write-Log ('Gave {0} Steam game(s) their own update setting back after an interrupted run.' -f $count) 'WARN'
    }

    $apps     = @(Get-SteamApps $root)
    $keepList = (@($apps | Where-Object { $SteamKeepUpdated -contains $_.Id }) | ForEach-Object { $_.Name }) -join ', '

    if (Test-Running 'steam') {
        Write-Log 'Steam is running, so it is keeping itself and its apps updated.' 'OK'
        Add-Row $Glyph.Ok 'Steam  (running)' 'Green'
        return
    }
    if ($DryRun) {
        Write-Log ('Would start Steam for a few minutes to update Steam itself and: {0}.' -f $keepList)
        return
    }

    # Hold every other game back, so starting Steam does not pull down their patches.
    $held = @($apps | Where-Object { $SteamKeepUpdated -notcontains $_.Id -and $_.AutoUpdate -ne '1' -and $_.AutoUpdate -ne '' } |
        ForEach-Object { [pscustomobject]@{ file = $_.File; name = $_.Name; original = $_.AutoUpdate } })
    ConvertTo-Json -InputObject $held | Set-Content -Path $holdFile -Encoding utf8     # recorded first, so it can always be undone
    foreach ($item in $held) { Set-SteamAutoUpdate $item.file '1' }

    $before = Get-SteamClientVersion $root
    Set-Phase 'Updating Steam'
    Write-Log ('Steam was closed. Starting it to update Steam itself and: {0}. Held back: {1}.' -f $keepList, (($held | ForEach-Object { $_.name }) -join ', '))
    Start-AsUser 'Start Steam quietly' $steamExe '-silent'

    # Steam updates itself before its main window process appears. After that, wait for the kept apps.
    $deadline = (Get-Date).AddMinutes(25)
    $readyAt  = $null
    $closed   = @()
    $asked    = @{}      # app id -> when Steam was asked to start it
    $putOff   = @{}      # app id -> the date Steam has scheduled its update for
    while ((Get-Date) -lt $deadline) {
        Wait-Animated 3
        if (-not $readyAt) {
            if (Test-Running 'steamwebhelper') { $readyAt = (Get-Date).AddSeconds(60) }     # signed in and settled
            continue
        }
        if ((Get-Date) -lt $readyAt) { continue }

        $behind = @(Get-SteamApps $root | Where-Object { $SteamKeepUpdated -contains $_.Id -and $_.State -ne 4 })
        if ($behind.Count -eq 0) { break }

        $nowUnix = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $waiting = 0
        foreach ($app in $behind) {
            $running = @(Get-Process | Where-Object { $_.Path -and $_.Path -like ($app.Folder + '\*') })

            # Steam spaces out the updates of apps it thinks are rarely played, sometimes by more
            # than a week (seen 2026-10-25). Wallpaper Engine starts with Windows rather than through
            # Steam, so Steam counts it as never played. Waiting does nothing for an update that has
            # been put off; starting the app through Steam makes Steam update it first.
            if ($app.Scheduled -gt ($nowUnix + 300)) {
                $when = [DateTimeOffset]::FromUnixTimeSeconds($app.Scheduled).LocalDateTime.ToString('d MMM')
                if ($asked.ContainsKey($app.Id)) {
                    if (((Get-Date) - $asked[$app.Id]).TotalSeconds -lt 180) { $waiting++ } else { $putOff[$app.Id] = $when }
                } elseif ($running.Count -gt 0 -or $closed -contains $app.Name) {
                    # It is normally open, so restarting it through Steam only changes who starts it.
                    if ($running.Count -gt 0) {
                        $running | Stop-Process -Force -ErrorAction SilentlyContinue
                        $closed += $app.Name
                        $script:SteamReopen = @($script:SteamReopen) + @($app.Folder)
                    }
                    Write-Log ('  Steam had put the {0} update off until {1}. Starting {0} through Steam, which makes Steam update it first.' -f $app.Name, $when)
                    Start-AsUser ('Update ' + $app.Name) $steamExe ('steam://rungameid/' + $app.Id)
                    $asked[$app.Id] = Get-Date
                    $waiting++
                } else {
                    $putOff[$app.Id] = $when        # not open: do not start an app the user had closed
                }
                continue
            }

            # Steam cannot replace the files of an app that is running, and Wallpaper Engine always is.
            if ($running.Count -gt 0 -and $closed -notcontains $app.Name) {
                Write-Log ('  Closing {0} so Steam can update it.' -f $app.Name)
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                $closed += $app.Name
                $script:SteamReopen = @($script:SteamReopen) + @($app.Folder)
            }
            $waiting++
        }
        if ($waiting -eq 0) { break }       # everything still behind has been put off by Steam
    }

    # Close the Steam this script started, then give the other games their own setting back.
    Start-AsUser 'Close Steam' $steamExe '-shutdown'
    $until = (Get-Date).AddSeconds(120)
    while ((Test-Running 'steam') -and (Get-Date) -lt $until) { Wait-Animated 2 }
    Wait-Animated 3

    if (Test-Running 'steam') {
        Write-Log 'Steam did not close. Its other games stay held back until the next run puts them right.' 'WARN'
    } else {
        $null = Restore-SteamHold $holdFile
    }

    # Reopen anything closed for its update, the way Windows starts it at sign-in.
    $startup = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    foreach ($folder in @($script:SteamReopen)) {
        if (-not $folder) { continue }
        if (@(Get-Process | Where-Object { $_.Path -and $_.Path -like ($folder + '\*') }).Count -gt 0) { continue }   # Steam already started it
        $entry = $startup.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -like ('*' + $folder + '\*') } | Select-Object -First 1
        if ($entry -and $entry.Value -match '^"([^"]+)"\s*(.*)$') {
            Start-AsUser ('Reopen ' + $entry.Name) $Matches[1] $Matches[2]
            Write-Log ('  Reopened {0}.' -f $entry.Name)
        }
    }

    $after  = Get-SteamClientVersion $root
    $kept   = @(Get-SteamApps $root | Where-Object { $SteamKeepUpdated -contains $_.Id })
    $behind = @($kept | Where-Object { $_.State -ne 4 })
    $client = 'Steam client was already current'
    if ($after -ne $before) { $client = 'Steam client updated ({0} -> {1})' -f $before, $after }
    if (-not $readyAt) {
        Write-Log 'Steam did not finish starting within 25 minutes.' 'WARN'
        Add-Row $Glyph.Skip 'Steam  (did not finish starting)' 'DarkYellow'
    } elseif ($behind.Count -eq 0) {
        Write-Log ('{0}; up to date: {1}.' -f $client, $keepList) 'OK'
        Add-Row $Glyph.Ok ('Steam and {0}' -f $keepList) 'Green'
    } elseif (@($behind | Where-Object { -not $putOff.ContainsKey($_.Id) }).Count -eq 0) {
        $list = ($behind | ForEach-Object { '{0} (Steam plans it for {1})' -f $_.Name, $putOff[$_.Id] }) -join ', '
        Write-Log ('{0}; update put off by Steam: {1}. Steam installs it then, or as soon as the app is started from Steam.' -f $client, $list)
        Add-Row $Glyph.Info ('Steam  (update put off by Steam: {0})' -f (($behind | ForEach-Object { $_.Name }) -join ', ')) 'Yellow'
    } else {
        Write-Log ('{0}; still updating when time ran out: {1}.' -f $client, (($behind | ForEach-Object { $_.Name }) -join ', ')) 'WARN'
        Add-Row $Glyph.Info ('Steam  ({0} not finished)' -f (($behind | ForEach-Object { $_.Name }) -join ', ')) 'Yellow'
    }
}

function Get-SelfUpdaterSteps {
    'Start-VendorUpdaters', 'Test-DiscordUpdate', 'Update-NvidiaDriver', 'Update-SteamQuietly'
    if (Get-Command ollama.exe -ErrorAction Ignore) { 'Update-OllamaModels' }
    if (Get-Service -Name LGHUBUpdaterService -ErrorAction Ignore) { 'Update-GHubService' }
}

function Update-OllamaModels {
    Set-Phase 'Updating installed Ollama models'
    $key = 'ollama-models'
    [void](Add-Item -Key $key -Label 'Ollama models' -State 'running')
    $exe = (Get-Command ollama.exe -ErrorAction Stop).Source
    $list = Invoke-Animated -File $exe -Arguments @('list') -TimeoutSec 60
    if ($list.ExitCode -ne 0 -or $list.TimedOut) {
        Set-Item -Key $key -State 'failed' -Note 'could not list models'
        Write-Log ('Ollama model list failed: {0}' -f (Format-NativeOutput $list.Output)) 'WARN'
        Add-Handoff -Source 'Ollama' -Name 'Installed models' -Reason 'ollama list failed' -Suggestion 'Check the local Ollama server and rerun.'
        return
    }
    $models = @($list.StdOut -split "`r?`n" | Select-Object -Skip 1 | ForEach-Object {
        $name = ($_ -split '\s+')[0]
        if ($name -match '^[A-Za-z0-9][A-Za-z0-9._/:-]*$') { $name }
    } | Select-Object -Unique)
    if ($models.Count -eq 0) {
        Set-Item -Key $key -State 'skip' -Note 'no installed models'
        Write-Log 'Ollama: no installed models to pull.'
        return
    }
    $bad = 0
    foreach ($model in $models) {
        if ($DryRun) { Write-Log ('Would pull Ollama model {0}.' -f $model); continue }
        Write-Log ('Ollama: pulling {0}.' -f $model)
        $run = Invoke-Animated -File $exe -Arguments @('pull', $model) -TimeoutSec 3600
        if ($run.ExitCode -ne 0 -or $run.TimedOut) {
            $bad++
            Write-Log ('Ollama pull {0} failed (exit {1}, timeout {2}): {3}' -f $model, $run.ExitCode, $run.TimedOut, (Format-NativeOutput $run.Output)) 'WARN'
            Add-Handoff -Source 'Ollama' -Name $model -Reason 'model pull failed or timed out' -Suggestion ('Run ollama pull {0} and check server/network access.' -f $model)
        } else { Write-Log ('Ollama: {0} pull completed.' -f $model) 'OK' }
    }
    if ($DryRun) { Set-Item -Key $key -State 'skip' -Note 'dry run' }
    elseif ($bad) { Set-Item -Key $key -State 'failed' -Note ("$bad pull(s) failed") }
    else { Set-Item -Key $key -State 'done' -Note ('{0} model(s) checked' -f $models.Count) }
}

function Update-GHubService {
    Set-Phase 'Checking G HUB background updater'
    $key = 'ghub-updater'
    [void](Add-Item -Key $key -Label 'Logitech G HUB updater' -State 'running')
    try {
        $service = Get-Service -Name LGHUBUpdaterService -ErrorAction Stop
        if ($service.Status -ne 'Running') {
            if ($DryRun) {
                Write-Log 'Would start the G HUB updater service.'
                Set-Item -Key $key -State 'skip' -Note 'dry run'
                return
            }
            Start-Service -Name LGHUBUpdaterService -ErrorAction Stop
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        }
        Write-Log 'G HUB updater service is running; it controls its own update timing. No forced check or completed update is claimed.' 'OK'
        Set-Item -Key $key -State 'done' -Note 'background updater running'
    } catch {
        Write-Log ('G HUB updater service: {0}' -f $_.Exception.Message) 'WARN'
        Set-Item -Key $key -State 'failed' -Note 'service not running'
        Add-Handoff -Source 'G HUB' -Name 'Updater service' -Reason $_.Exception.Message -Suggestion 'Check LGHUBUpdaterService in Services.'
    }
}

function Invoke-SelfUpdaters {
    param([string[]]$Skip = @())      # steps already running alongside as their own process
    foreach ($step in @(Get-SelfUpdaterSteps)) {
        if ($Skip -contains $step) { continue }
        try { & $step }
        catch { Write-Log ('{0} stopped at line {1}: {2}' -f $step, $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) 'WARN' }
        $script:UI.Done++
    }
}

function Update-CodeExtensions {
    Set-Phase 'Updating VS Code extensions'
    if ($DryRun) { Write-Log 'Would update VS Code extensions.'; return }
    $run = Invoke-Animated -File 'cmd.exe' -Arguments @('/c', 'code', '--update-extensions') -TimeoutSec 600
    Add-Content -Path $LogFile -Value (Format-NativeOutput $run.Output) -Encoding utf8
    if ($run.ExitCode -eq 0) {
        Write-Log 'VS Code extensions are up to date.' 'OK'
        Add-Row $Glyph.Ok 'VS Code extensions' 'Green'
    } else {
        Write-Log ('code --update-extensions returned exit {0}.' -f $run.ExitCode) 'WARN'
        Add-Row $Glyph.Fail 'VS Code extensions  (failed)' 'Red'
    }
}

# --- Slow steps that run alongside the app updates ---------------------------
# Steam (a minute of waiting every run), the NVIDIA driver (four minutes when
# there is a new one) and VS Code's extension update (up to two minutes) do not
# depend on the winget installs. Run one after another they were most of a
# run's time: on 2026-11-15 the three app updates took 90 seconds and these
# steps another seven minutes. Each now runs as its own hidden copy of this
# script while the main run carries on; the copy writes what it found to a
# small file, and the main run reads that back into its list, log and hand-off.
$script:ChildSteps = @{
    Steam   = @{ Label = 'Steam';              Run = 'Update-SteamQuietly' }
    Nvidia  = @{ Label = 'NVIDIA driver';      Run = 'Update-NvidiaDriver' }
    CodeExt = @{ Label = 'VS Code extensions'; Run = 'Update-CodeExtensions' }
    Windows = @{ Label = 'Windows Update';     Run = 'Update-WindowsParts'; Steps = 2 }
}

# Starts one step as its own process. Returns $false if it could not, so the
# caller can run the step in turn instead.
function Start-ChildStep([string]$Step) {
    $def = $script:ChildSteps[$Step]
    $out = Join-Path $env:TEMP ('updatebot-{0}-{1}.json' -f $Step.ToLower(), $PID)
    foreach ($old in $out, "$out.log") { if (Test-Path $old) { Remove-Item -LiteralPath $old -Force } }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                   '-ChildStep', $Step, '-ChildOut', ('"{0}"' -f $out), '-NoElevate', '-NoAnimation', '-NoClaude')
    if ($ReinstallNvidia) { $arguments += '-ReinstallNvidia' }
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $null = $proc.Handle
    } catch {
        Write-Log ('Could not start {0} alongside ({1}); it will run in turn instead.' -f $def.Label, $_.Exception.Message) 'WARN'
        return $false
    }
    $item = Add-Item -Key "step:$Step" -Label $def.Label -State 'busy'
    $item.Note = 'checking'
    $script:Children.Add(@{ Step = $Step; Label = $def.Label; Proc = $proc; Out = $out; Started = Get-Date })
    Write-Log ('{0}: started alongside the app updates.' -f $def.Label)
    $true
}

# Collects every step that has finished: its log, its rows and its hand-off
# items. Show-Status calls this, so it happens whatever the main run is doing.
function Receive-ChildSteps {
    for ($i = $script:Children.Count - 1; $i -ge 0; $i--) {
        $c = $script:Children[$i]
        $overdue = ((Get-Date) - $c.Started).TotalMinutes -gt 90
        if (-not $c.Proc.HasExited -and -not $overdue) { continue }
        if ($overdue) { try { $c.Proc.Kill() } catch {} }
        $script:Children.RemoveAt($i)

        $seconds = [int]((Get-Date) - $c.Started).TotalSeconds
        $log = "$($c.Out).log"
        if (Test-Path $log) {
            $text = [string](Get-Content $log -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($text.Trim()) { Add-Content -Path $LogFile -Value $text.TrimEnd() -Encoding utf8 }
        }
        $result = $null
        try { $result = Get-Content $c.Out -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch {}
        foreach ($old in $c.Out, $log) { if (Test-Path $old) { Remove-Item -LiteralPath $old -Force } }

        $key  = "step:$($c.Step)"
        $item = $null
        if ($script:UI.ByKey.ContainsKey($key)) { $item = $script:UI.ByKey[$key] }
        if (-not $result) {
            $why = ''
            if ($overdue) { $why = ' (stopped after 90 minutes)' }
            Write-Log ('{0} ended without reporting back{1}.' -f $c.Label, $why) 'WARN'
            if ($item) { $item.State = 'failed'; $item.Note = 'did not finish' }
        } else {
            foreach ($entry in @($result.handoff)) { if ($entry) { $script:Handoff.Add($entry) } }
            $rows = @($result.rows | Where-Object { $_ })
            if ($item) {
                if ($rows.Count -eq 0) {
                    # Nothing to report (the app is not installed, say): drop the placeholder line.
                    [void]$script:UI.Items.Remove($item); $script:UI.ByKey.Remove($key)
                } else {
                    $item.State = 'msg'; $item.Note = ''; $item.Mark = [string]$rows[0].mark; $item.Label = [string]$rows[0].text; $item.Color = [string]$rows[0].color
                    foreach ($row in @($rows | Select-Object -Skip 1)) { Add-Row ([string]$row.mark) ([string]$row.text) ([string]$row.color) }
                }
            }
            Write-Log ('{0}: finished alongside, {1} s.' -f $c.Label, $seconds)
        }
        $steps = 1
        if ($script:ChildSteps[$c.Step].Steps) { $steps = [int]$script:ChildSteps[$c.Step].Steps }
        $script:UI.Done += $steps
    }
}

function Wait-ChildSteps {
    if ($script:Children.Count -eq 0) { return }
    Set-Phase ('Finishing: {0}' -f (($script:Children | ForEach-Object { $_.Label }) -join ', '))
    while ($script:Children.Count -gt 0) { Show-Status; Start-Sleep -Milliseconds $script:TickMs }
}

# What a -ChildStep copy does: run its one step and write down what it found.
function Invoke-ChildStep {
    $def = $script:ChildSteps[$ChildStep]
    $failure = ''
    if (-not $def) {
        $failure = "unknown step '$ChildStep'"
    } else {
        try { & $def.Run }
        catch {
            $failure = '{0} stopped at line {1}: {2}' -f $def.Run, $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message
            Write-Log $failure 'WARN'
        }
    }
    $rows = @($script:UI.Items | Where-Object { $_.State -eq 'msg' } |
        ForEach-Object { @{ mark = [string]$_.Mark; text = [string]$_.Label; color = [string]$_.Color } })
    ConvertTo-Json -InputObject @{ rows = $rows; handoff = $script:Handoff.ToArray(); error = $failure } -Depth 5 |
        Set-Content -Path $ChildOut -Encoding utf8
}

# --- Moving into Windows Terminal --------------------------------------------
# The classic console host can only draw text. A run that starts there (a start
# as administrator lands there even when Windows Terminal is the default) is
# handed to a Windows Terminal window, where the mascot is a real image. This
# copy hides its own window, waits for the other one to finish and passes its
# exit code on, so Task Scheduler still sees one task from start to end.
# Returns $true when the run happened over there.
function Invoke-Rehost {
    if (-not $script:Live -or $NoMascot -or $NoRehost -or $RehostPidFile -or $DryRun) { return $false }
    if ($script:SixelSupported) { return $false }                       # this console already draws images
    if (-not (Test-Path (Join-Path $PSScriptRoot 'mascot.sixel.json'))) { return $false }
    $wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
    if (-not $wt) { return $false }

    # Installing a Windows Terminal update closes Terminal's windows, which would
    # end a run inside one. When that update is waiting, stay here; it is
    # installed last, as before.
    if (-not $Demo -and -not $SelfUpdatersOnly) {
        $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
        if ($winget) {
            $listing = (& $winget upgrade --include-unknown --accept-source-agreements --disable-interactivity | Out-String)
            if ($listing -match '\sMicrosoft\.WindowsTerminal(\.Preview)?\s') {
                Write-Log 'Staying in the classic console for this run: a Windows Terminal update is waiting, and installing it closes Terminal windows.'
                return $false
            }
        }
    }

    $pidFile = Join-Path $env:TEMP ('updatebot-rehost-{0}.txt' -f $PID)
    foreach ($old in $pidFile, "$pidFile.cancel") { if (Test-Path $old) { Remove-Item -LiteralPath $old -Force } }
    $arguments = @('-w', 'new', '--size', '124,40', '--title', '"Update All Apps"', '--suppressApplicationTitle',
                   'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                   '-NoElevate', '-RehostPidFile', ('"{0}"' -f $pidFile))
    foreach ($name in 'IncludeStore', 'SkipDevTools', 'SkipSelfUpdaters', 'SelfUpdatersOnly', 'ReinstallNvidia', 'NoClaude', 'NoEmoji', 'Demo') {
        if ($script:BoundNames -contains $name) { $arguments += "-$name" }
    }
    if ($script:BoundNames -contains 'MaxParallel') { $arguments += @('-MaxParallel', $MaxParallel) }
    try { Start-Process -FilePath $wt -ArgumentList $arguments } catch { return $false }

    # Wait for the copy in Terminal to say it has started.
    $otherId = 0
    $until = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $until) {
        $text = [string](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
        if ($text -match 'pid=(\d+)') { $otherId = [int]$Matches[1]; break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $otherId) {
        Set-Content -Path "$pidFile.cancel" -Value 'x' -Encoding ascii   # a late starter must not run a second update
        Write-Log 'Windows Terminal did not start in time; carrying on in this console.' 'WARN'
        return $false
    }

    $script:Rehosted = $true
    try { [void][Native.Vt]::ShowWindow([Native.Vt]::GetConsoleWindow(), 0) } catch {}   # hide this now-idle window
    while (Get-Process -Id $otherId -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 500 }
    $script:ExitCode = 1                                                # unless it says otherwise (closed by hand, say)
    $text = [string](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
    if ($text -match 'exit=(-?\d+)') { $script:ExitCode = [int]$Matches[1] }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    $true
}

# --- Demo ------------------------------------------------------------------
function Invoke-Demo {
    # Fakes the parallel run against a made-up list so the display can be seen
    # without changing anything. Each app downloads, installs, then finishes;
    # several move at once, like the real scheduler.
    $fake = @(
        @{ Name = '7-Zip';              Ver = '26.04';    Dl = 3;  In = 2; Fail = $false }
        @{ Name = 'Google Chrome';      Ver = '156.0';    Dl = 7;  In = 3; Fail = $false }
        @{ Name = 'Git';                Ver = '2.56.0.3'; Dl = 4;  In = 2; Fail = $false }
        @{ Name = 'KeePassXC';          Ver = '2.8.0';    Dl = 3;  In = 2; Fail = $false }
        @{ Name = 'MEGAsync';           Ver = '6.7.0';    Dl = 9;  In = 3; Fail = $false }
        @{ Name = 'OBS Studio';         Ver = '33.0.0';   Dl = 6;  In = 10; Fail = $false; InUse = $true }
        @{ Name = 'Ollama';             Ver = '0.40.10';  Dl = 10; In = 4; Fail = $false }
        @{ Name = 'Oracle VirtualBox';  Ver = '7.2.22';   Dl = 5;  In = 24; Fail = $false }
        @{ Name = 'PDF-XChange Editor'; Ver = '11.1.1';   Dl = 3;  In = 3; Fail = $false }
        @{ Name = 'qBittorrent';        Ver = '5.1.3';    Dl = 3;  In = 2; Fail = $false }
        @{ Name = 'Iriun Webcam';       Ver = '';         Dl = 2;  In = 0; Fail = $true }
    )
    $script:UI.Total = $fake.Count + 3
    Set-Phase 'Scanning installed apps'
    # The two slow steps that run alongside the app updates in a real run.
    $steam  = Add-Item -Key 'step:Steam'  -Label 'Steam'         -State 'busy'; $steam.Note  = 'checking'
    $nvidia = Add-Item -Key 'step:Nvidia' -Label 'NVIDIA driver' -State 'busy'; $nvidia.Note = 'checking'
    foreach ($a in $fake) { [void](Add-Item -Key $a.Name -Label $a.Name -State 'queued') }
    Wait-Animated 1

    Set-Phase ('Updating {0} apps (3 at a time)' -f $fake.Count)
    $pending = [System.Collections.ArrayList]@($fake)
    $running = [System.Collections.ArrayList]@()
    $step = 0
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt 3 -and $pending.Count -gt 0) {
            $a = $pending[0]; $pending.RemoveAt(0)
            $a.T = 0; [void]$running.Add($a)
            $a.Item = $script:UI.ByKey[$a.Name]; $a.Item.State = 'download'; $a.Item.Pct = 0.0
        }
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $a = $running[$i]; $a.T++
            if ($a.T -le $a.Dl) {
                $a.Item.State = 'download'; $a.Item.Pct = [double]$a.T / $a.Dl
            } elseif ($a.T -le ($a.Dl + $a.In)) {
                $a.Item.State = 'install'
            } else {
                $running.RemoveAt($i); $script:UI.Done++
                if ($a.Fail) { $a.Item.State = 'failed'; $a.Item.Note = "the publisher's download link is dead (404)" }
                else { $a.Item.State = 'done'; $a.Item.Note = $a.Ver }
            }
        }
        $step++
        if ($step -eq 8)  { $steam.State = 'msg'; $steam.Mark = $Glyph.Ok; $steam.Label = 'Steam and Wallpaper Engine'; $steam.Color = 'Green'; $script:UI.Done++ }
        if ($step -eq 5)  { $nvidia.Note = 'installing 621.24' }
        if ($step -eq 30) { $nvidia.State = 'msg'; $nvidia.Mark = $Glyph.Ok; $nvidia.Label = 'NVIDIA driver  621.24'; $nvidia.Color = 'Green'; $script:UI.Done++ }
        $script:UI.Speed = (Get-Random -Minimum 8MB -Maximum 60MB)
        # One step of the pretend run every 0.4 s; the display ticks at its own rate in between.
        $until = (Get-Date).AddMilliseconds(400)
        while ((Get-Date) -lt $until) { Show-Status; Start-Sleep -Milliseconds $script:TickMs }
    }
    $script:UI.Speed = 0
    if ($nvidia.State -eq 'busy') { $nvidia.State = 'msg'; $nvidia.Mark = $Glyph.Ok; $nvidia.Label = 'NVIDIA driver  621.24'; $nvidia.Color = 'Green'; $script:UI.Done++ }
    Add-Row $Glyph.Ok 'App updaters checked  (12)' 'Green'
    $script:UI.Done = $script:UI.Total
    Set-Phase ('All done {0}  (demo - nothing was changed)' -f $Glyph.Party)
    Wait-Animated 6
}

# --- Windows parts: Defender definitions, then Windows Update --------------
# Kept together because the Windows Update list is read against the Defender
# result. Runs alongside the app updates as its own process in a normal run.
function Update-WindowsParts {
    # --- Microsoft Defender definitions (before the Windows Update scan, which
    #     otherwise lists the same definition update as still waiting) --------
    Set-Phase 'Updating Defender definitions'
    $defenderOk = [bool]$DryRun
    if ($DryRun) {
        Write-Log 'Would refresh Microsoft Defender definitions.'
    } else {
        $defender = Invoke-AnimatedJob -TimeoutSec 180 -ScriptBlock { Update-MpSignature -ErrorAction Stop }
        $defenderOk = $defender.Ok
        if ($defender.Ok) {
            Write-Log 'Microsoft Defender definitions are current.' 'OK'
            Add-Row $Glyph.Ok 'Defender definitions' 'Green'
        } else {
            Write-Log ('Defender definition update failed: {0}' -f $defender.Error) 'WARN'
            Add-Row $Glyph.Skip 'Defender definitions  (failed)' 'DarkYellow'
        }
    }

    # --- Windows Update (scan; installs only what was approved, never restarts)
    Set-Phase 'Scanning Windows Update'
    Write-Log 'Scanning Windows Update...'
    $wu = Invoke-AnimatedJob -TimeoutSec 240 -ScriptBlock {
        # Hardware IDs of every device that is connected right now.
        $present = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            ForEach-Object { $_.HardwareID; $_.CompatibleID } | Where-Object { $_ } |
            ForEach-Object { $_.ToUpperInvariant() })

        $signed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.HardWareID })

        $session = New-Object -ComObject Microsoft.Update.Session
        $search  = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
        foreach ($update in $search.Updates) {
            $isDriver  = ($update.Type -eq 2)
            $inThisPc  = $true
            $offered   = ''
            $installed = ''
            if ($isDriver -and $update.DriverHardwareID) {
                $id = ([string]$update.DriverHardwareID).ToUpperInvariant()
                if ($present.Count -gt 0) {
                    $inThisPc = [bool]($present | Where-Object {
                        $_ -eq $id -or $_.StartsWith($id) -or ($_.Length -ge 15 -and $id.StartsWith($_))
                    } | Select-Object -First 1)
                }
                # What is offered against what is installed, so the decision can be made later.
                if ($update.DriverVerDate) { $offered = ([datetime]$update.DriverVerDate).ToString('yyyy-MM-dd') }
                $current = $signed | Where-Object {
                    $have = $_.HardWareID.ToUpperInvariant()
                    $have -eq $id -or $have.StartsWith($id) -or $id.StartsWith($have)
                } | Select-Object -First 1
                if ($current) { $installed = '{0} from {1}' -f $current.DriverVersion, $current.DriverDate.ToString('yyyy-MM-dd') }
            }
            [pscustomobject]@{
                Id = [string]$update.Identity.UpdateID; Title = $update.Title; Driver = $isDriver
                Model = [string]$update.DriverModel; InThisPc = $inThisPc; Offered = $offered; Installed = $installed
            }
        }
    }

    # Windows keeps offering drivers for hardware that was removed; those are not real updates.
    $ignored = @($wu.Result | Where-Object { -not $_.InThisPc })
    $waiting = @($wu.Result | Where-Object { $_.InThisPc })
    foreach ($update in $ignored) {
        Write-Log ('  Ignored: {0} - driver for {1}, which is not in this PC.' -f $update.Title, $update.Model)
    }

    # The Defender refresh above installs these; Windows Update can keep listing them for a while.
    if ($defenderOk) {
        $definitions = @($waiting | Where-Object { $_.Title -match 'Security Intelligence Update for Microsoft Defender' })
        foreach ($update in $definitions) { Write-Log ('  Ignored: {0} - covered by the Defender refresh.' -f $update.Title) }
        $waiting = @($waiting | Where-Object { $definitions.Id -notcontains $_.Id })
    }

    # --- Install the Windows updates Claude approved after an earlier run ----
    $approved = @()
    if (Test-Path $ApprovedFile) {
        try { $approved = @((Get-Content $ApprovedFile -Raw | ConvertFrom-Json) | ForEach-Object { [string]$_ }) } catch {}
    }
    $toInstall     = @($waiting | Where-Object { $approved -contains $_.Id })
    $restartNeeded = $false
    if ($toInstall.Count -gt 0 -and $DryRun) {
        Write-Log ('Would install {0} approved Windows update(s).' -f $toInstall.Count)
    } elseif ($toInstall.Count -gt 0 -and -not $isAdmin) {
        Write-Log '  Approved Windows updates are waiting, but this run is not elevated.' 'WARN'
    } elseif ($toInstall.Count -gt 0) {
        Set-Phase ('Installing {0} approved Windows update(s)' -f $toInstall.Count)
        Write-Log ('Installing {0} approved Windows update(s)...' -f $toInstall.Count)
        $install = Invoke-AnimatedJob -TimeoutSec 3600 -ArgumentList (, [string[]]$toInstall.Id) -ScriptBlock {
            param([string[]]$Ids)
            # A restore point first, so a bad driver can be undone from Windows recovery.
            $restore = 'created'
            try {
                Checkpoint-Computer -Description 'Update bot: before approved Windows updates' `
                    -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
            } catch { $restore = 'not created ({0})' -f $_.Exception.Message }

            $session = New-Object -ComObject Microsoft.Update.Session
            $found   = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
            $batch   = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($update in $found.Updates) {
                if ($Ids -contains $update.Identity.UpdateID) {
                    if (-not $update.EulaAccepted) { $update.AcceptEula() }
                    [void]$batch.Add($update)
                }
            }

            $outcome = @(); $restart = $false
            if ($batch.Count -gt 0) {
                $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $batch
                [void]$downloader.Download()
                $installer = $session.CreateUpdateInstaller(); $installer.Updates = $batch
                $result  = $installer.Install()
                $restart = [bool]$result.RebootRequired
                for ($i = 0; $i -lt $batch.Count; $i++) {
                    $one = $result.GetUpdateResult($i)
                    $outcome += [pscustomobject]@{
                        Id = [string]$batch.Item($i).Identity.UpdateID; Code = [int]$one.ResultCode; HResult = ('0x{0:X8}' -f $one.HResult)
                    }
                }
            }
            [pscustomobject]@{ Restore = $restore; Restart = $restart; Outcome = $outcome }
        }

        $report = $install.Result | Select-Object -First 1
        if (-not $install.Ok -or -not $report) {
            Write-Log ('  Installing approved Windows updates failed: {0}' -f $install.Error) 'WARN'
        } else {
            Write-Log ('  Restore point: {0}' -f $report.Restore)
            foreach ($one in @($report.Outcome)) {
                $update = $toInstall | Where-Object { $_.Id -eq $one.Id } | Select-Object -First 1
                if ($one.Code -eq 2 -or $one.Code -eq 3) {     # succeeded, or succeeded with errors
                    Write-Log ('  OK: {0}' -f $update.Title) 'OK'
                    Add-Row $Glyph.Ok $update.Title 'Green'
                    $waiting = @($waiting | Where-Object { $_.Id -ne $one.Id })
                } else {
                    Write-Log ('  FAILED ({0}): {1}' -f $one.HResult, $update.Title) 'ERROR'
                    $update | Add-Member -NotePropertyName Failed -NotePropertyValue $one.HResult -Force
                }
            }
            $restartNeeded = [bool]$report.Restart
        }

        # An approval is used once. A failure goes back on the list for a fresh decision.
        $unused = @($approved | Where-Object { $toInstall.Id -notcontains $_ })
        ConvertTo-Json -InputObject $unused | Set-Content -Path $ApprovedFile -Encoding utf8
    }

    if (-not $wu.Ok) {
        Write-Log ('  Windows Update scan failed: {0}' -f $wu.Error) 'WARN'
        Add-Row $Glyph.Skip 'Windows Update  (scan failed)' 'DarkYellow'
    } elseif ($waiting.Count -eq 0) {
        Write-Log '  Windows Update: nothing pending.' 'OK'
        Add-Row $Glyph.Ok 'Windows Update' 'Green'
    } else {
        Add-Row $Glyph.Info ('Windows Update  ({0} waiting)' -f $waiting.Count) 'Yellow'
        foreach ($update in $waiting) {
            $kind = 'Windows update'
            if ($update.Driver) { $kind = 'Driver update' }
            $reason = "$kind waiting to install"
            if ($update.Failed) { $reason = "$kind failed to install ($($update.Failed))" }
            $detail = ''
            if ($update.Driver) {
                $have = 'unknown'
                if ($update.Installed) { $have = $update.Installed }
                $detail = 'offered: {0}; installed now: {1}' -f $update.Offered, $have
            }
            Add-Handoff -Source 'Windows Update' -Name $update.Title -Id $update.Id -Reason $reason -Detail $detail `
                -Suggestion 'To install it, add its id to approved-windows-updates.json; the next elevated run installs it.'
        }
    }
    if ($restartNeeded) {
        Add-Row $Glyph.Info 'Restart needed to finish an update' 'Yellow'
        Add-Handoff -Source 'this run' -Name 'Restart needed' -Reason 'an installed Windows update finishes at the next restart' `
            -Suggestion 'Restart the PC when convenient. Nothing restarts it automatically.'
    }
}

# ===========================================================================
function Remove-OldWingetInstallers {
    param([string]$Root = (Join-Path $env:TEMP 'WinGet'), [datetime]$Now = (Get-Date))
    if ($DryRun -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $base = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if ($base.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Log 'Installer cleanup skipped: root is a link.' 'WARN'
        return
    }
    $prefix = $base.FullName.TrimEnd('\') + '\'
    $cutoff = $Now.AddDays(-14)
    $removed = 0; $bytes = 0L
    foreach ($folder in @(Get-ChildItem -LiteralPath $base.FullName -Directory -Force)) {
        # Retain shared caches, links and recently used folders.
        if ($folder.Name -notmatch '^.+\.\d' -or $folder.Name -match '(?i)riot|leagueoflegends|teamfight') { continue }
        $target = [IO.Path]::GetFullPath($folder.FullName)
        if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Parent $target) -ne $base.FullName -or
            ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $folder.LastWriteTime -ge $cutoff) { continue }
        try {
            $children = @(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction Stop)
            if (@($children | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.LastWriteTime -ge $cutoff }).Count) { continue }
            $size = ($children | Where-Object { -not $_.PSIsContainer } | Measure-Object Length -Sum).Sum
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            $removed++; $bytes += [long]$size
            Write-Log ('Removed old installer folder: {0}' -f $folder.Name)
        } catch { Write-Log ('Installer cleanup skipped {0}: {1}' -f $folder.Name, $_.Exception.Message) 'WARN' }
    }
    Write-Log ('Installer cleanup: {0} folder(s), {1} reclaimed; retained the last 14 days and shared caches.' -f $removed, (Format-Bytes $bytes))
}

function Invoke-RetentionCleanup {
    if ($DryRun) { return }
    Remove-OldWingetInstallers
    $old = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -File -Recurse | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) })
    Write-Log ('Log retention: {0} log(s) older than 90 days; preserved pending user decision.' -f $old.Count)
    foreach ($log in $old) { Write-Log ('Old log retained: {0} ({1}, {2} bytes)' -f $log.FullName, $log.LastWriteTime.ToString('yyyy-MM-dd'), $log.Length) }
}

function Invoke-Update {
    if ($SelfUpdatersOnly) {
        Write-Log ('Checking only the apps that update themselves | elevated: {0}' -f $isAdmin)
        $script:UI.Total = @(Get-SelfUpdaterSteps).Count
        Invoke-SelfUpdaters
        Invoke-RetentionCleanup
        Set-Phase ('Done {0}' -f $Glyph.Party)
        Write-Log 'Done (apps that update themselves only).' 'OK'
        Write-Log "Log: $LogFile"
        if ($script:Live -and ([Environment]::GetCommandLineArgs() -contains '-File')) {
            Wait-Animated 10
        }
        return
    }

    # --- Preflight ---------------------------------------------------------
    $script:Winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $script:Winget) {
        Write-Log 'winget not found. Install "App Installer" from the Microsoft Store.' 'ERROR'
        $script:ExitCode = 1
        return
    }

    Write-Log ('winget {0} | elevated: {1}' -f (& $script:Winget --version), $isAdmin)
    if (-not $isAdmin) {
        Write-Log 'Not elevated - machine-wide apps will be skipped. Re-run as admin for full coverage.' 'WARN'
    }

    # How many installs run at once: auto-size to the CPU, capped at 8. More than
    # the core count does not pay off - downloads saturate the connection and
    # Windows serialises MSI installs regardless (those share one lane below).
    $parallel = $MaxParallel
    if ($parallel -le 0) { $parallel = [math]::Max(4, [math]::Min([Environment]::ProcessorCount, 8)) }
    Write-Log ('Running up to {0} installs at once (lock-taking installers still go one at a time).' -f $parallel)

    $display = 'plain log lines (no live display)'
    if ($script:Live) {
        $display = 'classic console, mascot drawn with text blocks'
        if ($script:Sixel) { $display = 'Windows Terminal, mascot drawn as an image' }
        elseif ($NoMascot) { $display = 'live display without the mascot' }
        if ($RehostPidFile) { $display += ' (moved here from the classic console)' }
    }
    Write-Log ('Display: {0}.' -f $display)

    # --- Start the slow, independent steps now; they run alongside everything below
    $alongside = @()
    if (-not $SkipSelfUpdaters -and -not $DryRun) {
        if (Start-ChildStep 'Steam')  { $alongside += 'Update-SteamQuietly' }
        if (Start-ChildStep 'Nvidia') { $alongside += 'Update-NvidiaDriver' }
    }
    $windowsAlongside = $false
    if (-not $DryRun) { $windowsAlongside = Start-ChildStep 'Windows' }

    # --- Refresh sources ---------------------------------------------------
    Set-Phase 'Refreshing package sources'
    Write-Log 'Refreshing package sources...'
    $null = Invoke-Animated -File $script:Winget -Arguments @('source', 'update', '--disable-interactivity') -TimeoutSec 180

    # --- Discover what is upgradable ---------------------------------------
    Set-Phase 'Scanning installed apps'
    Write-Log 'Scanning installed apps for available updates...'
    $pending = @(Get-WingetUpgrades | Where-Object { $_.Id -notmatch '(?i)riot|leagueoflegends|teamfight' -and $_.Name -notmatch '(?i)riot|league of legends|teamfight' })

    # Skip what this script already installed when Windows cannot show it: either it
    # records no version at all, or only a shorter form of it ("6.7.0" for "6.7.0.3").
    $memo = Get-InstalledMemo
    $alreadyDone = @($pending | Where-Object {
        $memo[$_.Id] -eq $_.Available -and ($_.Version -eq 'Unknown' -or $_.Available.StartsWith($_.Version + '.')) -and
        (Test-AppFilesPresent $_.Name)     # a note that it was installed is no use if the program has gone missing
    })
    foreach ($app in $alreadyDone) {
        $why = 'winget cannot read its installed version'
        if ($app.Version -ne 'Unknown') { $why = 'Windows lists it as {0}' -f $app.Version }
        Write-Log ('  = {0} is already on {1} ({2})' -f $app.Name, $app.Available, $why)
    }
    $pending = @($pending | Where-Object { $alreadyDone.Id -notcontains $_.Id })

    # A version that changed nothing when it was installed is not downloaded again for three weeks.
    $noChange = Get-NoChangeMemo
    $repeats  = @($pending | Where-Object { $noChange.ContainsKey($_.Id) -and $noChange[$_.Id].version -eq $_.Available })
    foreach ($app in $repeats) {
        Write-Log ('  = {0}: winget still offers {1}, which changed nothing when it was installed on {2}; not repeated.' -f $app.Name, $app.Available, $noChange[$app.Id].date)
    }
    $pending = @($pending | Where-Object { $repeats.Id -notcontains $_.Id })

    $skipped = @($pending | Where-Object { $Exclude -contains $_.Id })
    $targets = @($pending | Where-Object { $Exclude -notcontains $_.Id })
    $early   = @($targets | Where-Object { $UpdateLast -notcontains $_.Id })
    $late    = @($targets | Where-Object { $UpdateLast -contains $_.Id })

    Write-Log ('{0} update(s) available:' -f $targets.Count)
    foreach ($app in $early + $late) {
        Write-Log ('  - {0}  ({1})  {2} -> {3}' -f $app.Name, $app.Id, $app.Version, $app.Available)
        [void](Add-Item -Key $app.Id -Label $app.Name -State 'queued')   # show every app from the start
    }
    foreach ($app in $skipped) {
        Write-Log ('  ~ SKIPPED (excluded): {0}' -f $app.Id) 'WARN'
        Add-Row $Glyph.Skip ('{0}  (excluded)' -f $app.Name) 'DarkYellow'
        Add-Handoff -Source 'winget' -Name $app.Name -Id $app.Id -Reason 'it is on the exclusion list but has an update' `
            -Suggestion 'The script leaves excluded apps alone. Ask Claude to update it.' `
            -Detail ('{0} -> {1}' -f $app.Version, $app.Available)
    }

    $devTools  = -not $SkipDevTools
    $hasNpm    = $devTools -and [bool](Get-Command npm -ErrorAction SilentlyContinue)
    $hasPython = $devTools -and [bool](Get-Command python -ErrorAction SilentlyContinue)
    $hasCode   = $devTools -and [bool](Get-Command code -ErrorAction SilentlyContinue)

    # One step per app, plus one per extra source below.
    $extraSteps = 2                                  # Windows Update scan, Defender
    if ($IncludeStore) { $extraSteps++ }
    if ($hasNpm)       { $extraSteps++ }
    if ($hasPython)    { $extraSteps++ }
    if ($hasCode)      { $extraSteps++ }
    if (-not $SkipSelfUpdaters) { $extraSteps += @(Get-SelfUpdaterSteps).Count }  # discovered self-updater steps
    if ($Adopt.Count -gt 0)     { $extraSteps++ }
    $script:UI.Total = $targets.Count + $extraSteps

    # --- Apply updates, several at once -------------------------------------
    $ok = 0; $fail = 0
    if (-not $DryRun -and $early.Count -gt 0) {
        Set-Phase ('Updating {0} apps ({1} at a time)' -f $early.Count, $parallel)
        $batch = Invoke-WingetBatch (New-WingetTasks $early) $parallel
        $ok += $batch.ok; $fail += $batch.failed
    }

    # VS Code's own extension update can start now that VS Code itself is done
    # updating; it too runs alongside the rest.
    $codeAlongside = $false
    if ($hasCode -and -not $DryRun) { $codeAlongside = Start-ChildStep 'CodeExt' }

    # --- Apps winget cannot link to its own package ------------------------
    if ($Adopt.Count -gt 0) {
        Set-Phase 'Checking apps winget cannot link'
        Update-AdoptedApps
        $ok += $script:AdoptedOk; $fail += $script:AdoptedFailed
        $script:UI.Done++
    }

    # --- Microsoft Store apps ----------------------------------------------
    $storeMsg = ''
    if ($IncludeStore) {
        Set-Phase 'Checking Microsoft Store apps'
        if ($DryRun) {
            Write-Log 'Would also sweep Microsoft Store apps (-IncludeStore).'
        } else {
            Write-Log 'Sweeping Microsoft Store apps (msstore source)...'
            $run = Invoke-Animated -File $script:Winget -Arguments @(
                'upgrade', '--all', '--source', 'msstore', '--silent', '--include-unknown',
                '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
            Add-Content -Path $LogFile -Value (Format-NativeOutput $run.Output) -Encoding utf8

            if ($run.Output -match 'No installed package found|No applicable upgrade|No available upgrade') {
                Write-Log '  Store apps already up to date.' 'OK'; $storeMsg = ' Store: ok.'
            } elseif ($run.ExitCode -eq 0) {
                Write-Log '  Store apps updated.' 'OK'; $storeMsg = ' Store: ok.'
            } else {
                Write-Log ('  Store sweep returned exit {0} - see log.' -f $run.ExitCode) 'WARN'
                $storeMsg = ' Store: check log.'
            }

            # winget only sees part of the Store catalog, so also ask the Store itself to check.
            $scan = Invoke-AnimatedJob -TimeoutSec 60 -ScriptBlock {
                Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
                    Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
            }
            if ($scan.Ok) { Write-Log '  Asked the Microsoft Store to check its own apps.' 'OK' }
            else { Write-Log ('  Could not start a Microsoft Store scan: {0}' -f $scan.Error) 'WARN' }
            Add-Row $Glyph.Ok 'Microsoft Store apps' 'Green'
        }
        $script:UI.Done++
    }

    # --- Defender definitions and Windows Update (only here if not started alongside)
    if (-not $windowsAlongside) {
        Update-WindowsParts
        $script:UI.Done += 2
    }

    # --- npm global packages -----------------------------------------------
    if ($hasNpm) {
        Set-Phase 'Checking npm global packages'
        $run = Invoke-Animated -File 'cmd.exe' -Arguments @('/c', 'npm', 'outdated', '-g', '--json') -TimeoutSec 120
        $outdated = @(); $checked = $false
        try {
            $json = $run.StdOut | ConvertFrom-Json -ErrorAction Stop
            $outdated = @($json.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Current = $_.Value.current; Latest = $_.Value.latest }
            })
            $checked = $true
        } catch {}

        if (-not $checked) {
            Write-Log 'Could not read the npm outdated list.' 'WARN'
            Add-Row $Glyph.Skip 'npm global packages  (could not check)' 'DarkYellow'
        } elseif ($outdated.Count -eq 0) {
            Write-Log 'npm global packages are up to date.' 'OK'
            Add-Row $Glyph.Ok 'npm global packages' 'Green'
        } elseif ($DryRun) {
            Write-Log ('Would update {0} npm global package(s).' -f $outdated.Count)
            Add-Row $Glyph.Info ('npm global packages  ({0} outdated)' -f $outdated.Count) 'Yellow'
        } else {
            Set-Phase 'Updating npm global packages'
            # Name each one at @latest: a bare "npm update -g" can stop short of the newest release.
            $targets = @($outdated | ForEach-Object { '{0}@latest' -f $_.Name })
            $update  = Invoke-Animated -File 'cmd.exe' -Arguments (@('/c', 'npm', 'install', '-g') + $targets) -TimeoutSec 900
            Add-Content -Path $LogFile -Value (Format-NativeOutput $update.Output) -Encoding utf8
            if ($update.ExitCode -eq 0) {
                Write-Log ('Updated {0} npm global package(s): {1}' -f $outdated.Count, ($outdated.Name -join ', ')) 'OK'
                Add-Row $Glyph.Ok ('npm global packages  ({0} updated)' -f $outdated.Count) 'Green'
            } else {
                Write-Log ('npm install -g returned exit {0}.' -f $update.ExitCode) 'WARN'
                Add-Row $Glyph.Fail 'npm global packages  (update failed)' 'Red'
                Add-Handoff -Source 'npm' -Name ($outdated.Name -join ', ') -Reason ('npm could not update them (exit {0})' -f $update.ExitCode) `
                    -Suggestion 'Read the npm output in the log and update them one at a time.' `
                    -Detail (($outdated | ForEach-Object { '{0} {1} -> {2}' -f $_.Name, $_.Current, $_.Latest }) -join '; ')
            }
        }
        $script:UI.Done++
    }

    # --- Python packages (snapshot, upgrade together, undo on any conflict) ---
    if ($hasPython) {
        Set-Phase 'Checking Python packages'
        $run = Invoke-Animated -File 'python' -TimeoutSec 180 -Arguments @(
            '-m', 'pip', 'list', '--outdated', '--format=json', '--disable-pip-version-check')
        $outdated = @(); $checked = $false
        try {
            # Piping unrolls the array; PowerShell 5.1 otherwise hands it back as one object.
            $outdated = @(($run.StdOut.Trim() | ConvertFrom-Json -ErrorAction Stop) | ForEach-Object { $_ })
            $checked = $true
        } catch {}

        if (-not $checked) {
            Write-Log 'Could not read the pip outdated list.' 'WARN'
            Add-Row $Glyph.Skip 'Python packages  (could not check)' 'DarkYellow'
        } elseif ($outdated.Count -eq 0) {
            Write-Log 'Python packages are up to date.' 'OK'
            Add-Row $Glyph.Ok 'Python packages' 'Green'
        } elseif ($DryRun) {
            Write-Log ('Would upgrade {0} Python package(s).' -f $outdated.Count)
            Add-Row $Glyph.Info ('Python packages  ({0} outdated)' -f $outdated.Count) 'Yellow'
        } else {
            Set-Phase ('Upgrading {0} Python packages' -f $outdated.Count)
            $changes = ($outdated | ForEach-Object { '{0} {1} -> {2}' -f $_.name, $_.version, $_.latest_version }) -join '; '

            # Snapshot first, so a bad upgrade can be undone.
            $snapshot = Join-Path $LogDir ('pip-freeze-' + (Get-Date -Format 'yyyy-MM-dd_HHmmss') + '.txt')
            $freeze = Invoke-Animated -File 'python' -Arguments @('-m', 'pip', 'freeze', '--disable-pip-version-check') -TimeoutSec 120
            Set-Content -Path $snapshot -Value $freeze.StdOut -Encoding ascii

            # One call, so pip resolves them together and keeps their dependencies consistent.
            $upgrade = Invoke-Animated -File 'python' -TimeoutSec 1800 -Arguments (
                @('-m', 'pip', 'install', '--upgrade', '--disable-pip-version-check') + @($outdated | ForEach-Object { $_.name }))
            Add-Content -Path $LogFile -Value (Format-NativeOutput $upgrade.Output) -Encoding utf8
            $check = Invoke-Animated -File 'python' -Arguments @('-m', 'pip', 'check', '--disable-pip-version-check') -TimeoutSec 120

            if ($upgrade.ExitCode -eq 0 -and $check.ExitCode -eq 0) {
                Write-Log ('Upgraded {0} Python package(s), no conflicts: {1}' -f $outdated.Count, $changes) 'OK'
                Add-Row $Glyph.Ok ('Python packages  ({0} upgraded)' -f $outdated.Count) 'Green'
            } else {
                Add-Content -Path $LogFile -Value (Format-NativeOutput $check.Output) -Encoding utf8
                $restore = Invoke-Animated -File 'python' -TimeoutSec 1800 -Arguments @(
                    '-m', 'pip', 'install', '--disable-pip-version-check', '-r', ('"{0}"' -f $snapshot))
                $state = 'the previous versions were put back'
                if ($restore.ExitCode -ne 0) { $state = 'putting the previous versions back also failed' }
                Write-Log ('Python upgrade caused a problem; {0}.' -f $state) 'WARN'
                Add-Row $Glyph.Fail 'Python packages  (upgrade undone)' 'Red'
                Add-Handoff -Source 'pip' -Name ('{0} Python package(s)' -f $outdated.Count) `
                    -Reason ('upgrading them together failed or left a conflict, and {0}' -f $state) `
                    -Suggestion "Upgrade them a few at a time and run pip check after each. Snapshot of the working set: $snapshot" `
                    -Detail $changes
            }
        }
        $script:UI.Done++
    }

    # --- VS Code extensions (only here if they could not be started alongside) -
    if ($hasCode -and -not $codeAlongside) {
        Update-CodeExtensions
        $script:UI.Done++
    }

    # --- Apps that update themselves (Discord, NVIDIA driver, Steam) ----
    #     Steam and the driver are normally already running alongside.
    if (-not $SkipSelfUpdaters) { Invoke-SelfUpdaters -Skip $alongside }

    # --- Everything started alongside has to be in before the lists are written
    Wait-ChildSteps

    if (-not $isAdmin -and -not $DryRun) {
        Add-Handoff -Source 'this run' -Name 'Not elevated' -Reason 'machine-wide apps may have been skipped' `
            -Suggestion 'Run the script again and accept the administrator prompt.'
    }

    if ($DryRun) {
        Write-Handoff
        Set-Phase 'Dry run finished - nothing was changed'
        Write-Log 'Dry run - nothing was changed.' 'OK'
        Write-Log "Needs attention: $($script:Handoff.Count) item(s) - $HandoffMd"
        Write-Log "Log: $LogFile"
        return
    }

    # --- Apps that can close this console go last, after everything is saved,
    #     and one at a time (replacing Terminal or PowerShell under ourselves). -
    Write-Handoff
    if ($late.Count -gt 0) {
        Set-Phase 'Updating the terminal and shell'
        $batch = Invoke-WingetBatch (New-WingetTasks $late) 1
        $ok += $batch.ok; $fail += $batch.failed
    }
    Write-Handoff

    Invoke-RetentionCleanup
    Write-Log ('Progress: {0}/{1} steps completed.' -f $script:UI.Done, $script:UI.Total)
    $script:UI.Done = $script:UI.Total
    Set-Phase ('All done {0}  {1} updated, {2} failed, {3} need attention' -f $Glyph.Party, $ok, $fail, $script:Handoff.Count)
    Write-Log ('Done. {0} updated, {1} failed, {2} excluded.{3}' -f $ok, $fail, $skipped.Count, $storeMsg) 'OK'
    Write-Log "Needs attention: $($script:Handoff.Count) item(s) - $HandoffMd"
    Write-Log "Log: $LogFile"

    # --- Hand what is left to Claude (a pending restart alone is nothing it can act on)
    $forClaude = @($script:Handoff | Where-Object { $_.source -ne 'this run' })
    if ($forClaude.Count -gt 0 -and -not $NoClaude) { Start-ClaudeHandoff }

    # Started with -File means this window closes on exit, so leave the result up for a moment.
    if ($script:Live -and ([Environment]::GetCommandLineArgs() -contains '-File')) {
        Wait-Animated 10
    }
}

# Dot-sourcing (. .\Update-AllApps.ps1) loads the functions without running a
# update, which the display tests rely on.
if ($MyInvocation.InvocationName -eq '.') { return }

$script:ExitCode = 0
try {
    if ($ChildStep)         { Invoke-ChildStep }
    elseif (Invoke-Rehost)  { }                    # the whole run happened in a Windows Terminal window
    elseif ($Demo)          { Invoke-Demo }
    else                    { Invoke-Update }
} catch {
    $script:Live = $false
    Write-Log ('Unexpected error at line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) 'ERROR'
    $script:ExitCode = 1
} finally {
    # Record anything that failed quietly, so a hidden run still leaves a trace.
    # (Not from the copy that only handed the run to Windows Terminal: the log belongs to the other one.)
    if (-not $script:Rehosted) {
        foreach ($problem in @($Error | Select-Object -First 10)) {
            $where = ''
            if ($problem.InvocationInfo) { $where = ' (line {0})' -f $problem.InvocationInfo.ScriptLineNumber }
            Add-Content -Path $LogFile -Encoding utf8 -Value ('[{0}] [DEBUG] quiet error{1}: {2}' -f (Get-Date -Format 'HH:mm:ss'), $where, "$problem".Trim())
        }
    }
    # Tell the copy that started this one how it ended.
    if ($RehostPidFile) { Add-Content -Path $RehostPidFile -Value "exit=$($script:ExitCode)" -Encoding ascii -ErrorAction SilentlyContinue }
    if ($script:Live -and -not $script:Rehosted -and -not $ChildStep) {
        try { [Console]::CursorVisible = $true } catch {}
        if ($script:Handoff.Count -gt 0) {
            Write-Host ''
            Write-Host ("  {0} item(s) need attention: {1}" -f $script:Handoff.Count, $HandoffMd) -ForegroundColor Yellow
            if ($script:ClaudeStarted) {
                Write-Host '  Claude has been started to work through them. Its report goes in leftovers-report.md.' -ForegroundColor Yellow
            } else {
                Write-Host '  Ask Claude: "handle my update leftovers"' -ForegroundColor Yellow
            }
        }
    }
}
exit $script:ExitCode
