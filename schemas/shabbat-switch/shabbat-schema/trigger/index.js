// EventBridge Scheduler invokes this with { externalDeviceId, command }.
// We look up by externalDeviceId (stable across OAuth token refreshes)
// rather than accessToken, since SmartThings refreshes access tokens
// periodically (every ~24h here) and a schedule created for next week
// would otherwise have a stale, already-rotated token baked into it by
// the time it actually fires.
//
// If the install has a fridgeDeviceId (selected during the install flow
// in oauth.js), this also sends the matching samsungce.sabbathMode on/off
// command directly to that device via the SmartThings Devices API, using
// the separately-stored OAuth-In access/refresh token (refreshed here
// first, since it's short-lived - about 24h). Note: Samsung has been
// observed to explicitly disable this capability server-side on some
// fridge/freezer models (it lists the capability under
// custom.disabledCapabilities in the device status and the API call
// returns 422 NOT_FOUND) even though it's visibly present - if that
// happens here, it's a Samsung-side restriction, not a bug in this code.

const { StateUpdateRequest } = require('st-schema');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, ScanCommand, UpdateCommand, GetCommand } = require('@aws-sdk/lib-dynamodb');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.INSTALLS_TABLE;
const CAP_LOCATION = process.env.CAP_LOCATION_ID;
const CAP_CANDLE = process.env.CAP_CANDLE_ID;
const CAP_HAVDALAH = process.env.CAP_HAVDALAH_ID;
const CANDLE_BASE_OFFSET_MIN = parseInt(process.env.CANDLE_BASE_OFFSET_MIN || '18', 10);
const HAVDALAH_BASE_OFFSET_MIN = parseInt(process.env.HAVDALAH_BASE_OFFSET_MIN || '42', 10);

async function findByExternalDeviceId(externalDeviceId) {
  const scan = await ddb.send(new ScanCommand({
    TableName: TABLE,
    FilterExpression: 'externalDeviceId = :d',
    ExpressionAttributeValues: { ':d': externalDeviceId },
  }));
  return scan.Items && scan.Items[0];
}

// Refreshes the OAuth-In access token (used to command the friend's fridge
// directly via the SmartThings Devices API - separate from the Schema
// Connector's own callback tokens used for pushing switch state).
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
  if (!res.ok) throw new Error(`OAuth-In token refresh failed: ${res.status} ${await res.text()}`);
  return res.json();
}

// Sends the samsungce.sabbathMode command directly to the fridge.
async function setFridgeSabbathMode(fridgeDeviceId, accessToken, command) {
  const res = await fetch(`https://api.smartthings.com/v1/devices/${fridgeDeviceId}/commands`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({ commands: [{ component: 'main', capability: 'samsungce.sabbathMode', command }] }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Fridge command failed: ${res.status} ${body}`);
  return body;
}

exports.handler = async (event) => {
  const { externalDeviceId, accessToken, command } = event || {};
  if ((!externalDeviceId && !accessToken) || (command !== 'on' && command !== 'off')) {
    throw new Error('Event payload must include externalDeviceId (or accessToken) and command: "on"|"off"');
  }

  // Prefer the stable externalDeviceId; fall back to accessToken only for
  // any already-scheduled events created before this fix.
  let record;
  if (externalDeviceId) {
    record = await findByExternalDeviceId(externalDeviceId);
  } else {
    const result = await ddb.send(new GetCommand({ TableName: TABLE, Key: { accessToken } }));
    record = result.Item;
  }

  if (!record) {
    console.warn(`No install found for externalDeviceId=${externalDeviceId} accessToken=${accessToken} - likely uninstalled, skipping`);
    return { skipped: true };
  }
  if (!record.callbackAuthentication || !record.callbackUrls) {
    console.warn(`Install has no callback access granted yet, skipping proactive push`);
    return { skipped: true };
  }

  await ddb.send(new UpdateCommand({
    TableName: TABLE,
    Key: { accessToken: record.accessToken },
    UpdateExpression: 'SET switchState = :s',
    ExpressionAttributeValues: { ':s': command },
  }));

  const updater = new StateUpdateRequest(process.env.SCHEMA_CLIENT_ID, process.env.SCHEMA_CLIENT_SECRET);

  const states = [{ component: 'main', capability: 'st.switch', attribute: 'switch', value: command }];
  const infoStates = await buildInfoStates(record);
  states.push(...infoStates);

  const deviceState = [{ externalDeviceId: record.externalDeviceId, states }];

  await updater.updateState(
    record.callbackUrls,
    record.callbackAuthentication,
    deviceState,
    async (refreshedAuth) => {
      // callback tokens rotate on refresh - persist the new ones
      await ddb.send(new UpdateCommand({
        TableName: TABLE,
        Key: { accessToken: record.accessToken },
        UpdateExpression: 'SET callbackAuthentication = :a',
        ExpressionAttributeValues: { ':a': refreshedAuth },
      }));
    }
  );

  // Fridge control, if one was selected during install. Failures here are
  // logged but don't fail the whole invocation - the switch itself already
  // succeeded above, and this is a best-effort secondary action.
  if (record.fridgeDeviceId && record.oauthInRefreshToken) {
    try {
      const refreshed = await refreshOauthInToken(record.oauthInRefreshToken);
      await ddb.send(new UpdateCommand({
        TableName: TABLE,
        Key: { accessToken: record.accessToken },
        UpdateExpression: 'SET oauthInAccessToken = :a, oauthInRefreshToken = :r',
        ExpressionAttributeValues: { ':a': refreshed.access_token, ':r': refreshed.refresh_token },
      }));
      await setFridgeSabbathMode(record.fridgeDeviceId, refreshed.access_token, command);
      console.log(`Fridge ${record.fridgeDeviceId} sabbathMode set to ${command}`);
    } catch (err) {
      console.error(`Fridge sabbathMode command failed for ${record.fridgeDeviceId}: ${err.message}`);
    }
  }

  return { installedFor: record.externalDeviceId, command };
};

// Same computation as webhook/index.js's buildInfoStates - duplicated
// since these are separate Lambda packages.
async function buildInfoStates(record) {
  if (!CAP_LOCATION || !record.latitude || !record.longitude) return [];
  try {
    const tz = record.timeZoneId || 'Asia/Jerusalem';
    const start = new Date();
    const end = new Date();
    end.setDate(end.getDate() + 8);
    const fmt8 = (d) => d.toISOString().slice(0, 10);

    const url = `https://www.hebcal.com/hebcal?v=1&cfg=json&maj=on&min=off&mod=off&nx=off&mf=off&s=on` +
      `&c=on&geo=pos&latitude=${record.latitude}&longitude=${record.longitude}&tzid=${encodeURIComponent(tz)}` +
      `&b=${CANDLE_BASE_OFFSET_MIN}&m=${HAVDALAH_BASE_OFFSET_MIN}&start=${fmt8(start)}&end=${fmt8(end)}&leyning=off`;
    const res = await fetch(url);
    if (!res.ok) return [];
    const data = await res.json();

    const isChanukah = (item) => /chanukah|hanukkah|חנוכה/i.test(`${item.title || ''} ${item.memo || ''} ${item.hebrew || ''}`);
    const events = (data.items || [])
      .filter((i) => (i.category === 'candles' || i.category === 'havdalah') && !isChanukah(i))
      .map((i) => ({ type: i.category, date: new Date(i.date) }))
      .sort((a, b) => a.date - b.date);

    const cycles = [];
    let openStart = null;
    for (const ev of events) {
      if (ev.type === 'candles') {
        if (openStart === null) openStart = ev.date;
      } else if (ev.type === 'havdalah' && openStart !== null) {
        cycles.push({ start: openStart, end: ev.date });
        openStart = null;
      }
    }
    if (!cycles.length) return [];
    const nextCycle = cycles[0];

    const candleExtra = record.candleOffsetMin || 0;
    const havdalahExtra = record.havdalahOffsetMin || 0;
    const candleTime = new Date(nextCycle.start);
    candleTime.setMinutes(candleTime.getMinutes() - candleExtra);
    const havdalahTime = new Date(nextCycle.end);
    havdalahTime.setMinutes(havdalahTime.getMinutes() + havdalahExtra);

    const locale = record.locale || 'en-US';
    const isHebrew = locale.startsWith('he');
    const fmt = (d) => new Intl.DateTimeFormat(locale, { timeZone: tz, weekday: isHebrew ? 'long' : 'short', hour: '2-digit', minute: '2-digit' }).format(d);
    const minLabel = isHebrew ? 'דקות' : 'min';

    return [
      { component: 'main', capability: CAP_LOCATION, attribute: 'location', value: (record.locationTitle || '').slice(0, 100) },
      { component: 'main', capability: CAP_CANDLE, attribute: 'candleLighting', value: `${fmt(candleTime)} (-${candleExtra} ${minLabel})`.slice(0, 100) },
      { component: 'main', capability: CAP_HAVDALAH, attribute: 'havdalah', value: `${fmt(havdalahTime)} (+${havdalahExtra} ${minLabel})`.slice(0, 100) },
    ];
  } catch (err) {
    console.error(`buildInfoStates failed: ${err.message}`);
    return [];
  }
}
