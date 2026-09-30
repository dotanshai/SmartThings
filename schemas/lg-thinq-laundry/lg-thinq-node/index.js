'use strict';

/**
 * LG ThinQ Laundry — SmartThings Schema Connector
 *
 * Architecture mirrors DolphinBoilerSchema exactly: one Lambda handles
 * both the OAuth HTTP routes (/authorize, /token) AND the SmartThings
 * Schema callback (via st-schema's SchemaConnector), routed on
 * event.requestContext presence — same as Dolphin's index.js.
 *
 * KEY DIFFERENCE FROM DOLPHIN: LG uses a long-lived Personal Access
 * Token (PAT), not a username/password login that mints a session API
 * key. So /authorize collects PAT + country code instead of email/pass,
 * and there's no "get API key" step — the PAT itself IS the credential,
 * verified once by calling the device list endpoint before accepting it.
 *
 * DynamoDB pattern matches Dolphin exactly: no separate "installedAppId"
 * concept. Records are keyed by whatever token is currently active
 * (session id -> code -> access_token/refresh_token), carried forward
 * at each step. accessToken is what SmartThings passes to every
 * discoveryHandler/stateRefreshHandler/commandHandler call, so lookups
 * are trivial — same as Dolphin's getData(accessToken).
 *
 * LG REST endpoints below were extracted directly from the official
 * thinqconnect Python SDK source (thinq_api.py) — base URL, headers,
 * and endpoint paths are copied 1:1, not guessed.
 *
 * SCOPE: v1 is laundry-only (DEVICE_WASHER type), monitoring + basic
 * on/off control (mapped to LG's START/STOP washerOperationMode).
 *
 * IMPORTANT PHYSICAL PREREQUISITE (confirmed via live testing, cannot
 * be worked around from code): commands only succeed while the washer
 * is in "remote start" mode, which requires the user to hold the
 * machine's Remote Start button (labeled "Add Item" on this model) for
 * 3+ seconds, door closed, machine powered on, immediately before use.
 * Powering off or opening the door cancels it. If it's been idle ~10
 * min, the machine goes to SLEEP and needs a WAKE_UP command before
 * START will work (START fails with COMMAND_NOT_SUPPORTED_IN_STATE
 * otherwise) — not implemented as an automatic fallback below, since
 * detecting "how long has it been idle" isn't reliably knowable from
 * our side. Worth adding as a retry-with-WAKE_UP fallback later if
 * command failures turn out to be common in practice.
 */

const { SchemaConnector } = require('st-schema');
const https = require('https');
const crypto = require('crypto');
const { DynamoDBClient, GetItemCommand, PutItemCommand, DeleteItemCommand } = require('@aws-sdk/client-dynamodb');
const { marshall, unmarshall } = require('@aws-sdk/util-dynamodb');

const TABLE = process.env.TABLE_NAME || 'LgThinqTokens';
const dynamo = new DynamoDBClient({ region: process.env.DYNAMO_REGION || 'us-east-1' });

const NS = 'vehiclepatch55148'; // reusing your existing custom capability namespace
const LAUNDRY_CAP = `${NS}.laundryState`;

// ─── DynamoDB helpers (identical pattern to Dolphin's) ──────────────────────

async function storeData(key, data) {
  await dynamo.send(new PutItemCommand({ TableName: TABLE, Item: marshall({ pk: key, ...data }) }));
}
async function getData(key) {
  const r = await dynamo.send(new GetItemCommand({ TableName: TABLE, Key: marshall({ pk: key }) }));
  return r.Item ? unmarshall(r.Item) : null;
}
async function deleteData(key) {
  await dynamo.send(new DeleteItemCommand({ TableName: TABLE, Key: marshall({ pk: key }) }));
}

// ─── LG ThinQ Connect API ────────────────────────────────────────────────────
// Endpoints/headers copied directly from thinqconnect's thinq_api.py source.

const LG_API_KEY = 'v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3'; // thinqconnect's public client API key (const.API_KEY)

// Country -> region domain prefix. Extend as needed; IL/EU countries use "eic".
// (thinqconnect's country.py has the full table — this covers what you need now.)
const REGION_BY_COUNTRY = {
  IL: 'eic', GB: 'eic', DE: 'eic', FR: 'eic', IT: 'eic', ES: 'eic', NL: 'eic',
  US: 'aic', CA: 'aic',
};

function regionFor(countryCode) {
  return REGION_BY_COUNTRY[(countryCode || 'IL').toUpperCase()] || 'eic';
}

function lgFetch(method, endpoint, { pat, clientId, countryCode, body } = {}) {
  return new Promise((resolve, reject) => {
    const region = regionFor(countryCode);
    const bodyStr = body ? JSON.stringify(body) : undefined;
    const headers = {
      Authorization: `Bearer ${pat}`,
      'x-country': countryCode || 'IL',
      'x-message-id': crypto.randomBytes(16).toString('base64').slice(0, 22), // matches thinqconnect's message-id shape
      'x-client-id': clientId,
      'x-api-key': LG_API_KEY,
      'x-service-phase': 'OP',
      'Content-Type': 'application/json',
    };
    if (method === 'POST') headers['x-conditional-control'] = 'true';
    if (bodyStr) headers['Content-Length'] = Buffer.byteLength(bodyStr);

    const req = https.request({
      hostname: `api-${region}.lgthinq.com`,
      port: 443,
      path: `/${endpoint}`,
      method,
      headers,
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        let parsed;
        try { parsed = JSON.parse(data); } catch { parsed = { raw: data }; }
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(parsed.response !== undefined ? parsed.response : parsed);
        } else {
          const msg = parsed?.error?.message || parsed?.message || data || `HTTP ${res.statusCode}`;
          reject(new Error(msg));
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('LG API timeout')));
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

const LG = {
  listDevices: (pat, clientId, countryCode) =>
    lgFetch('GET', 'devices', { pat, clientId, countryCode }),

  getStatus: (deviceId, pat, clientId, countryCode) =>
    lgFetch('GET', `devices/${deviceId}/state`, { pat, clientId, countryCode }),

  control: (deviceId, pat, clientId, countryCode, payload) =>
    lgFetch('POST', `devices/${deviceId}/control`, { pat, clientId, countryCode, body: payload }),
};

const LAUNDRY_TYPES = new Set([
  'DEVICE_WASHER', 'DEVICE_DRYER', 'DEVICE_WASHTOWER',
  'DEVICE_WASHCOMBO_MAIN', 'DEVICE_WASHCOMBO_MINI',
]);

// ─── Status normalisation ────────────────────────────────────────────────────

function normaliseStatus(raw) {
  // LG returns either a single object or (for some models) a list with
  // one entry per location — confirmed live: your washer returns a
  // single-item list.
  const s = Array.isArray(raw) ? (raw[0] || {}) : (raw || {});
  const runState = s.runState?.currentState || 'POWER_OFF';
  const timer = s.timer || {};
  const remainMinutes = (timer.remainHour || 0) * 60 + (timer.remainMinute || 0);
  const totalMinutes = (timer.totalHour || 0) * 60 + (timer.totalMinute || 0);
  return {
    runState,
    isOn: runState !== 'POWER_OFF',
    remainMinutes,
    totalMinutes,
    cycleCount: s.cycle?.cycleCount || 0,
    remoteControlEnabled: !!s.remoteControlEnable?.remoteControlEnabled,
    locationName: s.location?.locationName || 'MAIN',
  };
}

// ─── Schema Connector ────────────────────────────────────────────────────────

const connector = new SchemaConnector()
  .clientId(process.env.ST_CLIENT_ID)
  .clientSecret(process.env.ST_CLIENT_SECRET)
  .enableEventLogging(2)

  .discoveryHandler(async (accessToken, response) => {
    const data = await getData(accessToken);
    if (!data) { console.error('No data for token:', accessToken); return; }

    let devices;
    try {
      devices = await LG.listDevices(data.pat, data.clientId, data.countryCode);
    } catch (e) {
      console.error('LG listDevices failed:', e.message);
      return;
    }

    for (const d of (devices || [])) {
      const info = d.deviceInfo || {};
      if (!LAUNDRY_TYPES.has(info.deviceType)) continue; // laundry-only for v1

      response.addDevice(d.deviceId, info.alias || 'LG Washer/Dryer', LAUNDRY_CAP)
        .manufacturerName('LG')
        .modelName(info.modelName || 'ThinQ Laundry')
        .swVersion('1.0.0');
    }
  })

  .stateRefreshHandler(async (accessToken, response) => {
    const data = await getData(accessToken);
    if (!data) return;

    const deviceId = data.deviceId;
    const component = response.addDevice(deviceId).addComponent('main');

    try {
      const raw = await LG.getStatus(deviceId, data.pat, data.clientId, data.countryCode);
      const s = normaliseStatus(raw);

      component.addState('st.switch', 'switch', s.isOn ? 'on' : 'off');
      component.addState('st.healthCheck', 'healthStatus', 'online');
      component.addState(LAUNDRY_CAP, 'machineState', s.runState);
      component.addState(LAUNDRY_CAP, 'remainingTimeMinutes', s.remainMinutes);
      component.addState(LAUNDRY_CAP, 'totalTimeMinutes', s.totalMinutes);
      component.addState(LAUNDRY_CAP, 'cycleCount', s.cycleCount);
      component.addState(LAUNDRY_CAP, 'remoteControlEnabled', s.remoteControlEnabled);

      await storeData(accessToken, { ...data, lastStatus: s });
    } catch (err) {
      console.error('stateRefresh error:', err.message);
      component.addState('st.switch', 'switch', 'off');
      component.addState('st.healthCheck', 'healthStatus', 'offline');
    }
  })

  .commandHandler(async (accessToken, response, devices) => {
    const data = await getData(accessToken);
    if (!data) return;

    for (const device of devices) {
      const component = response.addDevice(device.externalDeviceId).addComponent('main');
      const deviceId = device.externalDeviceId;
      const locationName = data.lastStatus?.locationName || 'MAIN';

      for (const cmd of device.commands) {
        const { capability, command } = cmd;
        console.log('Command:', capability, command);

        if (capability !== 'st.switch') {
          console.warn('Unhandled capability/command:', capability, command);
          continue;
        }

        const turningOn = command === 'on';
        const operation = turningOn ? 'START' : 'STOP';

        try {
          await LG.control(deviceId, data.pat, data.clientId, data.countryCode, {
            location: { locationName },
            operation: { washerOperationMode: operation },
          });
          component.addState('st.switch', 'switch', turningOn ? 'on' : 'off');
        } catch (e) {
          // Most likely cause: remote-start mode wasn't armed on the
          // physical machine recently (see module docstring). We can't
          // tell the user why from here yet — see README TODO.
          console.error('washer command failed:', e.message);
          component.addState('st.switch', 'switch', turningOn ? 'off' : 'on');
        }
      }
    }
  })

  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    const data = await getData(accessToken);
    if (data) await storeData(accessToken, { ...data, callbackAuthentication, callbackUrls });
  })

  .integrationDeletedHandler(async (accessToken) => { await deleteData(accessToken); });

// ─── OAuth login page ─────────────────────────────────────────────────────────

function loginPage(sessionId, error) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LG ThinQ Laundry - Connect to SmartThings</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: -apple-system, Arial, sans-serif; max-width: 420px; margin: 60px auto; padding: 20px; background: #f0f2f5; }
    .card { background: white; border-radius: 16px; padding: 36px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
    h1 { color: #a50034; font-size: 24px; text-align: center; margin: 0 0 8px; }
    p { color: #666; font-size: 14px; text-align: center; margin: 0 0 12px; }
    a { color: #a50034; }
    label { display: block; font-size: 13px; color: #444; margin-bottom: 4px; font-weight: 500; }
    input { width: 100%; padding: 12px 14px; margin-bottom: 16px; border: 1.5px solid #ddd; border-radius: 10px; font-size: 15px; }
    input:focus { outline: none; border-color: #a50034; }
    button { width: 100%; padding: 14px; background: #a50034; color: white; border: none; border-radius: 10px; font-size: 16px; font-weight: 600; cursor: pointer; }
    button:hover { background: #7d0027; }
    .error { color: #d93025; background: #fce8e6; padding: 12px; border-radius: 8px; margin-bottom: 20px; font-size: 14px; text-align: center; }
  </style>
</head>
<body>
  <div class="card">
    <h1>LG ThinQ Laundry</h1>
    <p>Connect your LG washer/dryer to SmartThings</p>
    <p style="font-size:12px">Get your Personal Access Token at
       <a href="https://connect-pat.lgthinq.com" target="_blank">connect-pat.lgthinq.com</a>
       (must be a native LG account, not Google/Facebook/Amazon login).</p>
    ${error ? `<div class="error">${error}</div>` : ''}
    <form method="POST" action="/authorize">
      <input type="hidden" name="s" value="${sessionId}">
      <label>Personal Access Token</label><input type="text" name="pat" required autofocus>
      <label>Country code</label><input type="text" name="country" value="IL" required>
      <button>Connect to SmartThings</button>
    </form>
  </div>
</body>
</html>`;
}

// ─── Lambda entry point ───────────────────────────────────────────────────────

exports.handler = async (event, context) => {
  console.log('Event:', JSON.stringify({ ...event, body: event.body?.substring(0, 200) }));

  if (event.requestContext) {
    const method = (event.requestContext.http?.method || event.httpMethod || '').toUpperCase();
    const path = event.requestContext.http?.path || event.path || '';
    const qs = event.queryStringParameters || {};

    if (path === '/authorize' && method === 'GET') {
      const sid = crypto.randomBytes(16).toString('hex');
      await storeData('s:' + sid, { pk: 's:' + sid, r: qs.redirect_uri || '', st: qs.state || '' });
      return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: loginPage(sid) };
    }

    if (path === '/authorize' && method === 'POST') {
      const rawBody = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
      const params = new URLSearchParams(rawBody);
      const sid = params.get('s') || '', pat = params.get('pat') || '', country = params.get('country') || 'IL';
      const sess = await getData('s:' + sid);
      const redirectUri = sess ? sess.r : '', state = sess ? sess.st : '';

      const clientId = crypto.randomUUID();
      let devices;
      try {
        devices = await LG.listDevices(pat, clientId, country);
      } catch (e) {
        return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' },
          body: loginPage(sid, `Couldn't connect to LG: ${e.message}`) };
      }

      const washer = (devices || []).find(d => LAUNDRY_TYPES.has(d.deviceInfo?.deviceType));
      if (!washer) {
        return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' },
          body: loginPage(sid, 'No washer/dryer found on this LG account') };
      }

      const code = crypto.randomBytes(32).toString('hex');
      await storeData(code, { pk: code, pat, clientId, countryCode: country, deviceId: washer.deviceId });
      if (sess) await deleteData('s:' + sid);

      const url = new URL(redirectUri);
      url.searchParams.set('code', code);
      url.searchParams.set('state', state);
      return { statusCode: 302, headers: { Location: url.toString() }, body: '' };
    }

    if (path === '/token' && method === 'POST') {
      const rawBody = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
      const params = new URLSearchParams(rawBody);
      const grantType = params.get('grant_type');

      if (grantType === 'authorization_code') {
        const code = params.get('code');
        const stored = await getData(code);
        if (!stored) return { statusCode: 400, body: JSON.stringify({ error: 'invalid_grant' }) };
        const at = crypto.randomBytes(32).toString('hex'), rt = crypto.randomBytes(32).toString('hex');
        await storeData(at, { ...stored, pk: at });
        await storeData(rt, { ...stored, pk: rt, isRefresh: true });
        await deleteData(code);
        return { statusCode: 200, headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ access_token: at, refresh_token: rt, token_type: 'Bearer', expires_in: 31536000 }) };
      }

      if (grantType === 'refresh_token') {
        const rt = params.get('refresh_token');
        const stored = await getData(rt);
        if (!stored) return { statusCode: 400, body: JSON.stringify({ error: 'invalid_grant' }) };
        const at = crypto.randomBytes(32).toString('hex');
        await storeData(at, { ...stored, pk: at, isRefresh: false });
        return { statusCode: 200, headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ access_token: at, refresh_token: rt, token_type: 'Bearer', expires_in: 31536000 }) };
      }

      return { statusCode: 400, body: JSON.stringify({ error: 'unsupported_grant_type' }) };
    }

    return { statusCode: 404, body: 'Not found' };
  }

  return connector.handleLambdaCallback(event, context);
};
