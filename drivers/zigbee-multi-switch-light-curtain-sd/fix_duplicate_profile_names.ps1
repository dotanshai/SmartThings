# ==============================================================================
# fix_duplicate_profile_names.ps1
#
# Diagnoses and fixes the "deviceProfiles.name cannot contain duplicates" error
# that occurs when edge:drivers:package rejects the driver.
#
# Scans all YML files in the profiles\ folder, finds any duplicate name: fields,
# shows exactly which files are duplicated, then fixes them by making each name
# match its filename (which is already unique by definition).
#
# Usage (run from inside the driver folder):
#   cd <driver_folder>
#   .\fix_duplicate_profile_names.ps1
# ==============================================================================

$driverRoot  = $PSScriptRoot
$profilesDir = Join-Path $driverRoot "profiles"

Write-Host ""
Write-Host "=== fix_duplicate_profile_names.ps1 ===" -ForegroundColor Cyan
Write-Host "Scanning: $profilesDir"
Write-Host ""

if (-not (Test-Path $profilesDir)) {
    Write-Host "ERROR: profiles\ folder not found. Run from the driver root." -ForegroundColor Red
    pause; exit 1
}


# Remove any backup YML files that ended up inside profiles\ (they confuse the packager)
Write-Host "Cleaning up backup files from profiles\ folder ..." -ForegroundColor Yellow
$strayBackups = Get-ChildItem $profilesDir -Filter "*.backup.yml"
foreach ($sb in $strayBackups) {
    $dest = Join-Path $driverRoot $sb.Name
    Move-Item $sb.FullName $dest -Force
    Write-Host "  Moved $($sb.Name) -> driver root" -ForegroundColor DarkGray
}
Write-Host ""

$ymlFiles = Get-ChildItem $profilesDir -Filter "*.yml" | Where-Object { $_.Name -notlike "*.backup.yml" } | Sort-Object Name

# Build map of name -> list of files that have it
$nameMap = @{}
foreach ($f in $ymlFiles) {
    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($content -match '(?m)^name:\s*(\S+)') {
        $profileName = $Matches[1]
        if (-not $nameMap.ContainsKey($profileName)) {
            $nameMap[$profileName] = @()
        }
        $nameMap[$profileName] += $f.Name
    } else {
        Write-Host "  WARNING: no 'name:' field found in $($f.Name)" -ForegroundColor DarkYellow
    }
}

# Report
Write-Host "All profile names:" -ForegroundColor Yellow
foreach ($kv in $nameMap.GetEnumerator() | Sort-Object Key) {
    $color = if ($kv.Value.Count -gt 1) { "Red" } else { "Gray" }
    $flag  = if ($kv.Value.Count -gt 1) { "  *** DUPLICATE ***" } else { "" }
    Write-Host ("  [{0}] {1}{2}" -f ($kv.Value -join ", "), $kv.Key, $flag) -ForegroundColor $color
}

$duplicates = $nameMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
$dupCount   = ($duplicates | Measure-Object).Count

if ($dupCount -eq 0) {
    Write-Host ""
    Write-Host "No duplicate names found." -ForegroundColor Green
    Write-Host "The packaging error may have a different cause." -ForegroundColor DarkYellow
    Write-Host "Try: edge:drivers:package . --verbose" -ForegroundColor Gray
    pause; exit 0
}

Write-Host ""
Write-Host "$dupCount duplicate name(s) found. Fixing ..." -ForegroundColor Yellow
Write-Host ""

$fixed = 0
foreach ($dup in $duplicates) {
    $dupName  = $dup.Key
    $dupFiles = $dup.Value
    Write-Host "  Duplicate name: '$dupName'" -ForegroundColor Red
    Write-Host "  Found in: $($dupFiles -join ', ')" -ForegroundColor Red

    foreach ($fname in $dupFiles) {
        $fpath       = Join-Path $profilesDir $fname
        # Correct name = filename without .yml extension
        $correctName = [System.IO.Path]::GetFileNameWithoutExtension($fname)
        $content     = [System.IO.File]::ReadAllText($fpath, [System.Text.Encoding]::UTF8)

        # Backup before changing
        $backup = Join-Path $driverRoot ([System.IO.Path]::GetFileNameWithoutExtension($fname) + '.dupfix.backup.yml')
        if (-not (Test-Path $backup)) {
            Copy-Item $fpath $backup
        }

        # Fix the name: line
        $newContent = [regex]::Replace($content, '(?m)^(name:\s*)\S+', "`${1}$correctName")
        [System.IO.File]::WriteAllText($fpath, $newContent, [System.Text.Encoding]::UTF8)
        Write-Host "    Fixed $fname -> name: $correctName" -ForegroundColor Green
        $fixed++
    }
}

Write-Host ""
Write-Host "Fixed $fixed file(s)." -ForegroundColor Green
Write-Host ""
Write-Host "Now retry packaging:" -ForegroundColor Yellow
$cli = Join-Path (Split-Path $driverRoot -Parent) "smartthings.exe"
Write-Host "  & '$cli' edge:drivers:package ." -ForegroundColor Gray
Write-Host ""
pause
