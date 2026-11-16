# A stand-in for winget, used to exercise the bot's parallel scheduler without
# installing anything. What it does is chosen by markers in the --id.
$a = $args
$cmd = $a[0]
function ArgVal($name) { for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -eq $name) { return $a[$i + 1] } }; $null }
$id = ArgVal '--id'
$state = Join-Path $env:TEMP 'fakewinget-state'
New-Item -ItemType Directory -Force $state | Out-Null
$marker = Join-Path $state ($id -replace '[^A-Za-z0-9.]', '_')

switch ($cmd) {
    'show' {
        "Found $id [$id] Version 9.9.9"
        "Installer Type: nullsoft"
        "Installer Url: https://example.invalid/none.exe"
        exit 0
    }
    'list' {
        # Report the newer version, except for an id marked NOCHANGE, which stays put.
        $ver = '9.9.9'
        if ($id -match 'NOCHANGE') { $ver = '1.0.0' }
        $w = [math]::Max(13, $id.Length)
        ("{0,-$w} {1,-$w} {2,-9} {3,-9} {4}" -f 'Name', 'Id', 'Version', 'Available', 'Source')
        ('-' * ($w * 2 + 30))
        ("{0,-$w} {1,-$w} {2,-9} {3,-9} {4}" -f $id, $id, $ver, '9.9.9', 'winget')
        exit 0
    }
    'upgrade' {
        "Found $id [$id] Version 9.9.9"
        "Downloading https://example.invalid/none.exe"
        Start-Sleep -Milliseconds 1200
        if ($id -match 'MUTEX' -and -not (Test-Path "$marker.mutex")) {
            New-Item -ItemType File -Force "$marker.mutex" | Out-Null
            "Another installation is already in progress. Try again later."
            exit 1
        }
        if ($id -match 'INUSE') {
            "Files modified by the installer are currently in use by a different application."
            exit 1
        }
        if ($id -match 'HARDFAIL') {
            "No applicable upgrade found."
            exit 1
        }
        "Starting package install..."
        Start-Sleep -Milliseconds 900
        "Successfully installed"
        exit 0
    }
    default { "unknown fake command $cmd"; exit 2 }
}
