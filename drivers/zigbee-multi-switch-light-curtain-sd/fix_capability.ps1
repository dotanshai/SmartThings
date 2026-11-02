# Fix capability display for perfectworld33337.mschannelx55148
# - Adds setChannelType command (required for list displayType to be accepted)
# - Wires enumCommands so each enum value maps to the command
# - Updates capability presentation with list + state display
#
# The driver does NOT act on setChannelType - device type remains read-only.
# Run once. Then run upload_presentations.ps1 + re-install driver.

$token   = "ae346eea-2737-49b1-94b6-683a0ff1cc74"
$capId   = "perfectworld33337.mschannelx55148"
$capVer  = 1
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

# ── STEP 1: Update capability (command + enumCommands) ────────────────────────
# enumCommands: one entry per enum value, each mapping a literal value to its command
$capBody = @'
{
  "id": "perfectworld33337.mschannelx55148",
  "version": 1,
  "status": "proposed",
  "name": "mschannelx55148",
  "attributes": {
    "channelType": {
      "schema": {
        "type": "object",
        "properties": {
          "value": {
            "type": "string",
            "enum": ["light", "curtain"]
          }
        },
        "additionalProperties": false,
        "required": ["value"]
      },
      "enumCommands": [
        { "command": "setChannelType", "value": "light"   },
        { "command": "setChannelType", "value": "curtain" }
      ]
    }
  },
  "commands": {
    "setChannelType": {
      "name": "setChannelType",
      "arguments": [
        {
          "name": "value",
          "optional": false,
          "schema": {
            "type": "string",
            "enum": ["light", "curtain"]
          }
        }
      ]
    }
  }
}
'@

Write-Host ""
Write-Host "STEP 1: Updating capability (command + enumCommands) ..." -ForegroundColor Yellow
try {
    $r = Invoke-RestMethod `
        -Uri "https://api.smartthings.com/v1/capabilities/$capId/$capVer" `
        -Method PUT -Headers $headers -Body $capBody
    Write-Host "  OK - commands: $(($r.commands | ConvertTo-Json -Compress))" -ForegroundColor Green
} catch {
    $detail = $_.ErrorDetails.Message
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($detail) { Write-Host "  Detail: $detail" -ForegroundColor Red }
    pause; exit 1
}

# ── WAIT for platform to propagate the new command ────────────────────────────
Write-Host ""
Write-Host "  Waiting 5 seconds for platform to propagate command ..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# ── STEP 2: Update capability presentation ────────────────────────────────────
$presBody = @'
{
  "dashboard": {
    "states": [],
    "actions": [],
    "panelItems": []
  },
  "detailView": [
    {
      "label": "Channel Type",
      "displayType": "list",
      "list": {
        "command": {
          "name": "setChannelType",
          "alternatives": [
            { "key": "light",   "value": "\ud83d\udca1 Light",   "type": "active" },
            { "key": "curtain", "value": "\ud83e\ude9f Curtain", "type": "active" }
          ],
          "argumentType": "string"
        },
        "state": {
          "value": "channelType.value",
          "alternatives": [
            { "key": "light",   "value": "\ud83d\udca1 Light",   "type": "active" },
            { "key": "curtain", "value": "\ud83e\ude9f Curtain", "type": "active" }
          ]
        }
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
            { "key": "light",   "value": "Light",   "type": "active" },
            { "key": "curtain", "value": "Curtain", "type": "active" }
          ]
        }
      }
    ],
    "actions": [
      {
        "label": "Set channel type to",
        "displayType": "list",
        "list": {
          "command": "setChannelType",
          "argumentName": "value",
          "alternatives": [
            { "key": "light",   "value": "Light",   "type": "active" },
            { "key": "curtain", "value": "Curtain", "type": "active" }
          ]
        }
      }
    ]
  }
}
'@

Write-Host "STEP 2: Updating capability presentation ..." -ForegroundColor Yellow
try {
    $r = Invoke-RestMethod `
        -Uri "https://api.smartthings.com/v1/capabilities/$capId/$capVer/presentation" `
        -Method PUT -Headers $headers -Body $presBody
    Write-Host "  OK" -ForegroundColor Green
} catch {
    $detail = $_.ErrorDetails.Message
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($detail) { Write-Host "  Detail: $detail" -ForegroundColor Red }
    pause; exit 1
}

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run upload_presentations.ps1" -ForegroundColor White
Write-Host "  2. Clear app cache" -ForegroundColor White
Write-Host ""
pause
