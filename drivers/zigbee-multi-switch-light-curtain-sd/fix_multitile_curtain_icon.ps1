# ==============================================================================
# fix_multitile_curtain_icon.ps1
#
# Fixes two bugs in the Zigbee Multi Switch Light Curtain driver:
#
#   BUG 1 - Multi-tile dashboard tiles not showing in mixed mode
#            deviceconfig-4gang-mixed.json dashboard only had switch2/switch.
#            The mixed-multi profile had no dedicated deviceconfig at all.
#            Fix: patch deviceconfig-4gang-mixed.json for the single-tile
#            mixed profile, and create deviceconfig-4gang-mixed-multi.json
#            for the multi-tile mixed profile with curtain1/main02/main04 tiles.
#
#   BUG 2 - Curtain child device shows generic icon instead of shade icon
#            child-curtain.yml had vid: "generic-blinds" (unresolvable community
#            VID) which falls back to the generic device icon.
#            Fix: remove the metadata block so SmartThings derives the icon
#            from category: Blinds + windowShade capability (correct shade icon).
#
# Usage (run from inside the driver folder):
#   cd <driver_folder>
#   .\fix_multitile_curtain_icon.ps1
# ==============================================================================

$driverRoot = $PSScriptRoot
$token      = "ae346eea-2737-49b1-94b6-683a0ff1cc74"
$headers    = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
$baseUrl    = "https://api.smartthings.com/v1"

Write-Host ""
Write-Host "=== fix_multitile_curtain_icon.ps1 ===" -ForegroundColor Cyan
Write-Host "Driver root: $driverRoot"
Write-Host ""

# ==============================================================================
# STEP 1a - Patch deviceconfig-4gang-mixed.json
#           Single-tile mixed profile (smarthome4u-4gang-switch-mixed-v2)
#           Dashboard shows curtain1/windowShade as the primary tile.
# ==============================================================================
Write-Host "STEP 1a: Patching deviceconfig-4gang-mixed.json ..." -ForegroundColor Yellow

$mixedFile = Join-Path $driverRoot "deviceconfig-4gang-mixed.json"
if (-not (Test-Path $mixedFile)) {
    Write-Host "  ERROR: $mixedFile not found." -ForegroundColor Red
    pause; exit 1
}

$backupMixed = $mixedFile -replace '\.json$', '.backup.json'
if (-not (Test-Path $backupMixed)) {
    Copy-Item $mixedFile $backupMixed
    Write-Host "  Backup: $backupMixed" -ForegroundColor DarkGray
}

# Single-tile version: curtain1 windowShade as the dashboard primary
$mixedJson = @'
{
  "type": "profile",
  "dashboard": {
    "states": [
      { "component": "curtain1", "capability": "windowShade", "version": 1, "group": "main", "composite": false }
    ],
    "actions": [
      { "component": "curtain1", "capability": "windowShade", "version": 1, "group": "main" }
    ]
  },
  "detailView": [
    { "component": "curtain1",    "capability": "windowShade",                     "version": 1 },
    { "component": "main",        "capability": "signalStrength",                  "version": 1 },
    { "component": "main",        "capability": "switch",                          "version": 1 },
    { "component": "switch2",     "capability": "switch",                          "version": 1 },
    { "component": "switch4",     "capability": "switch",                          "version": 1 },
    { "component": "channeltype1","capability": "vehiclepatch55148.channelType",   "version": 1 },
    { "component": "channeltype2","capability": "vehiclepatch55148.channelType",   "version": 1 },
    { "component": "backlight",   "capability": "perfectworld33337.backlightMode", "version": 1 },
    { "component": "childlock",   "capability": "perfectworld33337.childLockMode", "version": 1 }
  ],
  "automation": {
    "conditions": [
      { "component": "curtain1",    "capability": "windowShade",                     "version": 1 },
      { "component": "main",        "capability": "switch",                          "version": 1 },
      { "component": "switch2",     "capability": "switch",                          "version": 1 },
      { "component": "switch4",     "capability": "switch",                          "version": 1 },
      { "component": "channeltype1","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "channeltype2","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "backlight",   "capability": "perfectworld33337.backlightMode", "version": 1 },
      { "component": "childlock",   "capability": "perfectworld33337.childLockMode", "version": 1 }
    ],
    "actions": [
      { "component": "curtain1",    "capability": "windowShade",                     "version": 1 },
      { "component": "main",        "capability": "switch",                          "version": 1 },
      { "component": "switch2",     "capability": "switch",                          "version": 1 },
      { "component": "switch4",     "capability": "switch",                          "version": 1 },
      { "component": "channeltype1","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "channeltype2","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "backlight",   "capability": "perfectworld33337.backlightMode", "version": 1 },
      { "component": "childlock",   "capability": "perfectworld33337.childLockMode", "version": 1 }
    ]
  }
}
'@

[System.IO.File]::WriteAllText($mixedFile, $mixedJson, [System.Text.Encoding]::UTF8)
Write-Host "  Patched: deviceconfig-4gang-mixed.json" -ForegroundColor Green

# ==============================================================================
# STEP 1b - Create deviceconfig-4gang-mixed-multi.json  (new file)
#           Multi-tile mixed profile (smarthome4u-4gang-switch-mixed-multi-v3)
#           Dashboard has 3 separate tiles: curtain1 / main02 / main04
# ==============================================================================
Write-Host ""
Write-Host "STEP 1b: Creating deviceconfig-4gang-mixed-multi.json ..." -ForegroundColor Yellow

$mixedMultiFile = Join-Path $driverRoot "deviceconfig-4gang-mixed-multi.json"

$mixedMultiJson = @'
{
  "type": "profile",
  "dashboard": {
    "states": [
      { "component": "curtain1", "capability": "windowShade", "version": 1, "group": "curtain1", "composite": false },
      { "component": "main02",   "capability": "switch",      "version": 1, "group": "main02",   "composite": false },
      { "component": "main04",   "capability": "switch",      "version": 1, "group": "main04",   "composite": false }
    ],
    "actions": [
      { "component": "curtain1", "capability": "windowShade", "version": 1, "group": "curtain1" },
      { "component": "main02",   "capability": "switch",      "version": 1, "group": "main02"   },
      { "component": "main04",   "capability": "switch",      "version": 1, "group": "main04"   }
    ]
  },
  "detailView": [
    { "component": "curtain1",    "capability": "windowShade",                     "version": 1 },
    { "component": "main",        "capability": "signalStrength",                  "version": 1 },
    { "component": "main",        "capability": "switch",                          "version": 1 },
    { "component": "main02",      "capability": "switch",                          "version": 1 },
    { "component": "main04",      "capability": "switch",                          "version": 1 },
    { "component": "channeltype1","capability": "vehiclepatch55148.channelType",   "version": 1 },
    { "component": "channeltype2","capability": "vehiclepatch55148.channelType",   "version": 1 },
    { "component": "backlight",   "capability": "perfectworld33337.backlightMode", "version": 1 },
    { "component": "childlock",   "capability": "perfectworld33337.childLockMode", "version": 1 }
  ],
  "automation": {
    "conditions": [
      { "component": "curtain1",    "capability": "windowShade",                     "version": 1 },
      { "component": "main",        "capability": "switch",                          "version": 1 },
      { "component": "main02",      "capability": "switch",                          "version": 1 },
      { "component": "main04",      "capability": "switch",                          "version": 1 },
      { "component": "channeltype1","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "channeltype2","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "backlight",   "capability": "perfectworld33337.backlightMode", "version": 1 },
      { "component": "childlock",   "capability": "perfectworld33337.childLockMode", "version": 1 }
    ],
    "actions": [
      { "component": "curtain1",    "capability": "windowShade",                     "version": 1 },
      { "component": "main",        "capability": "switch",                          "version": 1 },
      { "component": "main02",      "capability": "switch",                          "version": 1 },
      { "component": "main04",      "capability": "switch",                          "version": 1 },
      { "component": "channeltype1","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "channeltype2","capability": "vehiclepatch55148.channelType",   "version": 1 },
      { "component": "backlight",   "capability": "perfectworld33337.backlightMode", "version": 1 },
      { "component": "childlock",   "capability": "perfectworld33337.childLockMode", "version": 1 }
    ]
  }
}
'@

[System.IO.File]::WriteAllText($mixedMultiFile, $mixedMultiJson, [System.Text.Encoding]::UTF8)
Write-Host "  Created: deviceconfig-4gang-mixed-multi.json" -ForegroundColor Green

# ==============================================================================
# STEP 2 - Patch profiles/child-curtain.yml  (BUG 2)
# ==============================================================================
Write-Host ""
Write-Host "STEP 2: Patching profiles/child-curtain.yml ..." -ForegroundColor Yellow

$childFile = Join-Path $driverRoot "profiles\child-curtain.yml"
if (-not (Test-Path $childFile)) {
    Write-Host "  ERROR: $childFile not found." -ForegroundColor Red
    pause; exit 1
}

$backupChild = $childFile -replace '\.yml$', '.backup.yml'
if (-not (Test-Path $backupChild)) {
    Copy-Item $childFile $backupChild
    Write-Host "  Backup: $backupChild" -ForegroundColor DarkGray
}

$newChildYml = @'
id: child-curtain
name: child-curtain
components:
  - id: main
    capabilities:
      - id: windowShade
      - id: windowShadeLevel
      - id: healthCheck
      - id: refresh
    categories:
      - name: Blinds
'@

[System.IO.File]::WriteAllText($childFile, $newChildYml, [System.Text.Encoding]::UTF8)
Write-Host "  Patched: profiles/child-curtain.yml (removed vid: generic-blinds)" -ForegroundColor Green

# ==============================================================================
# STEP 3 - Upload both deviceconfigs via POST /presentation/deviceconfig
#          Each POST creates a new presentationId (VID) which is patched back
#          into the corresponding profile YML.
# ==============================================================================
Write-Host ""
Write-Host "STEP 3: Uploading deviceconfigs to SmartThings API ..." -ForegroundColor Yellow

$uploads = @(
    @{
        file    = $mixedFile
        label   = "deviceconfig-4gang-mixed.json"
        profile = "profiles\smarthome4u-4gang-switch-mixed-v2.yml"
    },
    @{
        file    = $mixedMultiFile
        label   = "deviceconfig-4gang-mixed-multi.json"
        profile = "profiles\smarthome4u-4gang-switch-mixed-multi-v3.yml"
    }
)

$results = @()

foreach ($u in $uploads) {
    Write-Host ""
    Write-Host "  $($u.label) ..." -ForegroundColor Yellow

    $body        = [System.IO.File]::ReadAllText($u.file, [System.Text.Encoding]::UTF8)
    $profilePath = Join-Path $driverRoot $u.profile

    try {
        $resp = Invoke-RestMethod `
            -Uri "$baseUrl/presentation/deviceconfig" `
            -Method POST `
            -Headers $headers `
            -Body $body

        $newVid = $resp.presentationId
        Write-Host "    OK - VID: $newVid" -ForegroundColor Green

        if (Test-Path $profilePath) {
            $yml = [System.IO.File]::ReadAllText($profilePath, [System.Text.Encoding]::UTF8)
            if ($yml -match 'vid:\s*\S+') {
                $yml = [regex]::Replace($yml, '(vid:\s*)\S+', "`${1}$newVid")
            } else {
                $yml = [regex]::Replace($yml, '(mnmn:\s*\S+)', "`$1`n  vid: $newVid")
            }
            [System.IO.File]::WriteAllText($profilePath, $yml, [System.Text.Encoding]::UTF8)
            Write-Host "    Patched VID in $($u.profile)" -ForegroundColor Cyan
        } else {
            Write-Host "    WARNING: profile not found: $profilePath" -ForegroundColor DarkYellow
        }

        $results += [PSCustomObject]@{ File = $u.label; VID = $newVid; Status = "OK" }

    } catch {
        Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host "    Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
        $results += [PSCustomObject]@{ File = $u.label; VID = "ERROR"; Status = "FAILED" }
    }
}

# ==============================================================================
# Summary
# ==============================================================================
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$failed = ($results | Where-Object { $_.Status -eq "FAILED" }).Count
if ($failed -eq 0) {
    Write-Host "All patches applied successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "What was fixed:" -ForegroundColor Cyan
    Write-Host "  BUG 1  deviceconfig-4gang-mixed.json       - dashboard uses curtain1/windowShade" -ForegroundColor White
    Write-Host "         deviceconfig-4gang-mixed-multi.json - 3 dashboard tiles: curtain1 | main02 | main04" -ForegroundColor White
    Write-Host "  BUG 2  profiles/child-curtain.yml          - removed vid:generic-blinds, uses Blinds category icon" -ForegroundColor White
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    $cli = Join-Path (Split-Path $driverRoot -Parent) "smartthings.exe"
    Write-Host "  1.  & '$cli' edge:drivers:package ." -ForegroundColor Gray
    Write-Host "  2.  & '$cli' edge:drivers:install" -ForegroundColor Gray
    Write-Host "  3. Delete the device in SmartThings app, re-add it, clear app cache" -ForegroundColor Gray
} else {
    Write-Host "$failed upload(s) failed. Local file patches were still applied." -ForegroundColor Red
    Write-Host "Fix the API error and re-run the script." -ForegroundColor DarkYellow
}

Write-Host ""
pause
