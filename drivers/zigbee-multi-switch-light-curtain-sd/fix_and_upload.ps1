# ==============================================================================
# Fix & Upload via REST API directly (bypasses broken CLI -i flag)
# Run from inside the driver folder
# ==============================================================================

$driverRoot = $PSScriptRoot
$cli = Join-Path (Split-Path $driverRoot -Parent) "smartthings.exe"

Write-Host "=== Fix & Upload (REST API mode) ===" -ForegroundColor Cyan
Write-Host ""

# ── Get auth token from CLI ───────────────────────────────────────────────────
Write-Host "Getting auth token from CLI..." -ForegroundColor Yellow
Push-Location $driverRoot
$tokenRaw = (& $cli config:list --json 2>&1) -join " "
Pop-Location

# Extract token
if ($tokenRaw -match '"token"\s*:\s*"([^"]+)"') {
    $token = $Matches[1]
    Write-Host "  Token: $($token.Substring(0,12))..." -ForegroundColor Green
} else {
    # Try reading token from SmartThings config file directly
    $configFile = "$env:USERPROFILE\.config\@smartthings\cli\credentials.json"
    if (-not (Test-Path $configFile)) {
        $configFile = "$env:APPDATA\SmartThings\credentials.json"
    }
    if (Test-Path $configFile) {
        $creds = Get-Content $configFile | ConvertFrom-Json
        # Get first token
        $token = ($creds.PSObject.Properties | Select-Object -First 1).Value.accessToken
        Write-Host "  Token from config file: $($token.Substring(0,12))..." -ForegroundColor Green
    } else {
        Write-Host "  Could not get token automatically." -ForegroundColor Red
        Write-Host "  Run: smartthings config:list  and paste your token below:" -ForegroundColor Yellow
        $token = Read-Host "  Token"
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ── STEP 1: Patch presentation JSONs locally ──────────────────────────────────
Write-Host ""
Write-Host "STEP 1: Patching presentation JSONs..." -ForegroundColor Yellow
foreach ($f in (Get-ChildItem $driverRoot -Filter "presentation-*.json")) {
    $content = Get-Content $f.FullName -Raw
    $fixed = $content -replace '("capability":\s*"perfectworld33337\.)channeltype3(")', '${1}mschannelx55148${2}'
    $count = ([regex]::Matches($content, 'perfectworld33337\.channeltype3')).Count
    Set-Content $f.FullName $fixed -NoNewline
    Write-Host "  $($f.Name): fixed $count capability references" -ForegroundColor Green
}

# ── STEP 2: Upload capability presentation via REST ───────────────────────────
Write-Host ""
Write-Host "STEP 2: Uploading capability presentation via REST API..." -ForegroundColor Yellow
$capPresFile = Join-Path $driverRoot "channelType_presentation.json"
$capPresBody = Get-Content $capPresFile -Raw
try {
    $r = Invoke-RestMethod -Uri "https://api.smartthings.com/v1/capabilities/perfectworld33337.mschannelx55148/1/presentation" `
        -Method PUT -Headers $headers -Body $capPresBody
    Write-Host "  OK" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# ── STEP 3: Upload device presentations via REST ──────────────────────────────
Write-Host ""
Write-Host "STEP 3: Uploading device presentations via REST API..." -ForegroundColor Yellow

$presentations = @(
    @{ file="presentation-2gang-single.json"; vid="c33f2404-2e20-3e59-9553-4896b6a6bcb2"; profile="profiles\smarthome4u-2gang-switch.yml" },
    @{ file="presentation-2gang-multi.json";  vid="8ec132ba-89a8-3b3d-a90c-306c1fab0f9f"; profile="profiles\smarthome4u-2gang-switch-multi.yml" },
    @{ file="presentation-4gang-single.json"; vid="e745d931-ad3e-32ca-a909-f3330fd6d0cb"; profile="profiles\smarthome4u-4gang-switch.yml" },
    @{ file="presentation-4gang-mixed.json";  vid="e745d931-ad3e-32ca-a909-f3330fd6d0cb"; profile="profiles\smarthome4u-4gang-switch-mixed-v2.yml" },
    @{ file="presentation-4gang-multi.json";  vid="18ef04e0-6412-3e7c-8134-87aa06d1ffb6"; profile="profiles\smarthome4u-4gang-switch-multi.yml" },
    @{ file="presentation-6gang-single.json"; vid="ed3c4399-6de8-325b-b6fa-70bc743d0b8c"; profile="profiles\smarthome4u-6gang-switch.yml" },
    @{ file="presentation-6gang-multi.json";  vid="1ec03459-5f3a-37df-91f4-718228d371eb"; profile="profiles\smarthome4u-6gang-switch-multi.yml" }
)

$results = @()
foreach ($p in $presentations) {
    Write-Host ""
    Write-Host "  $($p.file) (VID: $($p.vid))..." -ForegroundColor Yellow
    $body = Get-Content (Join-Path $driverRoot $p.file) -Raw
    $profilePath = Join-Path $driverRoot $p.profile

    try {
        # PUT updates existing presentation by VID
        $r = Invoke-RestMethod `
            -Uri "https://api.smartthings.com/v1/presentation?vid=$($p.vid)&mnmn=SmartThingsCommunity" `
            -Method PUT -Headers $headers -Body $body
        $returnedVid = $r.vid
        Write-Host "    OK - returned VID: $returnedVid" -ForegroundColor Green

        # Patch profile YML with the VID
        if (Test-Path $profilePath) {
            $yml = Get-Content $profilePath -Raw
            $yml = $yml -replace '(vid:\s*)\S+', "`${1}$returnedVid"
            Set-Content $profilePath $yml -NoNewline
            Write-Host "    Patched $($p.profile)" -ForegroundColor Cyan
        }
        $results += [PSCustomObject]@{ File=$p.file; VID=$returnedVid; Status="OK" }
    } catch {
        Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{ File=$p.file; VID="ERROR"; Status="FAILED" }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$ok = ($results | Where-Object { $_.Status -eq "OK" }).Count
if ($ok -eq $results.Count) {
    Write-Host "All done! Now run:" -ForegroundColor Green
    Write-Host "  & '$cli' edge:drivers:install" -ForegroundColor Gray
    Write-Host "Then delete+re-add the device in the SmartThings app and clear app cache." -ForegroundColor Yellow
} else {
    Write-Host "$($results.Count - $ok) failed." -ForegroundColor Red
}
Write-Host ""
pause
