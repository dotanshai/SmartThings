$token   = "ae346eea-2737-49b1-94b6-683a0ff1cc74"
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

$body = @'
{
  "dashboard": {
    "states": [],
    "actions": [],
    "panelItems": []
  },
  "detailView": [
    {
      "label": "Channel Type",
      "displayType": "state",
      "state": {
        "label": "{{channelType.value}}",
        "alternatives": [
          { "key": "light",   "value": "Light"   },
          { "key": "curtain", "value": "Curtain"  }
        ]
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
            { "key": "light",   "value": "Light"   },
            { "key": "curtain", "value": "Curtain"  }
          ]
        }
      }
    ],
    "actions": []
  }
}
'@

Write-Host "Updating channelType presentation..." -ForegroundColor Yellow
try {
    $r = Invoke-RestMethod `
        -Uri "https://api.smartthings.com/v1/capabilities/vehiclepatch55148.channelType/1/presentation" `
        -Method PUT -Headers $headers -Body $body
    Write-Host "OK" -ForegroundColor Green
    $r | ConvertTo-Json -Depth 10
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
}
pause
