$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "==============================================="
Write-Host " C.P Phone GPS Edge Driver v1.0.7"
Write-Host "==============================================="
Write-Host ""

& smartthings --version
if ($LASTEXITCODE -ne 0) { throw "SmartThings CLI not available." }

$namespace = "buildbook37604"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-SmartThings([string[]]$CliArgs) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & smartthings @CliArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    return @{ ExitCode = $exitCode; Output = $output }
}

function Ensure-Capability([string]$shortId, [string]$file) {
    $fullId = "$namespace.$shortId"
    Write-Host "Capability: $fullId"

    # Current CLI: capabilities lookup does NOT accept -V here.
    $lookup = Invoke-SmartThings @("capabilities", $fullId, "-j")
    if ($lookup.ExitCode -eq 0) {
        Write-Host "  found"
        return
    }

    $create = Invoke-SmartThings @("capabilities:create", "-i", $file)
    if ($create.ExitCode -ne 0) {
        # If another previous install already created it, verify it now.
        if ([string]$create.Output -match "already exists") {
            $verify = Invoke-SmartThings @("capabilities", $fullId, "-j")
            if ($verify.ExitCode -eq 0) {
                Write-Host "  found"
                return
            }
        }
        Write-Host ([string]$create.Output)
        throw "Capability creation failed: $fullId"
    }

    Write-Host "  created"
}

function Update-CapabilityPresentation([string]$shortId, [string]$file) {
    $fullId = "$namespace.$shortId"
    Write-Host "Presentation: $fullId"

    $update = Invoke-SmartThings @(
        "capabilities:presentation:update",
        $fullId,
        "--capability-version", "1",
        "-i", $file
    )
    if ($update.ExitCode -eq 0) {
        Write-Host "  updated"
        return
    }

    $create = Invoke-SmartThings @(
        "capabilities:presentation:create",
        $fullId,
        "--capability-version", "1",
        "-i", $file
    )
    if ($create.ExitCode -eq 0) {
        Write-Host "  created"
        return
    }

    Write-Host ([string]$update.Output)
    Write-Host ([string]$create.Output)
    throw "Capability presentation failed: $fullId"
}

function Upsert-CapabilityTranslation([string]$shortId, [string]$file) {
    $fullId = "$namespace.$shortId"
    Write-Host "Translation: $fullId"

    $result = Invoke-SmartThings @(
        "capabilities:translations:upsert",
        $fullId,
        "--capability-version", "1",
        "-i", $file
    )
    if ($result.ExitCode -ne 0) {
        Write-Host ([string]$result.Output)
        throw "Capability translation failed: $fullId"
    }
    Write-Host "  updated"
}

Write-Host "[1/5] Custom Capabilities"
Ensure-Capability "phoneGpsSummary"  ".\capabilities\summary.json"
Ensure-Capability "phoneGpsLocation" ".\capabilities\location.json"
Ensure-Capability "phoneGpsInfo"     ".\capabilities\info.json"

Write-Host "[2/5] Capability Presentations"
Update-CapabilityPresentation "phoneGpsSummary"  ".\presentations\summary.json"
Update-CapabilityPresentation "phoneGpsLocation" ".\presentations\location.json"
Update-CapabilityPresentation "phoneGpsInfo"     ".\presentations\info.json"

Write-Host "[3/5] Korean Translations"
Upsert-CapabilityTranslation "phoneGpsSummary"  ".\translations\summary-ko.json"
Upsert-CapabilityTranslation "phoneGpsLocation" ".\translations\location-ko.json"
Upsert-CapabilityTranslation "phoneGpsInfo"     ".\translations\info-ko.json"

Write-Host "[4/5] Device Presentations (1~4 phones)"
for ($i = 1; $i -le 4; $i++) {
    $input = ".\device-configs\device-config-$i.json"
    $generated = ".\device-configs\generated-device-config-$i.json"

    if (Test-Path $generated) { Remove-Item $generated -Force }

    & smartthings presentation:device-config:create -i $input -o $generated -j
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $generated)) {
        throw "Device presentation creation failed for profile $i."
    }

    $generatedPath = (Resolve-Path $generated).Path
    $generatedText = [System.IO.File]::ReadAllText($generatedPath, $utf8NoBom)
    $dp = $generatedText | ConvertFrom-Json
    $vid = if ($dp.presentationId) { [string]$dp.presentationId } elseif ($dp.vid) { [string]$dp.vid } else { "" }
    $mnmn = if ($dp.manufacturerName) { [string]$dp.manufacturerName } elseif ($dp.mnmn) { [string]$dp.mnmn } else { "" }

    if ([string]::IsNullOrWhiteSpace($vid) -or [string]::IsNullOrWhiteSpace($mnmn)) {
        throw "Could not read VID/manufacturerName for profile $i."
    }

    $profilePath = ".\profiles\cp-phone-gps-$i.yml"
    $profileFullPath = (Resolve-Path $profilePath).Path
    $profile = [System.IO.File]::ReadAllText($profileFullPath, $utf8NoBom)
    $profile = [regex]::Replace($profile, '(?m)^\s*mnmn:\s*.*$', "  mnmn: $mnmn")
    $profile = [regex]::Replace($profile, '(?m)^\s*vid:\s*.*$', "  vid: $vid")
    [System.IO.File]::WriteAllText($profileFullPath, $profile, $utf8NoBom)
    Write-Host "  profile $i VID: $vid"
}

Write-Host "[5/5] Package + Install"
& smartthings edge:drivers:package . --install
if ($LASTEXITCODE -ne 0) { throw "Driver package/install failed." }

Write-Host ""
Write-Host "설치 완료"
Write-Host "SmartThings 앱을 완전히 종료 후 다시 실행하십시오."
Write-Host ""
