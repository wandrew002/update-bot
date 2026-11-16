<# Promote only a source copy that passes parsing and its complete self-test. #>
[CmdletBinding()]
param(
    [string]$WorkScript,
    [string]$LiveScript
)
$ErrorActionPreference = 'Stop'
if (-not $WorkScript) { $WorkScript = Join-Path $PSScriptRoot 'Update-AllApps.ps1' }
if (-not $LiveScript) { $LiveScript = Join-Path (Split-Path $PSScriptRoot) 'Update-AllApps.ps1' }
try {
    $work = (Resolve-Path -LiteralPath $WorkScript).Path
    $live = [IO.Path]::GetFullPath($LiveScript)
    if ($work -eq $live) { throw 'Work and live paths must be different.' }
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($work, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors -join "`n") }
    $hash = (Get-FileHash -LiteralPath $work -Algorithm SHA256).Hash
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $work -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'Self-test failed; live copy was not changed.' }
    if ((Get-FileHash -LiteralPath $work -Algorithm SHA256).Hash -ne $hash) { throw 'Work copy changed during tests; rerun promotion.' }
    $defaultLive = Join-Path (Split-Path $PSScriptRoot) 'Update-AllApps.ps1'
    if ($live -eq $defaultLive -and (Get-ScheduledTask -TaskName 'Update All Apps' -ErrorAction Stop).State -eq 'Running') {
        throw 'The update task is running; wait before promoting.'
    }
    if (Test-Path -LiteralPath $live) {
        $backup = Join-Path $PSScriptRoot ('Update-AllApps.live-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.ps1')
        Copy-Item -LiteralPath $live -Destination $backup -ErrorAction Stop
        Write-Output "Backup: $backup"
    }
    Copy-Item -LiteralPath $work -Destination $live -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash -ne $hash) { throw 'Promoted file hash does not match work copy.' }
    Write-Output "Promoted: $live"
} catch { Write-Error $_; exit 1 }
