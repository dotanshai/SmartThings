'use strict';

const { SchemaConnector, StateUpdateRequest, DiscoveryRequest } = require('st-schema');
const https = require('https');
const crypto = require('crypto');
const { DynamoDBClient, GetItemCommand, PutItemCommand, DeleteItemCommand } = require('@aws-sdk/client-dynamodb');
const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');
const lambdaClient = new LambdaClient({ region: process.env.AWS_REGION || 'eu-west-1' });
const { marshall, unmarshall } = require('@aws-sdk/util-dynamodb');

const TABLE  = process.env.TABLE_NAME || 'DolphinBoilerTokens';
const dynamo = new DynamoDBClient({ region: process.env.DYNAMO_REGION || 'us-east-1' });

const NS = 'vehiclepatch55148'; // custom capability namespace
// Device profiles per shower count (1-6) — selected dynamically during discovery
const PROFILE_BY_SHOWERS = {
  1: '61471b5e-cb7a-41f5-9d1d-e2e39873850c',
  2: '4bee4a19-85f9-4755-a9ed-b752909d5b35',
  3: 'ce58276a-aec3-4659-b7e0-5fe1ea0aceb5',
  4: 'df14dda7-54ef-4191-96eb-98a20ac8fb6b',
  5: '73844a66-ce01-4c43-a490-bbada9f9124a',
  6: '22074664-d13e-4996-b0b2-e3b4319c5226',
  7: '53bb2206-680f-4911-a544-c579ab433aa8',
  8: 'fc07357c-df9e-4a28-9f67-7493f86edb74',
  9: 'd9e74639-19bd-4e49-b19e-0f623273205e',
  10: 'de7fb0a4-e23e-45bb-b3fd-fbde4f9d5d2b',
};

// ─── DynamoDB helpers ────────────────────────────────────────────────────────

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

// ─── Dolphin API ─────────────────────────────────────────────────────────────

function dolphinPostOnce(path, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const body = new URLSearchParams(params).toString();
    const req = https.request({
      hostname: 'api.dolphinboiler.com', port: 443, path, method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve({ raw: data }); } });
    });
    req.on('error', reject);
    req.setTimeout(timeoutMs, () => req.destroy(new Error('timeout')));
    req.write(body); req.end();
  });
}

async function dolphinPost(path, params, retries = 2) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await dolphinPostOnce(path, params, 8000);
    } catch (err) {
      lastErr = err;
      console.error(`dolphinPost attempt ${attempt + 1} failed for ${path}:`, err.message);
      if (attempt < retries) await new Promise(r => setTimeout(r, 500));
    }
  }
  throw lastErr;
}

async function dolphinGetKey(email, password) {
  const data = await dolphinPost('/HA/V1/getAPIkey.php', { email, password });
  const key = data.API_Key || data.api_key || data.raw?.trim();
  if (!key) throw new Error('No API key: ' + JSON.stringify(data));
  return key;
}

// Test accounts that don't have a real Dolphin device registered.
// Used only to allow GUI/discovery testing without real hardware.
const TEST_ACCOUNTS = ['you@example.com'];

async function dolphinGetDevices(email, apiKey) {
  const data = await dolphinPost('/HA/V1/getDevices.php', { email, API_Key: apiKey });
  const isTestAccount = TEST_ACCOUNTS.includes(email.toLowerCase());

  // Dolphin's API returns {"Error": "..."} (not an empty list) when the
  // account has no registered device.
  if (data && data.Error) {
    if (isTestAccount) return [{ deviceName: 'TEST', nickname: 'Test Boiler' }];
    throw new Error('No devices found on this Dolphin account');
  }

  const list = Array.isArray(data) ? data : (data.devices || data.Devices || []);
  if (!list.length) {
    if (isTestAccount) return [{ deviceName: 'TEST', nickname: 'Test Boiler' }];
    throw new Error('No devices found on this Dolphin account');
  }
  return list; // [{ deviceName, nickname }, ...]
}

async function dolphinGetStatus(deviceName, email, apiKey) {
  return dolphinPost('/HA/V1/getMainScreenData.php', { deviceName, email, API_Key: apiKey });
}

async function dolphinCmd(path, deviceName, email, apiKey, extra = {}) {
  return dolphinPost(path, { deviceName, email, API_Key: apiKey, ...extra });
}

const Dolphin = {
  turnOnManually:        (d, e, k, temp)   => dolphinCmd('/HA/V1/turnOnManually.php', d, e, k, { temperature: temp }),
  turnOffManually:       (d, e, k)         => dolphinCmd('/HA/V1/turnOffManually.php', d, e, k),
  enableShabbat:         (d, e, k)         => dolphinCmd('/HA/V1/enableShabbat.php', d, e, k),
  disableShabbat:        (d, e, k)         => dolphinCmd('/HA/V1/disableShabbat.php', d, e, k),
  turnOnFixedTemperature:(d, e, k, temp)   => dolphinCmd('/HA/V1/setFixedTemperature.php', d, e, k, { temperature: temp }),
  turnOffFixedTemperature:(d, e, k)        => dolphinCmd('/HA/V1/turnOffFixedTemperature.php', d, e, k),
};

// ─── Status normalisation (matches HA integration's models.py exactly) ───────

function normaliseStatus(raw, fallbackTargetTemp = 40) {
  const power = raw.Power === 'ON';
  const energy = raw.Energy ? parseFloat(raw.Energy) : 0;
  const temperature = raw.Temperature && raw.Temperature > 0 ? parseFloat(raw.Temperature) : null;
  const targetTemperature = raw.targetTemperature && raw.targetTemperature > 0 ? parseInt(raw.targetTemperature) : fallbackTargetTemp;
  const shabbat = raw.Shabbat === 'ON';
  const fixedTemperature = raw.fixedTemperature === 'ON';
  const showerTemperature = raw.showerTemperature || null; // array of {temp: N}

  return { power, energy, temperature, targetTemperature, shabbat, fixedTemperature, showerTemperature };
}

// ─── Proactive state callback (push a state update outside the request cycle) ─

async function pushProactiveState(accessToken, externalDeviceId, states) {
  const data = await getData(accessToken);
  if (!data || !data.callbackAuthentication || !data.callbackUrls) {
    console.error('No callback auth/urls stored for proactive update');
    return;
  }
  const requester = new StateUpdateRequest(process.env.ST_CLIENT_ID, process.env.ST_CLIENT_SECRET);
  const deviceState = [{ externalDeviceId, states }];
  try {
    await requester.updateState(data.callbackUrls, data.callbackAuthentication, deviceState, async (newCallbackAuth) => {
      // Refresh token was used; persist the new one.
      await storeData(accessToken, { ...data, callbackAuthentication: newCallbackAuth });
    });
  } catch (err) {
    console.error('Proactive state update failed:', err.message);
  }
}

// ─── Schema Connector ────────────────────────────────────────────────────────

const connector = new SchemaConnector()
  .clientId(process.env.ST_CLIENT_ID)
  .clientSecret(process.env.ST_CLIENT_SECRET)
  .enableEventLogging(2)

  .discoveryHandler(async (accessToken, response) => {
    const data = await getData(accessToken);
    if (!data) { console.error('No data for token:', accessToken); return; }

    // Get shower count from Dolphin API to select correct profile
    let showerCount = 4; // default fallback
    try {
      const { apiKey, email, deviceName } = data;
      if (apiKey && email && deviceName && deviceName !== 'TEST') {
        const status = await dolphinGetStatus(deviceName, email, apiKey);
        const count = (status?.showerTemperature || []).length;
        if (count >= 1 && count <= 10) showerCount = count;
      }
    } catch (e) {
      console.warn('Could not determine shower count, using default:', e.message);
    }

    const profileId = PROFILE_BY_SHOWERS[showerCount] || PROFILE_BY_SHOWERS[4];
    console.log(`Discovery: shower count=${showerCount}, profile=${profileId}`);

    response.addDevice(data.deviceName || 'dolphin-boiler-001', data.nickname || 'Dolphin Boiler', profileId)
      .manufacturerName('Dolphin')
      .modelName('Smart Boiler')
      .swVersion('1.0.0');
  })

  .stateRefreshHandler(async (accessToken, response) => {
    const data = await getData(accessToken);
    if (!data) return;

    const deviceId = data.deviceName || 'dolphin-boiler-001';
    const device = response.addDevice(deviceId);
    const component = device.addComponent('main');

    try {
      let { apiKey, email, password, deviceName } = data;
      if (!apiKey) { apiKey = await dolphinGetKey(email, password); await storeData(accessToken, { ...data, apiKey }); }

      const raw = await dolphinGetStatus(deviceName, email, apiKey);
      console.log('Dolphin raw status:', JSON.stringify(raw));
      const fallbackTargetTemp = data.desiredTemperature || data.lastStatus?.targetTemperature || 40;
      const s = normaliseStatus(raw, fallbackTargetTemp);

      // Standard capabilities
      component.addState('st.switch', 'switch', s.power ? 'on' : 'off');
      component.addState('st.healthCheck', 'healthStatus', 'online');
      if (s.temperature !== null) {
        component.addState('st.temperatureMeasurement', 'temperature', s.temperature, 'C');
      }
      component.addState('st.thermostatHeatingSetpoint', 'heatingSetpoint', s.targetTemperature, 'C');
      component.addState(`${NS}.targetTemperature`, 'temperature', s.targetTemperature, 'C');
      // Combined dashboard state: current + target temperature
      const targetTemp = (s.targetTemperature !== null && s.targetTemperature !== undefined) ? s.targetTemperature : s.temperature;
      component.addState(`${NS}.boilerTemperature`, 'currentTemperature', s.temperature, 'C');
      component.addState(`${NS}.boilerTemperature`, 'targetTemperature', targetTemp, 'C');

      // Custom capabilities
      component.addState(`${NS}.shabbatMode`, 'shabbatMode', s.shabbat ? 'enabled' : 'disabled');
      component.addState(`${NS}.fixedTemperatureControl`, 'fixedTemperatureControl', s.fixedTemperature ? 'enabled' : 'disabled');
      component.addState('st.currentMeasurement', 'current', s.energy, 'A');

      // Shower presets - dynamic based on API response (up to 6), using lowercase capability IDs
      const showerCapIds = [`${NS}.shower1`, `${NS}.shower2`, `${NS}.shower3`, `${NS}.shower4`, `${NS}.shower5`, `${NS}.shower6`, `${NS}.shower7`, `${NS}.shower8`, `${NS}.shower9`, `${NS}.shower10`];
      const showerCount = Math.min((s.showerTemperature || []).length, 10);
      for (let i = 1; i <= showerCount; i++) {
        const preset = s.showerTemperature[i - 1];
        const presetTemp = preset ? preset.temp : null;
        component.addState(showerCapIds[i - 1], 'switch', 'off');
        if (presetTemp !== null) {
          component.addState(showerCapIds[i - 1], 'temperature', presetTemp, 'C');
        }
      }

      // Cache last known status for command handler logic
      const newShowerCount = (s.showerTemperature || []).length;
      const prevShowerCount = data.lastShowerCount || 0;
      await storeData(accessToken, { ...data, apiKey, lastStatus: s, lastShowerCount: newShowerCount });

      // Dynamic profile switch: if shower count changed, send discoveryCallback with new profile
      if (newShowerCount !== prevShowerCount && newShowerCount >= 1 && newShowerCount <= 10 &&
          data.callbackAuthentication && data.callbackUrls) {
        const newProfileId = PROFILE_BY_SHOWERS[newShowerCount];
        console.log(`Shower count changed ${prevShowerCount} -> ${newShowerCount}, switching profile to ${newProfileId}`);
        try {
          // Invoke self asynchronously so discoveryCallback fires after stateRefresh completes
          const selfPayload = JSON.stringify({
            action: 'sendDiscoveryCallback',
            accessToken,
            deviceId,
            profileId: newProfileId,
            nickname: data.nickname || 'Dolphin Boiler'
          });
          await lambdaClient.send(new InvokeCommand({
            FunctionName: process.env.AWS_LAMBDA_FUNCTION_NAME,
            InvocationType: 'Event',
            Payload: Buffer.from(selfPayload)
          }));
          console.log(`Async discovery callback scheduled for profile ${newProfileId}`);
        } catch (e) {
          console.warn('Profile switch callback failed:', e.message);
        }
      }

    } catch (err) {
      console.error('stateRefresh error:', err.message);
      component.addState('st.switch', 'switch', 'off');
      component.addState('st.healthCheck', 'healthStatus', 'offline');
    }
  })

  .commandHandler(async (accessToken, response, devices) => {
    const data = await getData(accessToken);
    if (!data) return;

    let { apiKey, email, password, deviceName, lastStatus } = data;
    if (!apiKey) { apiKey = await dolphinGetKey(email, password); await storeData(accessToken, { ...data, apiKey }); }

    const maxTemp = 71; // from HA integration's _attr_max_temp

    for (const device of devices) {
      const component = response.addDevice(device.externalDeviceId).addComponent('main');

      for (const cmd of device.commands) {
        const { capability, command, arguments: args } = cmd;
        console.log('Command:', capability, command, args);

        try {
          // ── Main switch (power) ──────────────────────────────────────────
          if (capability === 'st.switch') {
            const turningOn = command === 'on';
            try {
              if (turningOn) {
                // Use the previously requested "desired" temperature if set,
                // otherwise fall back to the max temp.
                const desiredTemp = data.desiredTemperature || maxTemp;
                await Dolphin.turnOnManually(deviceName, email, apiKey, desiredTemp);
              } else {
                await Dolphin.turnOffManually(deviceName, email, apiKey);
              }
              component.addState('st.switch', 'switch', turningOn ? 'on' : 'off');
            } catch (e) {
              console.error('switch command failed:', e.message);
              component.addState('st.switch', 'switch', turningOn ? 'off' : 'on');
            }
          }

          // ── Target temperature (standard capability) ─────────────────────
          else if (capability === 'st.thermostatHeatingSetpoint') {
            const temp = args?.[0];
            try {
              await Dolphin.turnOnManually(deviceName, email, apiKey, temp);
              // Always show the requested value immediately — even if the boiler
              // can't act on it right now (e.g. water already hotter), it's
              // remembered as the desired target for the next time it's turned on.
              component.addState('st.thermostatHeatingSetpoint', 'heatingSetpoint', temp, 'C');
              component.addState(`${NS}.targetTemperature`, 'temperature', temp, 'C');
              await storeData(accessToken, { ...data, apiKey, desiredTemperature: temp });
            } catch (e) {
              console.error('thermostatHeatingSetpoint command failed:', e.message);
            }
          }

          // ── Target temperature (custom capability, full 20-71C range) ────
          else if (capability === `${NS}.targetTemperature`) {
            const temp = args?.[0];
            try {
              await Dolphin.turnOnManually(deviceName, email, apiKey, temp);
              component.addState(`${NS}.targetTemperature`, 'temperature', temp, 'C');
              component.addState('st.thermostatHeatingSetpoint', 'heatingSetpoint', temp, 'C');
              await storeData(accessToken, { ...data, apiKey, desiredTemperature: temp });
            } catch (e) {
              console.error('targetTemperature command failed:', e.message);
            }
          }

          // ── Shabbat mode ──────────────────────────────────────────────────
          else if (capability === `${NS}.shabbatMode`) {
            const value = args?.[0];
            const enabling = value === 'enabled';
            try {
              if (enabling) await Dolphin.enableShabbat(deviceName, email, apiKey);
              else await Dolphin.disableShabbat(deviceName, email, apiKey);
              component.addState(`${NS}.shabbatMode`, 'shabbatMode', enabling ? 'enabled' : 'disabled');
            } catch (e) {
              console.error('shabbatMode command failed:', e.message);
              component.addState(`${NS}.shabbatMode`, 'shabbatMode', enabling ? 'disabled' : 'enabled');
            }
          }

          // ── Fixed temperature mode ───────────────────────────────────────
          else if (capability === `${NS}.fixedTemperatureControl`) {
            const value = args?.[0];
            const enabling = value === 'enabled';
            try {
              if (enabling) {
                const target = lastStatus?.targetTemperature || 40;
                await Dolphin.turnOnFixedTemperature(deviceName, email, apiKey, target);
              } else {
                await Dolphin.turnOffFixedTemperature(deviceName, email, apiKey);
              }
              component.addState(`${NS}.fixedTemperatureControl`, 'fixedTemperatureControl', enabling ? 'enabled' : 'disabled');
            } catch (e) {
              console.error('fixedTemperatureControl command failed:', e.message);
              component.addState(`${NS}.fixedTemperatureControl`, 'fixedTemperatureControl', enabling ? 'disabled' : 'enabled');
            }
          }

          // ── Showers 1-6 (shows on; reverts on next state refresh) ───
          else if (/^vehiclepatch55148\.(shower1|shower2|shower3|shower4|shower5|shower6|shower7|shower8|shower9|shower10)$/.test(capability)) {
            const showerCapIds = [`${NS}.shower1`, `${NS}.shower2`, `${NS}.shower3`, `${NS}.shower4`, `${NS}.shower5`, `${NS}.shower6`, `${NS}.shower7`, `${NS}.shower8`, `${NS}.shower9`, `${NS}.shower10`];
            const idx = showerCapIds.indexOf(capability) + 1;
            const preset = lastStatus?.showerTemperature && lastStatus.showerTemperature[idx - 1];
            const presetTemp = preset ? preset.temp : null;
            const value = args?.[0];

            if (value === 'on' && presetTemp !== null) {
              try {
                await Dolphin.turnOnManually(deviceName, email, apiKey, presetTemp);
                component.addState(capability, 'switch', 'on');
              } catch (e) {
                console.error('turnOnManually failed:', e.message);
                component.addState(capability, 'switch', 'off');
              }
            } else {
              component.addState(capability, 'switch', 'off');
            }
          }

        } catch (err) {
          console.error('Command error:', err.message);
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
  <title>Dolphin Boiler - Connect to SmartThings</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: -apple-system, Arial, sans-serif; max-width: 420px; margin: 60px auto; padding: 20px; background: #f0f2f5; }
    .card { background: white; border-radius: 16px; padding: 36px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
    .logo { text-align: center; margin-bottom: 12px; }
    h1 { color: #1a73e8; font-size: 24px; text-align: center; margin: 0 0 8px; }
    p { color: #666; font-size: 14px; text-align: center; margin: 0 0 24px; }
    label { display: block; font-size: 13px; color: #444; margin-bottom: 4px; font-weight: 500; }
    input { width: 100%; padding: 12px 14px; margin-bottom: 16px; border: 1.5px solid #ddd; border-radius: 10px; font-size: 15px; }
    input:focus { outline: none; border-color: #1a73e8; }
    button { width: 100%; padding: 14px; background: #1a73e8; color: white; border: none; border-radius: 10px; font-size: 16px; font-weight: 600; cursor: pointer; }
    button:hover { background: #1557b0; }
    .error { color: #d93025; background: #fce8e6; padding: 12px; border-radius: 8px; margin-bottom: 20px; font-size: 14px; text-align: center; }
  </style>
</head>
<body>
  <div class="card">
    <div class="logo"><img src="https://dolphin-boiler-icons-<AWS_ACCOUNT_ID>.s3.amazonaws.com/dolphin_icon_2x.png" style="width:120px" alt="Dolphin"></div>
    <h1>Dolphin Boiler</h1>
    <p>Connect your Dolphin boiler to SmartThings</p>
    ${error ? `<div class="error">${error}</div>` : ''}
    <form method="POST" action="/authorize">
      <input type="hidden" name="s" value="${sessionId}">
      <label>Email</label><input type="email" name="e" required autofocus>
      <label>Password</label><input type="password" name="p" required>
      <button>Connect to SmartThings</button>
    </form>
  </div>
</body>
</html>`;
}

// ─── Device picker page (shown only if account has 2+ boilers) ────────────────

function devicePickerPage(sessionId, devices) {
  const options = devices.map((d, i) =>
    `<label class="device-option">
       <input type="radio" name="d" value="${d.deviceName}" ${i === 0 ? 'checked' : ''}>
       <span>${d.nickname || d.deviceName}</span>
     </label>`
  ).join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Dolphin Boiler - Select Device</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: -apple-system, Arial, sans-serif; max-width: 420px; margin: 60px auto; padding: 20px; background: #f0f2f5; }
    .card { background: white; border-radius: 16px; padding: 36px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
    .logo { text-align: center; margin-bottom: 12px; }
    h1 { color: #1a73e8; font-size: 22px; text-align: center; margin: 0 0 8px; }
    p { color: #666; font-size: 14px; text-align: center; margin: 0 0 20px; }
    .device-option { display: flex; align-items: center; gap: 10px; padding: 14px; border: 1.5px solid #ddd; border-radius: 10px; margin-bottom: 10px; cursor: pointer; }
    .device-option input { margin: 0; }
    .device-option span { font-size: 15px; color: #222; }
    button { width: 100%; padding: 14px; background: #1a73e8; color: white; border: none; border-radius: 10px; font-size: 16px; font-weight: 600; cursor: pointer; margin-top: 8px; }
    button:hover { background: #1557b0; }
  </style>
</head>
<body>
  <div class="card">
    <div class="logo"><img src="https://dolphin-boiler-icons-<AWS_ACCOUNT_ID>.s3.amazonaws.com/dolphin_icon_2x.png" style="width:120px" alt="Dolphin"></div>
    <h1>Select your boiler</h1>
    <p>We found multiple Dolphin boilers on this account</p>
    <form method="POST" action="/select-device">
      <input type="hidden" name="s" value="${sessionId}">
      ${options}
      <button>Continue</button>
    </form>
  </div>
</body>
</html>`;
}



exports.handler = async (event, context) => {
  console.log('Event:', JSON.stringify({ ...event, body: event.body?.substring(0, 200) }));

  // Handle async self-invocation for discoveryCallback (profile switching)
  if (event.action === 'sendDiscoveryCallback') {
    const { accessToken, deviceId, profileId, nickname } = event;
    console.log(`Processing async discoveryCallback for device ${deviceId}, profile ${profileId}`);
    try {
      const data = await getData(accessToken);
      if (!data || !data.callbackUrls || !data.callbackAuthentication) {
        console.error('No callback data found for token');
        return;
      }
      // Use plain object exactly as nayelyz recommended
      const device = {
        externalDeviceId: deviceId,
        friendlyName: nickname,
        deviceHandlerType: profileId,
        manufacturerInfo: {
          manufacturerName: 'Dolphin',
          modelName: 'Smart Boiler'
        }
      };
      const discoveryRequest = new DiscoveryRequest(process.env.ST_CLIENT_ID, process.env.ST_CLIENT_SECRET);
      discoveryRequest.addDevice(device);
      await discoveryRequest.sendDiscovery(
        data.callbackUrls,
        data.callbackAuthentication,
        async (newCallbackAuth) => {
          await storeData(accessToken, { ...data, callbackAuthentication: newCallbackAuth });
          console.log('Callback auth token refreshed during async discovery');
        }
      );
      console.log(`Async discoveryCallback sent successfully, profile switched to ${profileId}`);
    } catch (e) {
      console.error('Async discoveryCallback failed:', e.message);
    }
    return;
  }

  if (event.requestContext) {
    const method = (event.requestContext.http?.method || event.httpMethod || '').toUpperCase();
    const path   = event.requestContext.http?.path   || event.path || '';
    const qs     = event.queryStringParameters || {};

    if (path === '/authorize' && method === 'GET') {
      const sid = crypto.randomBytes(16).toString('hex');
      await storeData('s:' + sid, { pk: 's:' + sid, r: qs.redirect_uri || '', st: qs.state || '' });
      return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: loginPage(sid) };
    }

    if (path === '/authorize' && method === 'POST') {
      const rawBody = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
      const params = new URLSearchParams(rawBody);
      const sid = params.get('s') || '', email = params.get('e') || '', password = params.get('p') || '';
      const sess = await getData('s:' + sid);
      const redirectUri = sess ? sess.r : '', state = sess ? sess.st : '';

      let apiKey, devices;
      try { apiKey = await dolphinGetKey(email, password); }
      catch { return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: loginPage(sid, 'Invalid email or password') }; }

      try { devices = await dolphinGetDevices(email, apiKey); }
      catch { return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: loginPage(sid, 'No Dolphin boiler found on this account') }; }

      if (devices.length > 1) {
        // Store credentials temporarily on the session so /select-device can finish the flow
        await storeData('s:' + sid, { pk: 's:' + sid, r: redirectUri, st: state, email, password, apiKey });
        return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: devicePickerPage(sid, devices) };
      }

      const deviceName = devices[0].deviceName;
      const code = crypto.randomBytes(32).toString('hex');
      await storeData(code, { pk: code, email, password, deviceName, apiKey });
      if (sess) await deleteData('s:' + sid);

      const url = new URL(redirectUri);
      url.searchParams.set('code', code);
      url.searchParams.set('state', state);
      return { statusCode: 302, headers: { Location: url.toString() }, body: '' };
    }

    if (path === '/select-device' && method === 'POST') {
      const rawBody = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
      const params = new URLSearchParams(rawBody);
      const sid = params.get('s') || '', deviceName = params.get('d') || '';
      const sess = await getData('s:' + sid);
      if (!sess || !sess.email || !sess.apiKey) {
        return { statusCode: 400, body: 'Session expired, please start over.' };
      }
      const { r: redirectUri, st: state, email, password, apiKey } = sess;

      const code = crypto.randomBytes(32).toString('hex');
      await storeData(code, { pk: code, email, password, deviceName, apiKey });
      await deleteData('s:' + sid);

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
