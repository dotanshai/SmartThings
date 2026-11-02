# fix_all.ps1
# Run from inside the driver folder (where config.yml lives).
#
# FIXES:
#   BUG 1+2  Child curtain generic icon and empty detail view.
#            Fix: set vid=generic-blinds in child-curtain.yml.
#            This is a built-in SmartThings VID - no API call needed.
#            Same pattern as child-switch.yml which uses vid=generic-switch.
#
#   BUG 3+4  Multi-tile dashboard missing curtain tile + top-right toggle.
#            Fix: set smarthome4u-4gang-switch-mixed-multi-v3 to use the same
#            VID as smarthome4u-4gang-switch-mixed-v2 (af2b2e68-e456-36a6-beb9-eac69635730e).
#            presentation-4gang-mixed.json is already uploaded to that VID and
#            already defines the correct 3-tile dashboard (curtain1/main02/main04)
#            plus main/switch in detailView for the top-right toggle.
#            No API call needed.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$driverRoot = $PSScriptRoot

Write-Host ""
Write-Host "=== fix_all.ps1 - Zigbee Multi Switch Light Curtain ===" -ForegroundColor Cyan
Write-Host "Driver root: $driverRoot"
Write-Host ""

if (-not (Test-Path (Join-Path $driverRoot "config.yml"))) {
    Write-Host "ERROR: config.yml not found. Run from the driver root folder." -ForegroundColor Red
    pause; exit 1
}

$profilesDir = Join-Path $driverRoot "profiles"
if (-not (Test-Path $profilesDir)) {
    Write-Host "ERROR: profiles\ folder not found." -ForegroundColor Red
    pause; exit 1
}

# ==============================================================================
# STEP 1  Patch child-curtain.yml: use vid=generic-blinds
#         Same as child-switch.yml uses vid=generic-switch.
#         No API call needed.
# ==============================================================================
Write-Host "STEP 1: Patching profiles\child-curtain.yml (vid=generic-blinds) ..." -ForegroundColor Yellow

$childYmlPath = Join-Path $profilesDir "child-curtain.yml"
if (-not (Test-Path $childYmlPath)) {
    Write-Host "  ERROR: child-curtain.yml not found." -ForegroundColor Red
    pause; exit 1
}

Copy-Item $childYmlPath (Join-Path $driverRoot "child-curtain.pre-fix.backup.yml") -Force
Write-Host "  Backup: child-curtain.pre-fix.backup.yml" -ForegroundColor DarkGray

$childLines = @(
    "id: child-curtain",
    "name: child-curtain",
    "components:",
    "  - id: main",
    "    capabilities:",
    "      - id: windowShade",
    "      - id: windowShadeLevel",
    "      - id: healthCheck",
    "      - id: refresh",
    "    categories:",
    "      - name: Blinds",
    "metadata:",
    '  vid: "generic-blinds"',
    '  mnmn: "SmartThingsCommunity"'
)
[System.IO.File]::WriteAllText(
    $childYmlPath,
    ($childLines -join "`n"),
    (New-Object System.Text.UTF8Encoding $false)
)
Write-Host "  OK - vid=generic-blinds written" -ForegroundColor Green

# ==============================================================================
# STEP 2  Patch smarthome4u-4gang-switch-mixed-multi-v3.yml
#         Use the same VID as smarthome4u-4gang-switch-mixed-v2:
#           af2b2e68-e456-36a6-beb9-eac69635730e
#         presentation-4gang-mixed.json is already uploaded to that VID and
#         already has the correct 3-tile dashboard + main/switch detailView.
#         No API call needed.
# ==============================================================================
Write-Host ""
Write-Host "STEP 2: Patching profiles\smarthome4u-4gang-switch-mixed-multi-v3.yml ..." -ForegroundColor Yellow

$mixedVid         = "af2b2e68-e456-36a6-beb9-eac69635730e"
$mixedMultiYmlPath = Join-Path $profilesDir "smarthome4u-4gang-switch-mixed-multi-v3.yml"

if (-not (Test-Path $mixedMultiYmlPath)) {
    Write-Host "  ERROR: smarthome4u-4gang-switch-mixed-multi-v3.yml not found." -ForegroundColor Red
    pause; exit 1
}

Copy-Item $mixedMultiYmlPath (Join-Path $driverRoot "smarthome4u-4gang-switch-mixed-multi-v3.pre-fix.backup.yml") -Force
Write-Host "  Backup: smarthome4u-4gang-switch-mixed-multi-v3.pre-fix.backup.yml" -ForegroundColor DarkGray

$yml = [System.IO.File]::ReadAllText($mixedMultiYmlPath, [System.Text.Encoding]::UTF8)

if ($yml -match '(?m)^\s*vid:\s*\S+') {
    $yml = [regex]::Replace($yml, '(?m)^(\s*vid:\s*)\S+', ('${1}"' + $mixedVid + '"'))
} elseif ($yml -match '(?m)^metadata:') {
    $yml = [regex]::Replace($yml, '(?m)^(metadata:)', ('${1}' + "`n" + '  vid: "' + $mixedVid + '"'))
} else {
    $yml = $yml.TrimEnd() + "`nmetadata:`n  vid: `"$mixedVid`"`n  mnmn: `"SmartThingsCommunity`"`n"
}

[System.IO.File]::WriteAllText($mixedMultiYmlPath, $yml, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  OK - vid=$mixedVid written" -ForegroundColor Green

# ==============================================================================
# STEP 3  Verify
# ==============================================================================
Write-Host ""
Write-Host "STEP 3: Verifying ..." -ForegroundColor Yellow

$ok = $true
if ((Get-Content $childYmlPath -Raw) -match 'generic-blinds') {
    Write-Host "  child-curtain.yml            vid=generic-blinds  OK" -ForegroundColor Green
} else {
    Write-Host "  child-curtain.yml            generic-blinds NOT FOUND" -ForegroundColor Red
    $ok = $false
}

if ((Get-Content $mixedMultiYmlPath -Raw) -match [regex]::Escape($mixedVid)) {
    Write-Host "  smarthome4u-...-multi-v3.yml vid=$mixedVid  OK" -ForegroundColor Green
} else {
    Write-Host "  smarthome4u-...-multi-v3.yml VID NOT FOUND" -ForegroundColor Red
    $ok = $false
}

# ==============================================================================
# Summary
# ==============================================================================
Write-Host ""
if ($ok) { Write-Host "=== All done! ===" -ForegroundColor Cyan } else { Write-Host "=== Done with warnings ===" -ForegroundColor DarkYellow }
Write-Host ""
Write-Host "What was fixed (no API calls - file edits only):" -ForegroundColor White
Write-Host "  BUG 1+2  child-curtain.yml -> vid=generic-blinds" -ForegroundColor White
Write-Host "           Blinds icon + windowShade detail view from built-in ST presentation" -ForegroundColor White
Write-Host "  BUG 3+4  mixed-multi-v3.yml -> vid=$mixedVid" -ForegroundColor White
Write-Host "           Shares presentation-4gang-mixed.json with mixed-v2 profile" -ForegroundColor White
Write-Host "           3-tile dashboard: curtain1 + main02 + main04" -ForegroundColor White
Write-Host "           main/switch in detailView = top-right toggle on parent tile" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1.  smartthings edge:drivers:package ." -ForegroundColor Gray
Write-Host "  2.  smartthings edge:drivers:install" -ForegroundColor Gray
Write-Host "  3.  Parent device -> 3-dot -> Driver -> switch to this driver" -ForegroundColor Gray
Write-Host "      (triggers driverSwitched + child recreation with new profiles)" -ForegroundColor Gray
Write-Host "  4.  Clear ST app cache." -ForegroundColor Gray
Write-Host ""
pause
