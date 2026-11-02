# ==============================================================================
# Create custom capability perfectworld33337.signalMetrics
# Displays LQI and RSSI as read-only state tiles in detail view
# Run ONCE before upload_presentations.ps1
# ==============================================================================

$token   = "ae346eea-2737-49b1-94b6-683a0ff1cc74"
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
$capId   = "perfectworld33337.signalMetrics"
$capVer  = 1

$capBody = @'
{
  "id": "perfectworld33337.signalMetrics",
  "version": 1,
  "status": "proposed",
  "name": "Signal Metrics",
  "attributes": {
    "lqi": {
      "schema": {
        "type": "object",
        "properties": {
          "value": { "type": "integer", "minimum": 0, "maximum": 255 }
        },
        "additionalProperties": false,
        "required": ["value"]
      }
    },
    "rssi": {
      "schema": {
        "type": "object",
        "properties": {
          "value": { "type": "integer", "minimum": -200, "maximum": 0 }
        },
        "additionalProperties": false,
        "required": ["value"]
      }
    }
  },
  "commands": {}
}
'@

$presBody = @'
{
  "dashboard": {
    "states": [
      {
        "label": "LQI: {{lqi.value}}"
      }
    ],
    "actions": [],
    "basicPlus": []
  },
  "detailView": [
    {
      "label": "LQI",
      "displayType": "state",
      "state": {
        "label": "{{lqi.value}} lqi"
      }
    },
    {
      "label": "RSSI",
      "displayType": "state",
      "state": {
        "label": "{{rssi.value}} dBm"
      }
    }
  ],
  "automation": {
    "conditions": [],
    "actions": []
  }
}
'@

Write-Host ""
Write-Host "=== Create perfectworld33337.signalMetrics ===" -ForegroundColor Cyan

# STEP 1: Create capability
Write-Host "STEP 1: Creating capability ..." -ForegroundColor Yellow
try {
    $r = Invoke-RestMethod `
        -Uri "https://api.smartthings.com/v1/capabilities" `
        -Method POST -Headers $headers -Body $capBody
    Write-Host "  OK - id: $($r.id)" -ForegroundColor Green
} catch {
    $detail = $_.ErrorDetails.Message
    $statusCode = $_.Exception.Response.StatusCode
    $isConflict = ($statusCode -eq 409) -or ($statusCode -eq 422 -and $detail -match "ConflictError")
    if ($isConflict) {
        Write-Host "  Already exists - will update presentation ..." -ForegroundColor Yellow
    } else {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($detail) { Write-Host "  Detail: $detail" -ForegroundColor Red }
        pause; exit 1
    }
}

Write-Host "  Waiting 5 seconds ..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# STEP 2: Upload presentation
Write-Host "STEP 2: Uploading presentation ..." -ForegroundColor Yellow
try {
    Invoke-RestMethod `
        -Uri "https://api.smartthings.com/v1/capabilities/$capId/$capVer/presentation" `
        -Method PUT -Headers $headers -Body $presBody | Out-Null
    Write-Host "  OK" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "  Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
    pause; exit 1
}

Write-Host ""
Write-Host "Done! Next steps:" -ForegroundColor Green
Write-Host "  1. Run upload_presentations.ps1" -ForegroundColor White
Write-Host "  2. Run: edge:drivers:package + edge:drivers:install" -ForegroundColor White
Write-Host ""
pause
