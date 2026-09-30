'use strict';

/**
 * LG ThinQ Fridge — SmartThings Schema Connector
 *
 * Architecture ported directly from LgThinqLaundrySchema (which is
 * itself ported from DolphinBoilerSchema): one Lambda handles both the
 * OAuth HTTP routes (/authorize, /token) AND the SmartThings Schema
 * callback (via st-schema's SchemaConnector), routed on
 * event.requestContext presence.
 *
 * SEPARATE PROJECT from the laundry connector, per decision: own
 * Lambda, own DynamoDB table (LgThinqFridgeTokens), own API Gateway.
 * The LG API client (lgFetch/LG.*), DynamoDB helpers, and OAuth login
 * page are copied 1:1 from the laundry Lambda — same LG account model,
 * same PAT-based auth, same regional routing (kic/eic/aic).
 *
 * SCOPE: v1 is DEVICE_REFRIGERATOR only. Monitoring (fridge/freezer
 * temp, express mode, power save, door, water filter) + control
 * (temperature setpoints, express mode toggle). No on/off — a fridge
 * has no meaningful switch state, so there's no `switch` capability
 * in the device profile and no on/off command handling here.
 *
 * STATUS SHAPE below (normaliseStatus) is built directly from the real
 * profile/status JSON a Facebook group member (Homeagain) sent — not
 * guessed. The control payload shapes (setTemperatureC / setExpressMode
 * -> LG.control body) are a BEST GUESS mirrored from the profile's
 * property structure (temperature[]/refrigeration.expressMode) and are
 * CONFIRMED working against a live device (Homeagain's fridge,
 * model 2RES1VE62PFWA) as of 2026-08-27.
 *
 * Two Device Profiles are used, chosen at discovery time by country
 * code: DEVICE_PROFILE_ID_C (Celsius, all non-US accounts) and
 * DEVICE_PROFILE_ID_F (Fahrenheit, US accounts). Both are PUBLISHED.
 */

const { SchemaConnector, StateUpdateRequest } = require('st-schema');
const https = require('https');
const crypto = require('crypto');
const { DynamoDBClient, GetItemCommand, PutItemCommand, DeleteItemCommand, ScanCommand } = require('@aws-sdk/client-dynamodb');
const { marshall, unmarshall } = require('@aws-sdk/util-dynamodb');

const TABLE = process.env.TABLE_NAME || 'LgThinqFridgeTokens';
const dynamo = new DynamoDBClient({ region: process.env.DYNAMO_REGION || 'us-east-1' });

const NS = 'vehiclepatch55148'; // same custom capability namespace as the laundry project
const FRIDGE_TEMP_CAP_C = `${NS}.fridgeTemperatureC`;
const FREEZER_TEMP_CAP_C = `${NS}.freezerTemperatureC`;
const FRIDGE_TEMP_CAP_F = `${NS}.fridgeTemperatureF`;
const FREEZER_TEMP_CAP_F = `${NS}.freezerTemperatureF`;
const EXPRESS_MODE_CAP = `${NS}.expressMode`;
const POWER_SAVE_CAP = `${NS}.powerSave`;
const WATER_FILTER_CAP = `${NS}.waterFilter`;
const DEVICE_PROFILE_ID_C = '473e0f90-7fdb-45dc-b828-8d234ca11e75'; // "LG Fridge C v4" — adds device-level automation section (Routine "If"/"Then" support) + powerSave status key fix, matching the laundry project's working pattern
const DEVICE_PROFILE_ID_F = '21f92354-35af-45ee-a086-f1006b2b0a93'; // "LG Fridge F v10" — adds device-level automation section (Routine "If"/"Then" support), confirmed working via real testing: all 7 capabilities now show as Routine conditions/actions where applicable
function profileIdFor(countryCode) {
  return (countryCode || '').toUpperCase() === 'US' ? DEVICE_PROFILE_ID_F : DEVICE_PROFILE_ID_C;
}

// ─── DynamoDB helpers (identical pattern to the laundry Lambda) ────────────

async function storeData(key, data) {
  await dynamo.send(new PutItemCommand({ TableName: TABLE, Item: marshall({ pk: key, ...data }, { removeUndefinedValues: true }) }));
}
async function getData(key) {
  const r = await dynamo.send(new GetItemCommand({ TableName: TABLE, Key: marshall({ pk: key }) }));
  return r.Item ? unmarshall(r.Item) : null;
}
async function deleteData(key) {
  await dynamo.send(new DeleteItemCommand({ TableName: TABLE, Key: marshall({ pk: key }) }));
}

// ─── LG ThinQ Connect API (copied 1:1 from the laundry Lambda) ─────────────

const LG_API_KEY = 'v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3'; // thinqconnect's public client API key

const REGION_BY_COUNTRY = {
  IL: 'eic', GB: 'eic', DE: 'eic', FR: 'eic', IT: 'eic', ES: 'eic', NL: 'eic',
  US: 'aic', CA: 'aic',
  KR: 'kic', JP: 'kic', AU: 'kic', PH: 'kic', IN: 'kic', SG: 'kic', MY: 'kic',
  TH: 'kic', VN: 'kic', ID: 'kic', TW: 'kic', HK: 'kic', NZ: 'kic',
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
      'x-message-id': crypto.randomBytes(16).toString('base64').slice(0, 22),
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

  control: async (deviceId, pat, clientId, countryCode, payload) => {
    // LG's own API can transiently respond "Retry request" (a real
    // rate-limit response, matching their own PAT test script's warning
    // not to poll in a tight loop). Retry once with a short backoff
    // before giving up — Lambda timeout was raised to accommodate this.
    try {
      return await lgFetch('POST', `devices/${deviceId}/control`, { pat, clientId, countryCode, body: payload });
    } catch (e) {
      if (/retry/i.test(e.message)) {
        console.warn('LG control hit "Retry request", retrying once after 1.5s:', e.message);
        await new Promise(r => setTimeout(r, 1500));
        return lgFetch('POST', `devices/${deviceId}/control`, { pat, clientId, countryCode, body: payload });
      }
      throw e;
    }
  },
};

const FRIDGE_TYPES = new Set(['DEVICE_REFRIGERATOR']);

// ─── Status normalisation ────────────────────────────────────────────────
// Built directly from the real profile/status JSON Homeagain sent.

function normaliseStatus(raw) {
  const s = Array.isArray(raw) ? (raw[0] || {}) : (raw || {});

  const byLocation = (arr) => Object.fromEntries((arr || []).map(x => [x.locationName, x]));
  const temps = byLocation(s.temperatureInUnits);

  return {
    fridgeTempC: temps.FRIDGE ? temps.FRIDGE.targetTemperatureC : null,
    fridgeTempF: temps.FRIDGE ? temps.FRIDGE.targetTemperatureF : null,
    freezerTempC: temps.FREEZER ? temps.FREEZER.targetTemperatureC : null,
    freezerTempF: temps.FREEZER ? temps.FREEZER.targetTemperatureF : null,
    expressModeEnabled: !!s.refrigeration?.expressMode,
    powerSaveEnabled: !!s.powerSave?.powerSaveEnabled,
    doorOpen: (byLocation(s.doorStatus).MAIN || {}).doorState === 'OPEN',
    waterFilterUsedMonths: s.waterFilterInfo?.usedTime ?? null,
  };
}

// ─── Schema Connector ────────────────────────────────────────────────────

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
      if (!FRIDGE_TYPES.has(info.deviceType)) continue;

      response.addDevice(d.deviceId, info.alias || 'LG Fridge', profileIdFor(data.countryCode))
        .manufacturerName('LG')
        .modelName(info.modelName || 'ThinQ Refrigerator')
        .swVersion('1.0.0');
    }
  })

  .stateRefreshHandler(async (accessToken, response) => {
    const data = await getData(accessToken);
    if (!data) return;

    let lgDevices;
    try {
      lgDevices = await LG.listDevices(data.pat, data.clientId, data.countryCode);
    } catch (e) {
      console.error('LG listDevices failed during refresh:', e.message);
      return;
    }

    const fridgeDevices = (lgDevices || []).filter(d => FRIDGE_TYPES.has(d.deviceInfo?.deviceType));
    const updatedDevices = { ...(data.devices || {}) };

    for (const d of fridgeDevices) {
      const deviceId = d.deviceId;
      const component = response.addDevice(deviceId).addComponent('main');

      try {
        const raw = await LG.getStatus(deviceId, data.pat, data.clientId, data.countryCode);
        const s = normaliseStatus(raw);

        component.addState('st.healthCheck', 'healthStatus', 'online');
        const useF = (data.countryCode || '').toUpperCase() === 'US';
        if (useF) {
          if (s.fridgeTempF !== null) component.addState(FRIDGE_TEMP_CAP_F, 'temperatureF', s.fridgeTempF, 'F');
          if (s.freezerTempF !== null) component.addState(FREEZER_TEMP_CAP_F, 'temperatureF', s.freezerTempF, 'F');
        } else {
          if (s.fridgeTempC !== null) component.addState(FRIDGE_TEMP_CAP_C, 'temperatureC', s.fridgeTempC, 'C');
          if (s.freezerTempC !== null) component.addState(FREEZER_TEMP_CAP_C, 'temperatureC', s.freezerTempC, 'C');
        }
        component.addState(EXPRESS_MODE_CAP, 'expressModeEnabled', s.expressModeEnabled);
        component.addState(EXPRESS_MODE_CAP, 'switch', s.expressModeEnabled ? 'on' : 'off');
        component.addState(POWER_SAVE_CAP, 'powerSaveEnabled', s.powerSaveEnabled);
        component.addState(POWER_SAVE_CAP, 'status', s.powerSaveEnabled ? 'on' : 'off');
        component.addState('st.contactSensor', 'contact', s.doorOpen ? 'open' : 'closed');
        if (s.waterFilterUsedMonths !== null) component.addState(WATER_FILTER_CAP, 'usedTimeMonths', s.waterFilterUsedMonths, 'month');

        updatedDevices[deviceId] = { lastStatus: s };
      } catch (err) {
        console.error(`stateRefresh error for ${deviceId}:`, err.message);
        component.addState('st.healthCheck', 'healthStatus', 'offline');
      }
    }

    await storeData(accessToken, { ...data, devices: updatedDevices });
  })

  .commandHandler(async (accessToken, response, devices) => {
    const data = await getData(accessToken);
    if (!data) return;

    for (const device of devices) {
      const component = response.addDevice(device.externalDeviceId).addComponent('main');
      const deviceId = device.externalDeviceId;

      for (const cmd of device.commands) {
        const { capability, command, arguments: args } = cmd;
        console.log('Command:', capability, command, args);

        try {
          if (capability === FRIDGE_TEMP_CAP_C && command === 'setTemperatureC') {
            const tempToSend = Math.round(args[0]); // LG only accepts whole C degrees — no genuine decimal C precision exists
            // Confirmed shape from LG's own Device API docs: locationName
            // and unit live INSIDE the temperature object, flat — no
            // separate "location" wrapper.
            await LG.control(deviceId, data.pat, data.clientId, data.countryCode, {
              temperature: { targetTemperature: tempToSend, locationName: 'FRIDGE', unit: 'C' },
            });
            component.addState(FRIDGE_TEMP_CAP_C, 'temperatureC', tempToSend, 'C');
          }

          if (capability === FREEZER_TEMP_CAP_C && command === 'setTemperatureC') {
            const tempToSend = Math.round(args[0]); // LG only accepts whole C degrees — no genuine decimal C precision exists
            await LG.control(deviceId, data.pat, data.clientId, data.countryCode, {
              temperature: { targetTemperature: tempToSend, locationName: 'FREEZER', unit: 'C' },
            });
            component.addState(FREEZER_TEMP_CAP_C, 'temperatureC', tempToSend, 'C');
          }

          if (capability === FRIDGE_TEMP_CAP_F && command === 'setTemperatureF') {
            const tempF = Math.round(args[0] * 10) / 10;
            const tempC = Math.round((tempF - 32) * 5 / 9);
            await LG.control(deviceId, data.pat, data.clientId, data.countryCode, {
              temperature: { targetTemperature: tempC, locationName: 'FRIDGE', unit: 'C' },
            });
            component.addState(FRIDGE_TEMP_CAP_F, 'temperatureF', tempF, 'F');
          }

          if (capability === FREEZER_TEMP_CAP_F && command === 'setTemperatureF') {
            const tempF = Math.round(args[0] * 10) / 10;
            const tempC = Math.round((tempF - 32) * 5 / 9);
            await LG.control(deviceId, data.pat, data.clientId, data.countryCode, {
              temperature: { targetTemperature: tempC, locationName: 'FREEZER', unit: 'C' },
            });
            component.addState(FREEZER_TEMP_CAP_F, 'temperatureF', tempF, 'F');
          }

          if (capability === EXPRESS_MODE_CAP && (command === 'setExpressMode' || command === 'on' || command === 'off' || command === 'setSwitch')) {
            const enabled = command === 'on' ? true
              : command === 'off' ? false
              : command === 'setSwitch' ? args[0] === 'on'
              : args[0];
            // refrigeration.expressMode has no locationName in the profile
            // (it's not location-scoped), so no location wrapper here either.
            await LG.control(deviceId, data.pat, data.clientId, data.countryCode, {
              refrigeration: { expressMode: enabled },
            });
            component.addState(EXPRESS_MODE_CAP, 'expressModeEnabled', enabled);
            component.addState(EXPRESS_MODE_CAP, 'switch', enabled ? 'on' : 'off');
          }
        } catch (e) {
          console.error('fridge command failed:', capability, command, e.message);
          // Always send at least one state back — an empty states array
          // triggers a separate SmartThings-side "States is empty"
          // BAD-RESPONSE error on top of the actual failure.
          component.addState('st.healthCheck', 'healthStatus', 'online');
        }
      }
    }
  })

  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    const data = await getData(accessToken);
    if (data) await storeData(accessToken, { ...data, callbackAuthentication, callbackUrls });
  })

  .integrationDeletedHandler(async (accessToken) => { await deleteData(accessToken); });

// ─── Scheduled proactive state push (same pattern as laundry) ─────────────

function buildStateArray(s, countryCode, deviceId) {
  const useF = (countryCode || '').toUpperCase() === 'US';
  const states = [
    { component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: 'online' },
    { component: 'main', capability: EXPRESS_MODE_CAP, attribute: 'expressModeEnabled', value: s.expressModeEnabled },
    { component: 'main', capability: EXPRESS_MODE_CAP, attribute: 'switch', value: s.expressModeEnabled ? 'on' : 'off' },
    { component: 'main', capability: POWER_SAVE_CAP, attribute: 'powerSaveEnabled', value: s.powerSaveEnabled },
    { component: 'main', capability: POWER_SAVE_CAP, attribute: 'status', value: s.powerSaveEnabled ? 'on' : 'off' },
    { component: 'main', capability: 'st.contactSensor', attribute: 'contact', value: s.doorOpen ? 'open' : 'closed' },
  ];
  if (useF) {
    if (s.fridgeTempF !== null) states.push({ component: 'main', capability: FRIDGE_TEMP_CAP_F, attribute: 'temperatureF', value: s.fridgeTempF, unit: 'F' });
    if (s.freezerTempF !== null) states.push({ component: 'main', capability: FREEZER_TEMP_CAP_F, attribute: 'temperatureF', value: s.freezerTempF, unit: 'F' });
  } else {
    if (s.fridgeTempC !== null) states.push({ component: 'main', capability: FRIDGE_TEMP_CAP_C, attribute: 'temperatureC', value: s.fridgeTempC, unit: 'C' });
    if (s.freezerTempC !== null) states.push({ component: 'main', capability: FREEZER_TEMP_CAP_C, attribute: 'temperatureC', value: s.freezerTempC, unit: 'C' });
  }
  if (s.waterFilterUsedMonths !== null) states.push({ component: 'main', capability: WATER_FILTER_CAP, attribute: 'usedTimeMonths', value: s.waterFilterUsedMonths, unit: 'month' });
  return states;
}

async function scanLinkedAccounts() {
  const items = [];
  let ExclusiveStartKey;
  do {
    const resp = await dynamo.send(new ScanCommand({ TableName: TABLE, ExclusiveStartKey }));
    for (const raw of resp.Items || []) {
      const item = unmarshall(raw);
      if (item.callbackUrls && item.callbackAuthentication && item.devices && Object.keys(item.devices).length) items.push(item);
    }
    ExclusiveStartKey = resp.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return items;
}

async function pushUpdatesForAllDevices() {
  const accounts = await scanLinkedAccounts();
  const deviceCount = accounts.reduce((n, a) => n + Object.keys(a.devices).length, 0);
  console.log(`Scheduled push: found ${accounts.length} linked account(s), ${deviceCount} device(s)`);

  const updater = new StateUpdateRequest(process.env.ST_CLIENT_ID, process.env.ST_CLIENT_SECRET);

  for (const data of accounts) {
    const updatedDevices = { ...data.devices };
    let removedAny = false;

    for (const deviceId of Object.keys(data.devices)) {
      try {
        const raw = await LG.getStatus(deviceId, data.pat, data.clientId, data.countryCode);
        const s = normaliseStatus(raw);
        const deviceState = [{ externalDeviceId: deviceId, states: buildStateArray(s, data.countryCode, deviceId) }];

        await updater.updateState(
          data.callbackUrls,
          data.callbackAuthentication,
          deviceState,
          async (newCallbackAuth) => {
            await storeData(data.pk, { ...data, devices: updatedDevices, callbackAuthentication: newCallbackAuth });
          }
        );
        updatedDevices[deviceId] = { lastStatus: s };
      } catch (err) {
        console.error(`Push failed for device ${deviceId}:`, err.message);
        // Same stale-record cleanup as the laundry Lambda: a device
        // deleted directly via CLI bypasses integrationDeletedHandler
        // and would otherwise retry forever.
        if (err.message && err.message.includes('Not connected device')) {
          console.warn(`Device ${deviceId} no longer connected on SmartThings' side — removing from account ${data.pk}`);
          delete updatedDevices[deviceId];
          removedAny = true;
        }
      }
    }

    if (removedAny && Object.keys(updatedDevices).length === 0) {
      await deleteData(data.pk);
    } else {
      await storeData(data.pk, { ...data, devices: updatedDevices });
    }
  }
}

// ─── OAuth login page (same PAT + country flow as laundry) ────────────────

function loginPage(sessionId, error) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LG ThinQ Fridge - Connect to SmartThings</title>
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
    <h1>LG ThinQ Fridge</h1>
    <p>Connect your LG refrigerator to SmartThings</p>
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

// ─── Lambda entry point (same routing pattern as laundry) ─────────────────

exports.handler = async (event, context) => {
  console.log('Event:', JSON.stringify({ ...event, body: event.body?.substring(0, 200) }));

  if (event.source === 'lg-thinq-fridge-scheduled-push') {
    await pushUpdatesForAllDevices();
    return { statusCode: 200, body: 'ok' };
  }

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

      const fridge = (devices || []).find(d => FRIDGE_TYPES.has(d.deviceInfo?.deviceType));
      if (!fridge) {
        return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' },
          body: loginPage(sid, 'No refrigerator found on this LG account') };
      }

      const code = crypto.randomBytes(32).toString('hex');
      await storeData(code, { pk: code, pat, clientId, countryCode: country, deviceId: fridge.deviceId });
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
