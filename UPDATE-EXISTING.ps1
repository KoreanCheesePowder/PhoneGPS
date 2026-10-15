$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
$DeviceHealthId = '7cd5ac18-6432-41c6-b298-d0bd6b5bf757'

$DriverId = "8a672fc6-aee8-4b64-a138-f55346366687"
$HubId = "c9e6b370-41a7-499a-ae95-3496747cd165"
$ChannelId = "cd373cad-c1db-4b2a-943b-6ed6fb51d2fa"
$DeviceId = "7cd5ac18-6432-41c6-b298-d0bd6b5bf757"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-CLI {
    param([string[]]$Arguments, [string]$Description)
    Write-Host ("[CLI] " + $Description) -ForegroundColor Cyan
    $before = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = (& smartthings @Arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $before
    }
    if ($exitCode -ne 0) {
        Write-Host $output
        throw ("CLI failed at " + $Description + ". ExitCode=" + $exitCode)
    }
    return $output
}

Write-Host "C.P Phone GPS v1.1.2 - EXISTING DRIVER UPDATE ONLY" -ForegroundColor Green
$null = Invoke-CLI -Arguments @('--version') -Description 'CLI version check'

# Abort rather than installing a new ID, which could disturb the registered device/rules.
$device = Invoke-CLI -Arguments @('devices', $DeviceId, '-j') -Description 'Existing device verification'
if ($device -notmatch [regex]::Escape($DriverId)) {
    throw "Registered Phone GPS device is not using the expected driver. No update attempted."
}
if ($device -notmatch [regex]::Escape($HubId)) {
    throw "Registered Phone GPS device has moved to another Hub. No update attempted."
}

# Preserve the current 2-phone SmartThings presentation VID. The other profiles
# have placeholders in the source archive and need a one-time device-config creation.
foreach ($n in @(1, 3, 4)) {
    $profile = Join-Path $PSScriptRoot ("profiles\\cp-phone-gps-{0}.yml" -f $n)
    $yaml = [System.IO.File]::ReadAllText($profile)
    if ($yaml -notmatch '(?m)^\s*vid:\s*REPLACE_ME\s*$') { continue }

    $inputFile = Join-Path $PSScriptRoot ("device-configs\\device-config-{0}.json" -f $n)
    $outputFile = Join-Path $PSScriptRoot ("device-configs\\generated-device-config-{0}.json" -f $n)
    if (Test-Path $outputFile) { Remove-Item -LiteralPath $outputFile -Force }

    $null = Invoke-CLI -Arguments @('presentation:device-config:create', '-i', $inputFile, '-o', $outputFile, '-j') -Description ("Presentation for {0} phones" -f $n)
    if (-not (Test-Path -LiteralPath $outputFile)) { throw "Presentation file was not created: $n" }

    $presentation = Get-Content -LiteralPath $outputFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $vid = if ($presentation.presentationId) { [string]$presentation.presentationId } else { [string]$presentation.vid }
    if ($vid -notmatch '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') { throw "Invalid presentation id: $n" }
    # Literal replacement prevents PowerShell regex back-reference ambiguity
    # for UUIDs starting with a digit (e.g. $19..., which is not group 1).
    if ($yaml.Split([string[]]@('vid: REPLACE_ME'), [System.StringSplitOptions]::None).Count -ne 2) {
        throw "Expected exactly one presentation placeholder in profile: $n"
    }
    $yaml = $yaml.Replace('vid: REPLACE_ME', ('vid: ' + $vid))
    if ($yaml -notmatch ('(?m)^\s*vid:\s*' + [regex]::Escape($vid) + '\s*$')) {
        throw "Presentation ID replacement failed in profile: $n"
    }
    [System.IO.File]::WriteAllText($profile, $yaml, $Utf8NoBom)
}

foreach ($n in 1..4) {
    $profile = Join-Path $PSScriptRoot ("profiles\cp-phone-gps-{0}.yml" -f $n)
    $content = [System.IO.File]::ReadAllText($profile)
    if ($content -match 'REPLACE_ME') { throw "Unresolved presentation id in profile: $n" }
    if ($content -notmatch '(?m)^  vid: [a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}\s*$') {
        throw "Invalid presentation metadata in profile: $n"
    }
    if ($content -notmatch '(?m)^preferences:\s*$') {
        throw "Preferences section missing in profile: $n"
    }
}

# Important CLI v2.x detail: --channel and --install are conflicting modes.
# Package+channel first, then install the SAME driverId to the SAME hub.
$null = Invoke-CLI -Arguments @('edge:drivers:package', '.', '--channel', $ChannelId) -Description 'Package existing driver and assign version to channel'
$null = Invoke-CLI -Arguments @('edge:drivers:install', $DriverId, '-H', $HubId, '-C', $ChannelId) -Description 'Install updated version on existing hub'

Write-Host '[VERIFY] Checking actual SmartThings device health...' -ForegroundColor Cyan
Start-Sleep -Seconds 16
$healthOut = (& smartthings devices:health $DeviceHealthId -j 2>&1 | Out-String)
$healthExit = $LASTEXITCODE
Write-Host $healthOut
$checkPath = Join-Path $PSScriptRoot 'docs\LAST-HEALTH-CHECK.txt'
[System.IO.File]::WriteAllText($checkPath, ('Device: ' + $DeviceHealthId + "`r`n" + $healthOut), (New-Object System.Text.UTF8Encoding($false)))
if ($healthExit -ne 0) {
  Write-Warning 'Installation command finished, but health verification failed. Send docs/LAST-HEALTH-CHECK.txt.'
} elseif ($healthOut -match '(?i)"state"\s*:\s*"OFFLINE"') {
  Write-Warning 'UPDATED DRIVER BUT DEVICE STILL OFFLINE. Hub TCP/API connectivity or Edge HEALTH_API_REJECTED must be checked in logcat.'
  Write-Host 'Run HEALTH-CHECK.cmd and send its output. Do not reinstall the device.' -ForegroundColor Yellow
} else {
  Write-Host 'Health check complete. Verify the printed ONLINE state, do not infer from installer success.' -ForegroundColor Green
}
