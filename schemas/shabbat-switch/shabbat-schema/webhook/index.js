// ST Schema webhook Lambda. Handles discovery, stateRefresh, command, and
// grantCallbackAccess interactions using the st-schema SDK.
//
// Required environment variables:
//   INSTALLS_TABLE
//   SCHEMA_CLIENT_ID, SCHEMA_CLIENT_SECRET  (from `smartthings apps:create`)
//   DEVICE_PROFILE_ID   (from `smartthings deviceprofiles:create`)
//   CUSTOM_CAPABILITY_ID (namespaced id, e.g. "yournamespace.shabbatinfo")
//   CANDLE_BASE_OFFSET_MIN (default 18), HAVDALAH_BASE_OFFSET_MIN (default 42)

const { SchemaConnector } = require('st-schema');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, UpdateCommand, DeleteCommand } = require('@aws-sdk/lib-dynamodb');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.INSTALLS_TABLE;
const DEVICE_PROFILE_ID = process.env.DEVICE_PROFILE_ID;
const CAP_LOCATION = process.env.CAP_LOCATION_ID;
const CAP_CANDLE = process.env.CAP_CANDLE_ID;
const CAP_HAVDALAH = process.env.CAP_HAVDALAH_ID;
const CAP_CANDLE_OFFSET = process.env.CAP_CANDLE_OFFSET_ID;
const CAP_HAVDALAH_OFFSET = process.env.CAP_HAVDALAH_OFFSET_ID;
const CAP_LANGUAGE = process.env.CAP_LANGUAGE_ID;
const CANDLE_BASE_OFFSET_MIN = parseInt(process.env.CANDLE_BASE_OFFSET_MIN || '18', 10);
const HAVDALAH_BASE_OFFSET_MIN = parseInt(process.env.HAVDALAH_BASE_OFFSET_MIN || '42', 10);

// Refreshes the OAuth-In access token used to command the friend's fridge
// directly via the SmartThings Devices API (separate from this app's own
// Schema Connector credentials).
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

// If this install has a connected fridge, mirrors the switch command to it.
// Best-effort: failures are logged but never thrown, so a fridge problem
// never breaks the switch command itself.
async function syncFridgeWithSwitch(record, command) {
  if (!record.fridgeDeviceId || !record.oauthInRefreshToken) return;
  try {
    const refreshed = await refreshOauthInToken(record.oauthInRefreshToken);
    await ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: { accessToken: record.accessToken },
      UpdateExpression: 'SET oauthInAccessToken = :a, oauthInRefreshToken = :r',
      ExpressionAttributeValues: { ':a': refreshed.access_token, ':r': refreshed.refresh_token },
    }));
    await setFridgeSabbathMode(record.fridgeDeviceId, refreshed.access_token, command);
    console.log(`Fridge ${record.fridgeDeviceId} sabbathMode set to ${command} (manual switch command)`);
  } catch (err) {
    console.error(`Fridge sabbathMode command failed for ${record.fridgeDeviceId}: ${err.message}`);
  }
}

const connector = new SchemaConnector()
  .clientId(process.env.SCHEMA_CLIENT_ID)
  .clientSecret(process.env.SCHEMA_CLIENT_SECRET)

  .discoveryHandler(async (accessToken, response) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    // deviceHandlerType is set to our custom Device Profile ID (not the
    // built-in "c2c-switch" type) so the info capability is available.
    response.addDevice(record.externalDeviceId, 'Shabbat Switch', DEVICE_PROFILE_ID)
      .manufacturerName('Shai D. Shared Drivers')
      .modelName('Shabbat Switch')
      .addCategory('Switch');
  })

  .stateRefreshHandler(async (accessToken, response) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    const states = [{ component: 'main', capability: 'st.switch', attribute: 'switch', value: record.switchState }];
    const infoStates = await buildInfoStates(record);
    states.push(...infoStates);
    if (CAP_CANDLE_OFFSET) {
      states.push({ component: 'main', capability: CAP_CANDLE_OFFSET, attribute: 'candleOffset', value: record.candleOffsetMin || 0 });
    }
    if (CAP_HAVDALAH_OFFSET) {
      states.push({ component: 'main', capability: CAP_HAVDALAH_OFFSET, attribute: 'havdalahOffset', value: record.havdalahOffsetMin || 0 });
    }
    if (CAP_LANGUAGE) {
      states.push({ component: 'main', capability: CAP_LANGUAGE, attribute: 'language', value: (record.locale || 'en-US').startsWith('he') ? 'he' : 'en' });
    }
    response.addDevice(record.externalDeviceId, states);
  })

  .commandHandler(async (accessToken, response, devices) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    for (const device of devices) {
      const deviceResponse = response.addDevice(device.externalDeviceId);
      for (const cmd of device.commands) {
        if (cmd.capability === 'st.switch' && (cmd.command === 'on' || cmd.command === 'off')) {
          await ddb.send(new UpdateCommand({
            TableName: TABLE,
            Key: { accessToken },
            UpdateExpression: 'SET switchState = :s',
            ExpressionAttributeValues: { ':s': cmd.command },
          }));
          deviceResponse.addState('main', 'st.switch', 'switch', cmd.command);
          await syncFridgeWithSwitch(record, cmd.command);
        } else if (CAP_CANDLE_OFFSET && cmd.capability === CAP_CANDLE_OFFSET && cmd.command === 'setCandleOffset') {
          const value = Math.max(0, Math.round(Number(cmd.arguments[0])));
          await ddb.send(new UpdateCommand({
            TableName: TABLE,
            Key: { accessToken },
            UpdateExpression: 'SET candleOffsetMin = :v',
            ExpressionAttributeValues: { ':v': value },
          }));
          deviceResponse.addState('main', CAP_CANDLE_OFFSET, 'candleOffset', value);
          const refreshed = await getRecord(accessToken);
          for (const s of await buildInfoStates(refreshed)) deviceResponse.addState(s.component, s.capability, s.attribute, s.value);
        } else if (CAP_HAVDALAH_OFFSET && cmd.capability === CAP_HAVDALAH_OFFSET && cmd.command === 'setHavdalahOffset') {
          const value = Math.max(0, Math.round(Number(cmd.arguments[0])));
          await ddb.send(new UpdateCommand({
            TableName: TABLE,
            Key: { accessToken },
            UpdateExpression: 'SET havdalahOffsetMin = :v',
            ExpressionAttributeValues: { ':v': value },
          }));
          deviceResponse.addState('main', CAP_HAVDALAH_OFFSET, 'havdalahOffset', value);
          const refreshed = await getRecord(accessToken);
          for (const s of await buildInfoStates(refreshed)) deviceResponse.addState(s.component, s.capability, s.attribute, s.value);
        } else if (CAP_LANGUAGE && cmd.capability === CAP_LANGUAGE && cmd.command === 'setLanguage') {
          const langKey = String(cmd.arguments[0]);
          const newLocale = langKey === 'he' ? 'he-IL' : 'en-US';
          let newLocationTitle = record.locationTitle;
          if (record.latitude && record.longitude) {
            const geocoded = await reverseGeocode(record.latitude, record.longitude, newLocale);
            if (geocoded) newLocationTitle = geocoded;
          }
          await ddb.send(new UpdateCommand({
            TableName: TABLE,
            Key: { accessToken },
            UpdateExpression: 'SET locale = :v, locationTitle = :t',
            ExpressionAttributeValues: { ':v': newLocale, ':t': newLocationTitle },
          }));
          deviceResponse.addState('main', CAP_LANGUAGE, 'language', langKey);
          const refreshed = await getRecord(accessToken);
          for (const s of await buildInfoStates(refreshed)) deviceResponse.addState(s.component, s.capability, s.attribute, s.value);
        }
      }
    }
  })

  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    await ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: { accessToken },
      UpdateExpression: 'SET callbackAuthentication = :a, callbackUrls = :u',
      ExpressionAttributeValues: { ':a': callbackAuthentication, ':u': callbackUrls },
    }));
  })

  .integrationDeletedHandler(async (accessToken) => {
    await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { accessToken } }));
  });

exports.handler = async (event) => {
  const rawBody = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf-8') : event.body;
  const body = typeof rawBody === 'string' ? JSON.parse(rawBody) : rawBody;
  console.log(`Webhook interactionType: ${body.headers && body.headers.interactionType}`);
  const result = await connector.handleCallback(body);
  console.log(`Webhook response: ${JSON.stringify(result)}`);
  return { statusCode: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(result) };
};

// Re-resolves the location name in a new language via OpenStreetMap's free
// Nominatim service, used when the user toggles language (location name is
// stored once at install and otherwise wouldn't update, unlike the times
// which recompute live on every call).
async function reverseGeocode(latitude, longitude, locale) {
  try {
    const lang = (locale || 'en-US').split('-')[0];
    const url = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${latitude}&lon=${longitude}&zoom=10&addressdetails=1&accept-language=${lang}`;
    const res = await fetch(url, {
      headers: { 'User-Agent': 'ShabbatSwitchSchemaConnector/1.0 (SmartThings community integration)' },
    });
    if (!res.ok) return null;
    const data = await res.json();
    const addr = data.address || {};
    const city = addr.city || addr.town || addr.village || addr.municipality || addr.county;
    const country = addr.country;
    if (city && country) return `${city}, ${country}`;
    return data.display_name || null;
  } catch (err) {
    console.error(`Reverse geocode error: ${err.message}`);
    return null;
  }
}

async function getRecord(accessToken) {
  const { Item } = await ddb.send(new GetCommand({ TableName: TABLE, Key: { accessToken } }));
  return Item;
}

// Builds three separate tile states: location, candle-lighting (with its
// offset), and Havdalah (with its offset). Holiday-aware (Chanukah
// excluded, contiguous holy-day spans treated as one cycle). Returns []
// if the capability isn't configured or the computation fails, so a
// failure here never breaks the switch itself.
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

    // Pair candles -> havdalah into cycles the same way the scheduler
    // does, so the tile shows whichever cycle is actually coming up next
    // (which may be a standalone mid-week Yom Tov, not always Shabbat).
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
