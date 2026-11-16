param([string]$Script = (Join-Path (Split-Path $PSScriptRoot) 'Update-AllApps.ps1'))
$ErrorActionPreference = 'Stop'
. $Script -Demo -NoElevate
$script:Live = $false
$script:DryRun = $false
$fixture = Join-Path $env:TEMP ('updatebot-maintenance-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$LogFile = Join-Path $fixture 'test.log'
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message }; "PASS $Message" }

# A failed pull must not prevent the next installed model from being checked.
$script:Calls = New-Object System.Collections.Generic.List[string]
function Invoke-Animated {
    param($File, $Arguments, $TimeoutSec)
    $script:Calls.Add(($Arguments -join ' '))
    if ($Arguments[0] -eq 'list') {
        return [pscustomobject]@{ExitCode=0; TimedOut=$false; StdOut="NAME ID SIZE MODIFIED`nfirst:latest abc 1 GB now`nsecond:latest def 2 GB now`n"; Output=''}
    }
    $failed = $Arguments[1] -eq 'first:latest'
    [pscustomobject]@{ExitCode=[int]$failed; TimedOut=$failed; StdOut=''; Output='fixture'}
}
Update-OllamaModels
Assert ($script:Calls.Count -eq 3 -and $script:Calls[2] -eq 'pull second:latest') 'pull continues after a failed model'
Assert (@($script:UI.Items | Where-Object { $_.Key -eq 'ollama-models' -and $_.State -eq 'failed' }).Count -eq 1) 'pull failure appears in the list'
$script:Calls.Clear(); $script:DryRun = $true
Update-OllamaModels
Assert ($script:Calls.Count -eq 1 -and $script:Calls[0] -eq 'list') 'dry run lists models without pulling'
$script:DryRun = $false

$root = Join-Path $fixture 'WinGet'
$outside = Join-Path $fixture 'outside'
New-Item -ItemType Directory -Path $root,$outside | Out-Null
$oldDate = (Get-Date).AddDays(-20)
foreach ($name in 'Old.App.1.0','Recent.App.1.0','Active.App.1.0','cache','Linked.App.1.0') {
    $dir = New-Item -ItemType Directory -Path (Join-Path $root $name)
    Set-Content -LiteralPath (Join-Path $dir.FullName 'installer.bin') -Value 'fixture'
    (Get-Item -LiteralPath (Join-Path $dir.FullName 'installer.bin')).LastWriteTime = $oldDate
    $dir.LastWriteTime = $oldDate
}
(Get-Item -LiteralPath (Join-Path $root 'Recent.App.1.0')).LastWriteTime = Get-Date
(Get-Item -LiteralPath (Join-Path $root 'Active.App.1.0\installer.bin')).LastWriteTime = Get-Date
Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'outside'
$junction = Join-Path $root 'Linked.App.1.0\junction'
New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
(Get-Item -LiteralPath (Join-Path $root 'Linked.App.1.0')).LastWriteTime = $oldDate
Remove-OldWingetInstallers -Root $root
Assert (-not (Test-Path -LiteralPath (Join-Path $root 'Old.App.1.0'))) 'old installer folder removed'
foreach ($name in 'Recent.App.1.0','Active.App.1.0','cache','Linked.App.1.0') {
    Assert (Test-Path -LiteralPath (Join-Path $root $name)) ("preserved $name")
}
Assert (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'junction target preserved'
Remove-OldWingetInstallers -Root $junction
Assert (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'linked root rejected'
$script:DryRun = $true
Remove-OldWingetInstallers -Root $root -Now (Get-Date).AddDays(100)
Assert (Test-Path -LiteralPath (Join-Path $root 'Recent.App.1.0')) 'dry run preserves old folders'
"Fixtures retained for inspection: $fixture"
'ALL CHECKS PASSED'
exit 0
