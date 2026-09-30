// TEMPORARY - checks the LIVE, real-time status of both the Shabbat Switch
// device and the connected fridge directly from SmartThings, using the
// install's stored OAuth-In token. Read-only. Delete after use.
//
// Invoke with: { "externalDeviceId": "<install's externalDeviceId>" }

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, ScanCommand, UpdateCommand } = require('@aws-sdk/lib-dynamodb');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.INSTALLS_TABLE;

async function findByExternalDeviceId(externalDeviceId) {
  const scan = await ddb.send(new ScanCommand({
    TableName: TABLE,
    FilterExpression: 'externalDeviceId = :d',
    ExpressionAttributeValues: { ':d': externalDeviceId },
  }));
  return scan.Items && scan.Items[0];
}

async function refreshOauthInToken(refreshToken) {
  const basicAuth = Buffer.from(`${process.env.OAUTH_IN_CLIENT_ID}:${process.env.OAUTH_IN_CLIENT_SECRET}`).toString('base64');
  const res = await fetch('https://api.smartthings.com/oauth/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${basicAuth}`,
    },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Token refresh failed: ${res.status} ${body}`);
  return JSON.parse(body);
}

exports.handler = async (event) => {
  const { externalDeviceId } = event || {};
  if (!externalDeviceId) throw new Error('Need externalDeviceId');

  const record = await findByExternalDeviceId(externalDeviceId);
  if (!record) throw new Error(`No install found for externalDeviceId=${externalDeviceId}`);
  if (!record.oauthInRefreshToken) throw new Error('No oauthInRefreshToken on this install');

  const refreshed = await refreshOauthInToken(record.oauthInRefreshToken);

  await ddb.send(new UpdateCommand({
    TableName: TABLE,
    Key: { accessToken: record.accessToken },
    UpdateExpression: 'SET oauthInAccessToken = :a, oauthInRefreshToken = :r',
    ExpressionAttributeValues: { ':a': refreshed.access_token, ':r': refreshed.refresh_token },
  }));

  // Find the Shabbat Switch device itself by listing devices at the
  // location and matching our own viper endpointAppId.
  const listRes = await fetch(`https://api.smartthings.com/v1/devices?locationId=${record.locationId}`, {
    headers: { Authorization: `Bearer ${refreshed.access_token}` },
  });
  const listBody = await listRes.json();
  const switchDevice = (listBody.items || []).find((d) => d.viper && d.viper.endpointAppId === 'viper_f25adce0-8194-11f1-b7d5-4bd5935b2433');

  let switchStatus = null;
  if (switchDevice) {
    const sRes = await fetch(`https://api.smartthings.com/v1/devices/${switchDevice.deviceId}/components/main/capabilities/switch/status`, {
      headers: { Authorization: `Bearer ${refreshed.access_token}` },
    });
    switchStatus = await sRes.json();
  }

  let fridgeStatus = null;
  if (record.fridgeDeviceId) {
    const fRes = await fetch(`https://api.smartthings.com/v1/devices/${record.fridgeDeviceId}/components/main/capabilities/samsungce.sabbathMode/status`, {
      headers: { Authorization: `Bearer ${refreshed.access_token}` },
    });
    fridgeStatus = await fRes.json();
  }

  return {
    switchDeviceId: switchDevice ? switchDevice.deviceId : null,
    switchStatus,
    fridgeDeviceId: record.fridgeDeviceId,
    fridgeStatus,
  };
};
