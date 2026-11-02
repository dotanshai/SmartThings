$token   = "ae346eea-2737-49b1-94b6-683a0ff1cc74"
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

$capId  = "perfectworld33337.channelType"
$capVer = 1
$baseUrl = "https://api.smartthings.com/v1"

$capFile  = "$env:TEMP\st_channeltype_cap.json"
$presFile = "$env:TEMP\st_channeltype_pres.json"

[System.IO.File]::WriteAllText($capFile, @'
{
  "id": "perfectworld33337.channelType",
  "version": 1,
  "status": "proposed",
  "name": "Channel Type",
  "attributes": {
    "channelType": {
      "schema": {
        "type": "object",
        "properties": {
          "value": {
            "type": "string",
            "enum": ["💡 Light", "🪟 Curtain"]
          }
        },
        "additionalProperties": false,
        "required": ["value"]
      },
      "enumCommands": [
        { "command": "setChannelType", "value": "💡 Light"   },
        { "command": "setChannelType", "value": "🪟 Curtain" }
      ]
    }
  },
  "commands": {
    "setChannelType": {
      "name": "setChannelType",
      "arguments": [
        {
          "name": "value",
          "schema": {
            "type": "string",
            "enum": ["💡 Light", "🪟 Curtain"]
          }
        }
      ]
    }
  }
}
'@, [System.Text.Encoding]::UTF8)

[System.IO.File]::WriteAllText($presFile, @'
{
  "dashboard": { "states": [], "actions": [], "panelItems": [] },
  "detailView": [
    {
      "label": "Channel Type",
      "displayType": "state",
      "state": {
        "label": "{{channelType.value}}"
      }
    }
  ],
  "automation": {
    "conditions": [
      {
        "label": "Channel type is",
        "displayType": "list",
        "list": {
          "attribute": "channelType",
          "value": "channelType.value",
          "alternatives": [
            { "key": "💡 Light",   "value": "💡 Light"   },
            { "key": "🪟 Curtain", "value": "🪟 Curtain" }
          ]
        }
      }
    ],
    "actions": []
  }
}
'@, [System.Text.Encoding]::UTF8)

# STEP 1: Delete existing capability
Write-Host ""
Write-Host "STEP 1: Deleting existing capability $capId v$capVer ..." -ForegroundColor Yellow
try {
    Invoke-RestMethod `
        -Uri "$baseUrl/capabilities/$capId/$capVer" `
        -Method DELETE -Headers $headers | Out-Null
    Write-Host "  Deleted OK" -ForegroundColor Green
} catch {
    $code = $_.Exception.Response.StatusCode
    if ($code -eq 404) {
        Write-Host "  Not found - proceeding to create ..." -ForegroundColor Yellow
    } else {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host "  Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
        pause; exit 1
    }
}

Write-Host "  Waiting 5 seconds ..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# STEP 2: Create with new emoji enum
Write-Host "STEP 2: Creating capability with emoji enum values ..." -ForegroundColor Yellow
try {
    $r = Invoke-RestMethod `
        -Uri "$baseUrl/capabilities" `
        -Method POST -Headers $headers -InFile $capFile -ContentType "application/json"
    Write-Host "  Created OK - id: $($r.id)" -ForegroundColor Green
} catch {
    $detail = $_.ErrorDetails.Message
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($detail) { Write-Host "  Detail: $detail" -ForegroundColor Red }
    pause; exit 1
}

Write-Host "  Waiting 5 seconds ..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# STEP 3: Upload presentation
Write-Host "STEP 3: Uploading presentation ..." -ForegroundColor Yellow
try {
    Invoke-RestMethod `
        -Uri "$baseUrl/capabilities/$capId/$capVer/presentation" `
        -Method PUT -Headers $headers -InFile $presFile -ContentType "application/json" | Out-Null
    Write-Host "  OK" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "  Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
    pause; exit 1
}

Write-Host ""
Write-Host "=== Done! ===" -ForegroundColor Green
Write-Host "Next: run upload_presentations.ps1, then package + install the driver." -ForegroundColor Yellow
Write-Host ""
pause
