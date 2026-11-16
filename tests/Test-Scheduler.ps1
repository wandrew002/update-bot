<#
    Exercises the bot's parallel scheduler against a pretend winget
    (fakewinget.cmd): several installs at once, the one-at-a-time lane for
    installers that take the Windows Installer lock, a retry after a lock
    clash, a version that changes nothing, an app whose files are in use, and
    a plain failure. Also runs a step alongside as its own process, the way a
    real run does with Steam and the NVIDIA driver. Installs nothing.

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File Test-Scheduler.ps1 [-Script <path to Update-AllApps.ps1>]
#>
param([string]$Script = (Join-Path (Split-Path $PSScriptRoot) 'Update-AllApps.ps1'))

. $Script -Demo -NoElevate
$script:Live    = $false
$script:Winget  = Join-Path $PSScriptRoot 'fakewinget.cmd'
$LogDir         = Join-Path $env:TEMP 'updatebot-test'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$LogFile        = Join-Path $LogDir 'scheduler-test.log'
$MemoFile       = Join-Path $LogDir 'installed-versions.json'
$NoChangeFile   = Join-Path $LogDir 'no-change-versions.json'
Remove-Item $LogFile, $MemoFile, $NoChangeFile -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'fakewinget-state') -Recurse -Force -ErrorAction SilentlyContinue
$script:Handoff = New-Object System.Collections.Generic.List[object]

function T($id, $name, $serial) {
    [pscustomobject]@{
        Id = $id; Name = $name; Version = '1.0.0'; Available = '9.9.9'
        Type = ''; Url = ''; Serial = $serial; TotalBytes = 0.0; Staged = 0.0
        State = 'queued'; Pct = $null; Tries = 0; Force = $false
        Proc = $null; OutFile = $null; ErrFile = $null; Started = $null
    }
}
$tasks = @(
    (T 'App.Alpha'          'Alpha'   $false)
    (T 'App.Beta'           'Beta'    $false)
    (T 'App.Gamma.NOCHANGE' 'Gamma'   $false)
    (T 'App.Delta.MUTEX'    'Delta'   $true)
    (T 'App.Epsilon'        'Epsilon' $true)
    (T 'App.Zeta.HARDFAIL'  'Zeta'    $false)
    (T 'App.Eta.INUSE'      'Eta'     $false)
    (T 'App.Theta'          'Theta'   $false)
)
foreach ($t in $tasks) { [void](Add-Item -Key $t.Id -Label $t.Name -State 'queued') }
$script:UI.Total = $tasks.Count + 1

# A real step, run as its own process alongside (the NVIDIA check changes nothing when the driver is current).
$startedChild = Start-ChildStep 'Nvidia'

$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Invoke-WingetBatch $tasks 3
Wait-ChildSteps
$sw.Stop()

$expect = @{ Alpha = 'done'; Beta = 'done'; Gamma = 'skip'; Delta = 'done'; Epsilon = 'done'; Zeta = 'failed'; Eta = 'skip'; Theta = 'done' }
$bad = 0
"=== result: ok=$($res.ok) failed=$($res.failed) unchanged=$($res.unchanged) in $([int]$sw.Elapsed.TotalSeconds)s ==="
foreach ($it in $script:UI.Items) {
    $want = $expect[$it.Label]
    $flag = ''
    if ($want -and $it.State -ne $want) { $flag = "   <-- expected $want"; $bad++ }
    '{0,-28} {1,-8} {2}{3}' -f $it.Label, $it.State, $it.Note, $flag
}
"alongside step started: $startedChild; still waiting: $($script:Children.Count)"
"no-change memo: " + ((Get-NoChangeMemo).Keys -join ', ')
"hand-off: " + (($script:Handoff | ForEach-Object { '{0} [{1}]' -f $_.name, $_.source }) -join '; ')
if ($res.ok -ne 5 -or $res.failed -ne 2 -or $res.unchanged -ne 1) { $bad++; 'COUNTS ARE WRONG (expected ok=5 failed=2 unchanged=1)' }
if (-not (Get-NoChangeMemo).ContainsKey('App.Gamma.NOCHANGE')) { $bad++; 'NO-CHANGE MEMO MISSING' }
if ($bad -eq 0) { 'ALL CHECKS PASSED' } else { "$bad CHECK(S) FAILED" }
exit $bad
