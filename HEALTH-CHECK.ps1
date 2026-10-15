$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $PSScriptRoot
$devId = '7cd5ac18-6432-41c6-b298-d0bd6b5bf757'
$hubId = 'c9e6b370-41a7-499a-ae95-3496747cd165'
$drvId = '8a672fc6-aee8-4b64-a138-f55346366687'
$outFile = Join-Path $PSScriptRoot 'docs\LAST-HEALTH-CHECK.txt'
$records = @('[C.P EDGE CHECK] v1.1.3','Device: ' + $devId, 'Driver: ' + $drvId, 'Hub: ' + $hubId)
$commands = @(
    @('devices:health', $devId, '-j'),
    @('devices:preferences', $devId, '-j'),
    @('edge:drivers:installed', '--hub=' + $hubId, '-j')
)
foreach ($argsSet in $commands) {
    $records += ('=== smartthings ' + ($argsSet -join ' ') + ' ===')
    $records += (& smartthings @argsSet 2>&1 | Out-String)
}
[System.IO.File]::WriteAllText($outFile, ($records -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Saved: ' + $outFile) -ForegroundColor Cyan
Write-Host 'Send docs/LAST-HEALTH-CHECK.txt if still OFFLINE. Edge logcat is also needed for HEALTH_API_REJECTED / TCP CONNECT FAILED.'
