# ==============================================================================
# Upload device configurations + capability presentation
# Run from inside the driver folder:
#   cd C:\Users\dotan\Desktop\smartthings_win\Zigbee_Multi_Switch_Light_Curtain_SD_TEST
#   .\upload_presentations.ps1
#
# FIXES APPLIED:
#   - smarthome4u-4gang-switch-mixed-multi-v3: now gets its own VID (was sharing
#     with mixed-v2, causing multi-tile to always render as single-tile)
#   - child-curtain: replaced fabricated "generic-blinds" vid with a real uploaded VID
#     (generic-blinds does not exist; the upload script posts deviceconfig-child-curtain.json
#     and patches the returned real VID into child-curtain.yml automatically)
#   - tuya_multi_switch.lua: after device-type DPs settle the profile to mixed-multi,
#     children are now recreated (delete old all-light children, create curtain+light).
#     Previously the initial children (created before DPs arrived) were never replaced,
#     so the curtain child was missing and multi-tile showed wrong tiles.
#
# AFTER RUNNING THIS SCRIPT:
#   - Redeploy the driver (edge:drivers:package + edge:drivers:install)
#   - To fix the curtain child icon: toggle "Create Child Devices" OFF then ON
#     in device settings so the child is recreated with the new profile VID
# ==============================================================================

$driverRoot = $PSScriptRoot
$token   = "ae346eea-2737-49b1-94b6-683a0ff1cc74"
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
$baseUrl = "https://api.smartthings.com/v1"

Write-Host ""
Write-Host "=== SmartThings Upload (REST API) ===" -ForegroundColor Cyan
Write-Host "Driver root: $driverRoot"
Write-Host ""

# ── STEP 1: capability presentation already uploaded ──────────────────────────
Write-Host "STEP 1: capability presentation already uploaded - skipping" -ForegroundColor Gray

# ── STEP 2: POST device configs ───────────────────────────────────────────────
Write-Host ""
Write-Host "STEP 2: Uploading device configurations ..." -ForegroundColor Yellow

$presentations = @(
    @{ file="deviceconfig-2gang-single.json";       profile="profiles\smarthome4u-2gang-switch-v2.yml" },
    @{ file="deviceconfig-12gang.json";              profile="profiles\smarthome4u-12gang-switch-v2.yml" },
    @{ file="deviceconfig-12gang-c100000.json"; profile="profiles\smarthome4u-12gang-switch-c100000-v2.yml" },
    @{ file="deviceconfig-12gang-c010000.json"; profile="profiles\smarthome4u-12gang-switch-c010000-v2.yml" },
    @{ file="deviceconfig-12gang-c110000.json"; profile="profiles\smarthome4u-12gang-switch-c110000-v2.yml" },
    @{ file="deviceconfig-12gang-c001000.json"; profile="profiles\smarthome4u-12gang-switch-c001000-v2.yml" },
    @{ file="deviceconfig-12gang-c101000.json"; profile="profiles\smarthome4u-12gang-switch-c101000-v2.yml" },
    @{ file="deviceconfig-12gang-c011000.json"; profile="profiles\smarthome4u-12gang-switch-c011000-v2.yml" },
    @{ file="deviceconfig-12gang-c111000.json"; profile="profiles\smarthome4u-12gang-switch-c111000-v2.yml" },
    @{ file="deviceconfig-12gang-c000100.json"; profile="profiles\smarthome4u-12gang-switch-c000100-v2.yml" },
    @{ file="deviceconfig-12gang-c100100.json"; profile="profiles\smarthome4u-12gang-switch-c100100-v2.yml" },
    @{ file="deviceconfig-12gang-c010100.json"; profile="profiles\smarthome4u-12gang-switch-c010100-v2.yml" },
    @{ file="deviceconfig-12gang-c110100.json"; profile="profiles\smarthome4u-12gang-switch-c110100-v2.yml" },
    @{ file="deviceconfig-12gang-c001100.json"; profile="profiles\smarthome4u-12gang-switch-c001100-v2.yml" },
    @{ file="deviceconfig-12gang-c101100.json"; profile="profiles\smarthome4u-12gang-switch-c101100-v2.yml" },
    @{ file="deviceconfig-12gang-c011100.json"; profile="profiles\smarthome4u-12gang-switch-c011100-v2.yml" },
    @{ file="deviceconfig-12gang-c111100.json"; profile="profiles\smarthome4u-12gang-switch-c111100-v2.yml" },
    @{ file="deviceconfig-12gang-c000010.json"; profile="profiles\smarthome4u-12gang-switch-c000010-v2.yml" },
    @{ file="deviceconfig-12gang-c100010.json"; profile="profiles\smarthome4u-12gang-switch-c100010-v2.yml" },
    @{ file="deviceconfig-12gang-c010010.json"; profile="profiles\smarthome4u-12gang-switch-c010010-v2.yml" },
    @{ file="deviceconfig-12gang-c110010.json"; profile="profiles\smarthome4u-12gang-switch-c110010-v2.yml" },
    @{ file="deviceconfig-12gang-c001010.json"; profile="profiles\smarthome4u-12gang-switch-c001010-v2.yml" },
    @{ file="deviceconfig-12gang-c101010.json"; profile="profiles\smarthome4u-12gang-switch-c101010-v2.yml" },
    @{ file="deviceconfig-12gang-c011010.json"; profile="profiles\smarthome4u-12gang-switch-c011010-v2.yml" },
    @{ file="deviceconfig-12gang-c111010.json"; profile="profiles\smarthome4u-12gang-switch-c111010-v2.yml" },
    @{ file="deviceconfig-12gang-c000110.json"; profile="profiles\smarthome4u-12gang-switch-c000110-v2.yml" },
    @{ file="deviceconfig-12gang-c100110.json"; profile="profiles\smarthome4u-12gang-switch-c100110-v2.yml" },
    @{ file="deviceconfig-12gang-c010110.json"; profile="profiles\smarthome4u-12gang-switch-c010110-v2.yml" },
    @{ file="deviceconfig-12gang-c110110.json"; profile="profiles\smarthome4u-12gang-switch-c110110-v2.yml" },
    @{ file="deviceconfig-12gang-c001110.json"; profile="profiles\smarthome4u-12gang-switch-c001110-v2.yml" },
    @{ file="deviceconfig-12gang-c101110.json"; profile="profiles\smarthome4u-12gang-switch-c101110-v2.yml" },
    @{ file="deviceconfig-12gang-c011110.json"; profile="profiles\smarthome4u-12gang-switch-c011110-v2.yml" },
    @{ file="deviceconfig-12gang-c111110.json"; profile="profiles\smarthome4u-12gang-switch-c111110-v2.yml" },
    @{ file="deviceconfig-12gang-c000001.json"; profile="profiles\smarthome4u-12gang-switch-c000001-v2.yml" },
    @{ file="deviceconfig-12gang-c100001.json"; profile="profiles\smarthome4u-12gang-switch-c100001-v2.yml" },
    @{ file="deviceconfig-12gang-c010001.json"; profile="profiles\smarthome4u-12gang-switch-c010001-v2.yml" },
    @{ file="deviceconfig-12gang-c110001.json"; profile="profiles\smarthome4u-12gang-switch-c110001-v2.yml" },
    @{ file="deviceconfig-12gang-c001001.json"; profile="profiles\smarthome4u-12gang-switch-c001001-v2.yml" },
    @{ file="deviceconfig-12gang-c101001.json"; profile="profiles\smarthome4u-12gang-switch-c101001-v2.yml" },
    @{ file="deviceconfig-12gang-c011001.json"; profile="profiles\smarthome4u-12gang-switch-c011001-v2.yml" },
    @{ file="deviceconfig-12gang-c111001.json"; profile="profiles\smarthome4u-12gang-switch-c111001-v2.yml" },
    @{ file="deviceconfig-12gang-c000101.json"; profile="profiles\smarthome4u-12gang-switch-c000101-v2.yml" },
    @{ file="deviceconfig-12gang-c100101.json"; profile="profiles\smarthome4u-12gang-switch-c100101-v2.yml" },
    @{ file="deviceconfig-12gang-c010101.json"; profile="profiles\smarthome4u-12gang-switch-c010101-v2.yml" },
    @{ file="deviceconfig-12gang-c110101.json"; profile="profiles\smarthome4u-12gang-switch-c110101-v2.yml" },
    @{ file="deviceconfig-12gang-c001101.json"; profile="profiles\smarthome4u-12gang-switch-c001101-v2.yml" },
    @{ file="deviceconfig-12gang-c101101.json"; profile="profiles\smarthome4u-12gang-switch-c101101-v2.yml" },
    @{ file="deviceconfig-12gang-c011101.json"; profile="profiles\smarthome4u-12gang-switch-c011101-v2.yml" },
    @{ file="deviceconfig-12gang-c111101.json"; profile="profiles\smarthome4u-12gang-switch-c111101-v2.yml" },
    @{ file="deviceconfig-12gang-c000011.json"; profile="profiles\smarthome4u-12gang-switch-c000011-v2.yml" },
    @{ file="deviceconfig-12gang-c100011.json"; profile="profiles\smarthome4u-12gang-switch-c100011-v2.yml" },
    @{ file="deviceconfig-12gang-c010011.json"; profile="profiles\smarthome4u-12gang-switch-c010011-v2.yml" },
    @{ file="deviceconfig-12gang-c110011.json"; profile="profiles\smarthome4u-12gang-switch-c110011-v2.yml" },
    @{ file="deviceconfig-12gang-c001011.json"; profile="profiles\smarthome4u-12gang-switch-c001011-v2.yml" },
    @{ file="deviceconfig-12gang-c101011.json"; profile="profiles\smarthome4u-12gang-switch-c101011-v2.yml" },
    @{ file="deviceconfig-12gang-c011011.json"; profile="profiles\smarthome4u-12gang-switch-c011011-v2.yml" },
    @{ file="deviceconfig-12gang-c111011.json"; profile="profiles\smarthome4u-12gang-switch-c111011-v2.yml" },
    @{ file="deviceconfig-12gang-c000111.json"; profile="profiles\smarthome4u-12gang-switch-c000111-v2.yml" },
    @{ file="deviceconfig-12gang-c100111.json"; profile="profiles\smarthome4u-12gang-switch-c100111-v2.yml" },
    @{ file="deviceconfig-12gang-c010111.json"; profile="profiles\smarthome4u-12gang-switch-c010111-v2.yml" },
    @{ file="deviceconfig-12gang-c110111.json"; profile="profiles\smarthome4u-12gang-switch-c110111-v2.yml" },
    @{ file="deviceconfig-12gang-c001111.json"; profile="profiles\smarthome4u-12gang-switch-c001111-v2.yml" },
    @{ file="deviceconfig-12gang-c101111.json"; profile="profiles\smarthome4u-12gang-switch-c101111-v2.yml" },
    @{ file="deviceconfig-12gang-c011111.json"; profile="profiles\smarthome4u-12gang-switch-c011111-v2.yml" },
    @{ file="deviceconfig-12gang-c111111.json"; profile="profiles\smarthome4u-12gang-switch-c111111-v2.yml" },
    @{ file="deviceconfig-8gang-din.json";       profile="profiles\smarthome4u-8gang-din-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1000.json"; profile="profiles\smarthome4u-8gang-din-c1000-v2.yml" },
    @{ file="deviceconfig-8gang-din-c0100.json"; profile="profiles\smarthome4u-8gang-din-c0100-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1100.json"; profile="profiles\smarthome4u-8gang-din-c1100-v2.yml" },
    @{ file="deviceconfig-8gang-din-c0010.json"; profile="profiles\smarthome4u-8gang-din-c0010-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1010.json"; profile="profiles\smarthome4u-8gang-din-c1010-v2.yml" },
    @{ file="deviceconfig-8gang-din-c0110.json"; profile="profiles\smarthome4u-8gang-din-c0110-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1110.json"; profile="profiles\smarthome4u-8gang-din-c1110-v2.yml" },
    @{ file="deviceconfig-8gang-din-c0001.json"; profile="profiles\smarthome4u-8gang-din-c0001-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1001.json"; profile="profiles\smarthome4u-8gang-din-c1001-v2.yml" },
    @{ file="deviceconfig-8gang-din-c0101.json"; profile="profiles\smarthome4u-8gang-din-c0101-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1101.json"; profile="profiles\smarthome4u-8gang-din-c1101-v2.yml" },
    @{ file="deviceconfig-8gang-din-c0011.json"; profile="profiles\smarthome4u-8gang-din-c0011-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1011.json"; profile="profiles\smarthome4u-8gang-din-c1011-v2.yml" },
    @{ file="deviceconfig-8gang-din-c0111.json"; profile="profiles\smarthome4u-8gang-din-c0111-v2.yml" },
    @{ file="deviceconfig-8gang-din-c1111.json"; profile="profiles\smarthome4u-8gang-din-c1111-v2.yml" },
    @{ file="deviceconfig-2gang-curtain.json";        profile="profiles\smarthome4u-2gang-switch-curtain-v2.yml" },
    @{ file="deviceconfig-3gang-mixed-13.json";       profile="profiles\smarthome4u-3gang-switch-mixed-13-v2.yml" },
    @{ file="deviceconfig-3gang-mixed-13-multi.json"; profile="profiles\smarthome4u-3gang-switch-mixed-13-multi-v2.yml" },
    @{ file="deviceconfig-3gang-multi.json";        profile="profiles\smarthome4u-3gang-switch-multi-v2.yml" },
    @{ file="deviceconfig-3gang-single.json";       profile="profiles\smarthome4u-3gang-switch-v2.yml" },
    @{ file="deviceconfig-2gang-multi.json";        profile="profiles\smarthome4u-2gang-switch-multi-v2.yml" },
    @{ file="deviceconfig-4gang-single.json";       profile="profiles\smarthome4u-4gang-switch-v2.yml" },
    @{ file="deviceconfig-4gang-mixed.json";        profile="profiles\smarthome4u-4gang-switch-mixed-v2.yml" },
    @{ file="deviceconfig-4gang-mixed-multi.json";  profile="profiles\smarthome4u-4gang-switch-mixed-multi-v3.yml" },
    @{ file="deviceconfig-4gang-mixed-r.json";        profile="profiles\smarthome4u-4gang-switch-mixed-r-v2.yml" },
    @{ file="deviceconfig-4gang-multi.json";        profile="profiles\smarthome4u-4gang-switch-multi-v2.yml" },
    @{ file="deviceconfig-6gang-single.json";           profile="profiles\smarthome4u-6gang-switch-v2.yml" },
    @{ file="deviceconfig-6gang-multi.json";            profile="profiles\smarthome4u-6gang-switch-multi-v2.yml" },
    @{ file="deviceconfig-6gang-curtain.json";          profile="profiles\smarthome4u-6gang-switch-curtain-v2.yml" },
    @{ file="deviceconfig-6gang-curtain-multi.json";    profile="profiles\smarthome4u-6gang-switch-curtain-multi-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-l.json";          profile="profiles\smarthome4u-6gang-switch-mixed-l-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-l-multi.json";    profile="profiles\smarthome4u-6gang-switch-mixed-l-multi-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-m.json";          profile="profiles\smarthome4u-6gang-switch-mixed-m-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-m-multi.json";    profile="profiles\smarthome4u-6gang-switch-mixed-m-multi-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-r.json";          profile="profiles\smarthome4u-6gang-switch-mixed-r-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-r-multi.json";    profile="profiles\smarthome4u-6gang-switch-mixed-r-multi-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-lm.json";         profile="profiles\smarthome4u-6gang-switch-mixed-lm-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-lm-multi.json";   profile="profiles\smarthome4u-6gang-switch-mixed-lm-multi-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-lr.json";         profile="profiles\smarthome4u-6gang-switch-mixed-lr-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-lr-multi.json";   profile="profiles\smarthome4u-6gang-switch-mixed-lr-multi-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-mr.json";         profile="profiles\smarthome4u-6gang-switch-mixed-mr-v2.yml" },
    @{ file="deviceconfig-6gang-mixed-mr-multi.json";   profile="profiles\smarthome4u-6gang-switch-mixed-mr-multi-v2.yml" },
    @{ file="deviceconfig-4gang-mixed-r-multi.json"; profile="profiles\smarthome4u-4gang-switch-mixed-r-multi-v2.yml" },
    @{ file="deviceconfig-4gang-curtain.json";       profile="profiles\smarthome4u-4gang-switch-curtain-v2.yml" },
    @{ file="deviceconfig-4gang-curtain-multi.json"; profile="profiles\smarthome4u-4gang-switch-curtain-multi-v2.yml" },
    @{ file="deviceconfig-child-curtain.json";      profile="profiles\child-curtain.yml" },
    @{ file="deviceconfig-child-switch.json";       profile="profiles\child-switch.yml" }
)

$results = @()
foreach ($p in $presentations) {
    Write-Host ""
    Write-Host "  $($p.file) ..." -ForegroundColor Yellow
    $filePath    = Join-Path $driverRoot $p.file
    $profilePath = Join-Path $driverRoot $p.profile
    $body = Get-Content $filePath -Raw

    try {
        $r = Invoke-RestMethod `
            -Uri "$baseUrl/presentation/deviceconfig" `
            -Method POST -Headers $headers -Body $body
        $newVid = $r.presentationId
        Write-Host "    VID: $newVid" -ForegroundColor Green

        if (Test-Path $profilePath) {
            $yml = [System.IO.File]::ReadAllText($profilePath, [System.Text.UTF8Encoding]::new($false))
            $yml = $yml.TrimStart([char]0xFEFF)  # strip BOM if present
            if ($yml -match 'vid:\s*\S+') {
                $yml = $yml -replace '(vid:\s*)\S+', "`${1}$newVid"
            } else {
                $yml = $yml -replace '(mnmn:\s*\S+)', "`$1`n  vid: $newVid"
            }
            [System.IO.File]::WriteAllText($profilePath, $yml, [System.Text.UTF8Encoding]::new($false))
            Write-Host "    Patched VID in $($p.profile)" -ForegroundColor Cyan
        } else {
            Write-Host "    WARNING: profile not found: $profilePath" -ForegroundColor Red
        }
        $results += [PSCustomObject]@{ File=$p.file; VID=$newVid; Status="OK" }
    } catch {
        Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host "    Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
        $results += [PSCustomObject]@{ File=$p.file; VID="ERROR"; Status="FAILED" }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$failed = ($results | Where-Object { $_.Status -eq "FAILED" }).Count
if ($failed -eq 0) {
    Write-Host "All done!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    $cli = Join-Path (Split-Path $driverRoot -Parent) "smartthings.exe"
    Write-Host "  1. Package + install driver:" -ForegroundColor White
    Write-Host "     & '$cli' edge:drivers:package ." -ForegroundColor Gray
    Write-Host "     & '$cli' edge:drivers:install" -ForegroundColor Gray
    Write-Host "  2. In SmartThings app: DELETE the device, then re-add it" -ForegroundColor White
    Write-Host "  3. Clear app cache" -ForegroundColor White
} else {
    Write-Host "$failed config(s) failed." -ForegroundColor Red
}
Write-Host ""
pause
