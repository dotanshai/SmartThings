# ==============================================================================
# fix_4gang_multi_vid.ps1
# Uploads corrected deviceconfig-4gang-multi.json (all-light multi-tile layout
# with group+composite fields) and patches the new VID into the profile.
# Also uploads deviceconfig-6gang-multi.json which has the same fix.
# Run from inside the driver folder.
# ==============================================================================

$driverRoot = $PSScriptRoot
$token   = "ae346eea-2737-49b1-94b6-683a0ff1cc74"
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
$baseUrl = "https://api.smartthings.com/v1"

Write-Host ""
Write-Host "=== Fix all-light multi-tile VIDs ===" -ForegroundColor Cyan
Write-Host ""

$uploads = @(
    @{ file="deviceconfig-4gang-multi.json"; profile="profiles\smarthome4u-4gang-switch-multi-v2.yml"; label="4-gang all-light multi" },
    @{ file="deviceconfig-6gang-multi.json"; profile="profiles\smarthome4u-6gang-switch-multi-v2.yml"; label="6-gang all-light multi" }
)

foreach ($u in $uploads) {
    $filePath    = Join-Path $driverRoot $u.file
    $profilePath = Join-Path $driverRoot $u.profile

    Write-Host "--- $($u.label) ---" -ForegroundColor Yellow

    # Verify group/composite present
    $obj = [System.IO.File]::ReadAllText($filePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $hasGroup = $true
    foreach ($s in $obj.dashboard.states) {
        if (-not $s.group) { $hasGroup = $false }
    }
    if (-not $hasGroup) {
        Write-Host "  ERROR: Missing group fields in $($u.file)" -ForegroundColor Red
        continue
    }

    $dashComps = $obj.dashboard.states | ForEach-Object { $_.component }
    Write-Host "  Layout: $($dashComps -join ', ')" -ForegroundColor Green

    $body = [System.IO.File]::ReadAllText($filePath, [System.Text.UTF8Encoding]::new($false))
    try {
        $r = Invoke-RestMethod -Uri "$baseUrl/presentation/deviceconfig" -Method POST -Headers $headers -Body $body
        $newVid = $r.presentationId
        Write-Host "  New VID: $newVid" -ForegroundColor Green

        $yml = [System.IO.File]::ReadAllText($profilePath, [System.Text.UTF8Encoding]::new($false))
        $yml = $yml.TrimStart([char]0xFEFF)
        if ($yml -match 'vid:\s*\S+') {
            $yml = $yml -replace '(vid:\s*)\S+', "`${1}$newVid"
        } else {
            $yml = $yml -replace '(mnmn:\s*\S+)', "`$1`n  vid: $newVid"
        }
        [System.IO.File]::WriteAllText($profilePath, $yml, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Patched VID into $($u.profile)" -ForegroundColor Cyan

    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host "  Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
    }
    Write-Host ""
}

Write-Host "=== Done! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
$cli = Join-Path (Split-Path $driverRoot -Parent) "smartthings.exe"
Write-Host "  1. Package + install:" -ForegroundColor White
Write-Host "     & '$cli' edge:drivers:package ." -ForegroundColor Gray
Write-Host "     & '$cli' edge:drivers:install" -ForegroundColor Gray
Write-Host "  2. Toggle Multi-Tile OFF then ON in device settings" -ForegroundColor White
Write-Host ""
pause
