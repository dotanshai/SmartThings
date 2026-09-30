'use strict';

const { SchemaConnector, DeviceErrorTypes, StateUpdateRequest } = require('st-schema');
const { CognitoIdentityProviderClient, InitiateAuthCommand, RespondToAuthChallengeCommand } = require('@aws-sdk/client-cognito-identity-provider');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand, ScanCommand } = require('@aws-sdk/lib-dynamodb');
const https = require('https');
const { randomUUID } = require('crypto');

// ---- Config (env vars) ----
const TABLE_NAME = process.env.TABLE_NAME;
const DYNAMO_REGION = process.env.DYNAMO_REGION || 'eu-west-1';
const ST_CLIENT_ID = process.env.ST_CLIENT_ID;
const ST_CLIENT_SECRET = process.env.ST_CLIENT_SECRET;
const DEVICE_PROFILE_ID = process.env.DEVICE_PROFILE_ID;

// Tadiran / Cognito constants (from captured traffic)
const COGNITO_REGION = 'eu-west-1';
const COGNITO_CLIENT_ID = '312eed498hlvku8pdup0lvfpir';
const ORGANIZATION_ID = 'tenant-f365f952-9143-4004-95b6-5042aed5b7cd'; // TODO: confirm if this varies per account
const TADIRAN_API_HOST = 'api.tadiran-iot.co.il';

const ddbClient = new DynamoDBClient({ region: DYNAMO_REGION });
const ddb = DynamoDBDocumentClient.from(ddbClient);
const cognito = new CognitoIdentityProviderClient({ region: COGNITO_REGION });

// =====================================================================
// Cognito helpers
// =====================================================================

function normalizeIsraeliPhone(raw) {
  let p = (raw || '').trim().replace(/[\s-]/g, '');
  if (p.startsWith('+')) return p;
  if (p.startsWith('00')) return '+' + p.slice(2);
  if (p.startsWith('972')) return '+' + p;
  if (p.startsWith('0')) return '+972' + p.slice(1);
  return '+972' + p;
}

async function cognitoInitiateAuth(phoneNumber) {
  const resp = await cognito.send(new InitiateAuthCommand({
    ClientId: COGNITO_CLIENT_ID,
    AuthFlow: 'CUSTOM_AUTH',
    AuthParameters: { USERNAME: phoneNumber }
  }));
  return resp; // contains Session
}

async function cognitoRespondToChallenge(phoneNumber, session, otp) {
  const resp = await cognito.send(new RespondToAuthChallengeCommand({
    ClientId: COGNITO_CLIENT_ID,
    ChallengeName: 'CUSTOM_CHALLENGE',
    ChallengeResponses: { USERNAME: phoneNumber, ANSWER: otp },
    Session: session
  }));
  return resp.AuthenticationResult; // { AccessToken, IdToken, RefreshToken, ExpiresIn }
}

async function cognitoRefresh(refreshToken) {
  const resp = await cognito.send(new InitiateAuthCommand({
    ClientId: COGNITO_CLIENT_ID,
    AuthFlow: 'REFRESH_TOKEN_AUTH',
    AuthParameters: { REFRESH_TOKEN: refreshToken }
  }));
  return resp.AuthenticationResult; // { AccessToken, IdToken, ExpiresIn } - no new RefreshToken
}

// =====================================================================
// Tadiran API helpers
// =====================================================================

function tadiranRequest(method, path, accessToken, idToken, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const options = {
      hostname: TADIRAN_API_HOST,
      path,
      method,
      headers: {
        'accept': 'application/json, text/plain, */*',
        'authorization': `Bearer ${accessToken}`,
        'idtoken': idToken,
        'organizationid': ORGANIZATION_ID,
        'User-Agent': 'okhttp/4.12.0'
      }
    };
    if (payload) {
      options.headers['Content-Type'] = 'application/json';
      options.headers['Content-Length'] = Buffer.byteLength(payload);
    }

    const req = https.request(options, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8'); // avoid UTF-8 split-chunk corruption (LG bug lesson)
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try {
            resolve(raw ? JSON.parse(raw) : {});
          } catch (e) {
            resolve({});
          }
        } else {
          reject(new Error(`Tadiran API ${method} ${path} failed: ${res.statusCode} ${raw}`));
        }
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function getDevices(accessToken, idToken) {
  return tadiranRequest('GET', '/mobile-app/api/v1/devices/', accessToken, idToken);
}

async function setDeviceFields(accessToken, idToken, deviceId, fields) {
  // fields: [{name, value}, ...]
  const path = `/mobile-app/api/v1/devices/${deviceId}/shadow/update/?device_id=${deviceId}`;
  return tadiranRequest('PUT', path, accessToken, idToken, fields);
}

// =====================================================================
// DynamoDB token record helpers
// Record keyed by the accessToken we hand to SmartThings (== Cognito AccessToken)
// =====================================================================

async function saveTokenRecord(accessToken, record) {
  await ddb.send(new PutCommand({
    TableName: TABLE_NAME,
    Item: { accessToken, ...record, updatedAt: Date.now() }
  }));
}

async function getTokenRecord(accessToken) {
  const resp = await ddb.send(new GetCommand({
    TableName: TABLE_NAME,
    Key: { accessToken }
  }));
  return resp.Item;
}

async function deleteTokenRecord(accessToken) {
  await ddb.send(new DeleteCommand({ TableName: TABLE_NAME, Key: { accessToken } }));
}

// Decodes the stable Cognito user id ("sub" claim) from a JWT, without verifying
// the signature (we already trust tokens arriving through SmartThings' own
// authenticated channel). Used to match an account across access-token rotations.
function decodeJwtSub(token) {
  try {
    const payload = token.split('.')[1];
    const json = Buffer.from(payload.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
    return JSON.parse(json).sub;
  } catch (e) {
    return null;
  }
}

// Ensures we have a fresh (non-expired) Cognito access/id token for this record.
// If expired, refreshes via Cognito, saves a NEW record under the NEW access token,
// and returns { accessToken, idToken, record }.
async function ensureFreshTokens(record) {
  const now = Date.now();
  if (record.cognitoExpiresAt && now < record.cognitoExpiresAt - 5 * 60 * 1000) {
    return { accessToken: record.cognitoAccessToken, idToken: record.cognitoIdToken, record };
  }
  // Expired or close to it - refresh
  const auth = await cognitoRefresh(record.cognitoRefreshToken);
  const newRecord = {
    ...record,
    cognitoAccessToken: auth.AccessToken,
    cognitoIdToken: auth.IdToken,
    cognitoExpiresAt: now + (auth.ExpiresIn * 1000)
  };
  // Old record's key was record.cognitoAccessToken - move to new key
  await saveTokenRecord(auth.AccessToken, newRecord);
  if (record.cognitoAccessToken !== auth.AccessToken) {
    await deleteTokenRecord(record.cognitoAccessToken).catch(() => {});
  }
  return { accessToken: auth.AccessToken, idToken: auth.IdToken, record: newRecord };
}

// =====================================================================
// Device <-> SmartThings state mapping
// =====================================================================

function getDeviceExternalId(device) {
  return device.device_id || device.asset_id || device.id;
}

function fieldsArrayToConfigurations(fields, optimistic = false) {
  const c = {};
  const map = {
    power: 'power', temp_set: 'temp_set', temp_current: 'temp_current',
    mode: 'mode', wind_speed: 'wind_speed', swing_ud: 'swing_ud',
    swing_lr: 'swing_lr', light: 'light', turbo: 'turbo', mute: 'mute', online: 'online'
  };
  // Sensor/read-only fields: always trust the reported (actual) value, never the desired placeholder.
  const sensorFields = new Set(['temp_current', 'online']);
  for (const f of fields) {
    if (!(f.name in map)) continue;
    let v;
    if (sensorFields.has(f.name)) {
      v = (f.reported !== undefined && f.reported !== null) ? f.reported : f.desired;
    } else if (optimistic) {
      // Immediately after a command: prefer the just-issued desired value so SmartThings
      // doesn't briefly show a stale/lagging state before the physical device catches up.
      v = (f.desired !== undefined && f.desired !== null && f.desired !== '') ? f.desired : f.reported;
    } else {
      // Periodic refresh / discovery / proactive sync: trust the reported (actual) value,
      // so a desired value that never actually applied doesn't get shown as real long-term.
      v = (f.reported !== undefined && f.reported !== null) ? f.reported : f.desired;
    }
    if (v === 'true') v = true;
    if (v === 'false') v = false;
    if (typeof v === 'string' && v !== '' && !isNaN(v) && (f.name === 'temp_set' || f.name === 'temp_current')) v = Number(v);
    // Tadiran's shadow sometimes returns `desired.mode` in inconsistent casing (e.g. "Cool"
    // instead of "COOL"), while `reported.mode` is reliably upper-case. SmartThings' acMode
    // capability enum is strictly upper-case (COOL/HEAT/FAN/DRY/AUTO) and rejects the ENTIRE
    // command response (including power/switch state) if any single field fails validation -
    // so a lowercase/mixed-case mode silently kills the whole "on" command from the user's
    // point of view. Always normalize to upper-case regardless of which field it came from.
    if (f.name === 'mode' && typeof v === 'string') v = v.toUpperCase();
    c[f.name] = v;
  }
  return c;
}

function deviceToStates(device) {
  const c = device.configurations || {};
  const extId = getDeviceExternalId(device) || 'unknown';
  return [
    { component: 'main', capability: 'st.switch', attribute: 'switch', value: c.power ? 'on' : 'off' },
    { component: 'main', capability: 'st.temperatureMeasurement', attribute: 'temperature', value: Number((typeof c.temp_current === 'number') ? c.temp_current : 24), unit: 'C' },
    { component: 'main', capability: 'st.thermostatCoolingSetpoint', attribute: 'coolingSetpoint', value: Number((typeof c.temp_set === 'number') ? c.temp_set : 24), unit: 'C' },

    { component: 'main', capability: 'vehiclepatch55148.acTemperature', attribute: 'tempSet', value: (typeof c.temp_set === 'number') ? c.temp_set : 24 },
    { component: 'main', capability: 'vehiclepatch55148.acTemperature', attribute: 'tempCurrent', value: (typeof c.temp_current === 'number') ? c.temp_current : 24 },
    { component: 'main', capability: 'vehiclepatch55148.acMode', attribute: 'mode', value: c.mode || 'COOL' },
    { component: 'main', capability: 'vehiclepatch55148.acFanSpeed', attribute: 'fanSpeed', value: c.wind_speed || 'LOW' },
    { component: 'main', capability: 'vehiclepatch55148.acSwingUpDown', attribute: 'switch', value: c.swing_ud ? 'on' : 'off' },
    { component: 'main', capability: 'vehiclepatch55148.acSwingLeftRight', attribute: 'switch', value: c.swing_lr ? 'on' : 'off' },
    { component: 'main', capability: 'vehiclepatch55148.acLight', attribute: 'switch', value: c.light ? 'on' : 'off' },
    { component: 'main', capability: 'vehiclepatch55148.acTurbo', attribute: 'switch', value: c.turbo ? 'on' : 'off' },
    { component: 'main', capability: 'vehiclepatch55148.acMute', attribute: 'switch', value: c.mute ? 'on' : 'off' },
    { component: 'main', capability: 'vehiclepatch55148.acStatus', attribute: 'statusSwitch', value: c.power ? 'on' : 'off' },
    { component: 'main', capability: 'vehiclepatch55148.acStatus', attribute: 'statusMode', value: c.mode || 'COOL' },
    { component: 'main', capability: 'vehiclepatch55148.acStatus', attribute: 'statusTempSet', value: (typeof c.temp_set === 'number') ? c.temp_set : 24 },
    { component: 'main', capability: 'vehiclepatch55148.acStatus2', attribute: 'statusMode', value: c.mode || 'COOL' },
    { component: 'main', capability: 'vehiclepatch55148.acStatus2', attribute: 'statusTempSet', value: (typeof c.temp_set === 'number') ? c.temp_set : 24 },
    { component: 'main', capability: 'vehiclepatch55148.acDeviceId', attribute: 'shortId', value: extId.slice(0, 8) },
    { component: 'main', capability: 'st.healthCheck', attribute: 'checkInterval', value: 3600 },
    { component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: (c.online === false) ? 'offline' : 'online' }
  ];
}

// =====================================================================
// st-schema connector setup
// =====================================================================

async function scanAllTokenRecords() {
  const records = [];
  let ExclusiveStartKey;
  do {
    const resp = await ddb.send(new ScanCommand({ TableName: TABLE_NAME, ExclusiveStartKey }));
    records.push(...(resp.Items || []));
    ExclusiveStartKey = resp.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return records;
}

// Proactively fetches current device state from Tadiran for every linked account
// and pushes it to SmartThings via the async state-update callback, so changes
// made outside SmartThings (Alexa, Google Home, My Tadiran app) show up promptly.
async function syncOneAccount(record) {
  if (!record.callbackAuthentication || !record.callbackUrls) {
    console.log('PROACTIVE SYNC - skipping account ending', (record.accessToken || '').slice(-6), '(no callbackAuthentication on file yet)');
    return; // account never completed the grantCallbackAccess step
  }
  const idHint = (record.accessToken || '').slice(-6);
  try {
    const { accessToken, idToken, record: freshRecord } = await ensureFreshTokens(record);
    const devices = await getDevices(accessToken, idToken);
    const deviceState = [];
    for (const device of devices) {
      const extId = getDeviceExternalId(device);
      if (!extId) continue;
      let configurations;
      try {
        const shadow = await setDeviceFields(accessToken, idToken, extId, []);
        configurations = fieldsArrayToConfigurations(shadow);
      } catch (e) {
        console.error('PROACTIVE SYNC - shadow read failed for', extId, 'account ending', idHint, e.message);
        continue;
      }
      const states = deviceToStates({ device_id: extId, configurations }).map(
        s => ({ component: s.component, capability: s.capability, attribute: s.attribute, value: s.value, unit: s.unit })
      );
      deviceState.push({ externalDeviceId: extId, states });
    }
    if (deviceState.length === 0) return;

    let callbackAuth = freshRecord.callbackAuthentication;
    const callbackUrls = freshRecord.callbackUrls;
    await new StateUpdateRequest(ST_CLIENT_ID, ST_CLIENT_SECRET).updateState(
      callbackUrls,
      callbackAuth,
      deviceState,
      async (refreshedCallbackAuth) => {
        callbackAuth = refreshedCallbackAuth;
        await saveTokenRecord(accessToken, { ...freshRecord, callbackAuthentication: refreshedCallbackAuth });
      }
    );
    console.log('PROACTIVE SYNC - pushed state for', deviceState.length, 'device(s) on account ending', accessToken.slice(-6));
  } catch (e) {
    console.error('PROACTIVE SYNC - account ending', idHint, 'failed:', e.message);
  }
}

async function proactiveSyncAll() {
  const records = await scanAllTokenRecords();
  console.log(`PROACTIVE SYNC - ${records.length} account(s) on file`);
  const CONCURRENCY = 8;
  for (let i = 0; i < records.length; i += CONCURRENCY) {
    const batch = records.slice(i, i + CONCURRENCY);
    await Promise.all(batch.map(syncOneAccount));
  }
}

const connector = new SchemaConnector()
  .clientId(ST_CLIENT_ID)
  .clientSecret(ST_CLIENT_SECRET)
  .discoveryHandler(async (accessToken, response) => {
    const record = await getTokenRecord(accessToken);
    if (!record) return;
    const { accessToken: freshAccess, idToken: freshId, record: freshRecord } = await ensureFreshTokens(record);
    const devices = await getDevices(freshAccess, freshId);
    console.log('DISCOVERY - raw devices:', JSON.stringify(devices));

    for (const device of devices) {
      const externalId = getDeviceExternalId(device);
      console.log('DISCOVERY - device_id:', device.device_id, 'asset_id:', device.asset_id, 'id:', device.id);
      if (!externalId) {
        console.log('DISCOVERY - skipping device with no usable ID:', JSON.stringify(device));
        continue;
      }
      response.addDevice(externalId, device.name || 'Tadiran AC', DEVICE_PROFILE_ID)
        .manufacturerName('Tadiran')
        .modelName(device.model_id || 'AC');
    }
  })
  .stateRefreshHandler(async (accessToken, response) => {
    const record = await getTokenRecord(accessToken);
    if (!record) return;
    const { accessToken: freshAccess, idToken: freshId } = await ensureFreshTokens(record);
    const devices = await getDevices(freshAccess, freshId);

    for (const device of devices) {
      const externalId = getDeviceExternalId(device);
      if (!externalId) continue;
      const dev = response.addDevice(externalId);

      let configs = device.configurations;
      if (!configs) {
        try {
          const shadow = await setDeviceFields(freshAccess, freshId, externalId, []);
          console.log('STATE REFRESH - shadow read via empty PUT:', JSON.stringify(shadow));
          if (Array.isArray(shadow) && shadow.length > 0) {
            configs = fieldsArrayToConfigurations(shadow);
          }
        } catch (e) {
          console.error('STATE REFRESH - shadow read failed:', e.message);
        }
      }
      console.log('STATE REFRESH - final configs used:', JSON.stringify(configs));
      for (const s of deviceToStates({ device_id: externalId, configurations: configs })) {
        dev.addState(s.component, s.capability, s.attribute, s.value, s.unit);
      }
    }
  })
  .commandHandler(async (accessToken, response, devices) => {
    const record = await getTokenRecord(accessToken);
    if (!record) return;
    const { accessToken: freshAccess, idToken: freshId } = await ensureFreshTokens(record);

    for (const cmd of devices) {
      console.log('COMMAND - raw cmd object:', JSON.stringify(cmd));
      const deviceId = cmd.externalDeviceId;
      const dev = response.addDevice(deviceId);
      const fields = [];

      for (const c of cmd.commands) {
        try {
          const args = c.arguments || [];
          switch (`${c.capability}:${c.command}`) {
            case 'st.switch:on':
              fields.push({ name: 'power', value: true }); break;
            case 'st.switch:off':
              fields.push({ name: 'power', value: false }); break;
            case 'vehiclepatch55148.acTemperature:setTempSet':
              fields.push({ name: 'temp_set', value: args[0] }); break;
            // SharpTools (and any client that reads the standard st.thermostatCoolingSetpoint
            // state we expose for compatibility) sends this standard command instead of our
            // custom acTemperature one. It was previously falling through to "Unhandled command"
            // and silently doing nothing. Tadiran only accepts whole-degree integers, while this
            // standard capability allows decimals (e.g. 24.5), so round it.
            case 'st.thermostatCoolingSetpoint:setCoolingSetpoint':
              fields.push({ name: 'temp_set', value: Math.round(Number(args[0])) }); break;
            case 'vehiclepatch55148.acMode:setMode':
              fields.push({ name: 'mode', value: args[0] }); break;
            case 'vehiclepatch55148.acFanSpeed:setFanSpeed':
              fields.push({ name: 'wind_speed', value: args[0] }); break;
            case 'vehiclepatch55148.acSwingUpDown:setSwitch':
              fields.push({ name: 'swing_ud', value: args[0] === 'on' }); break;
            case 'vehiclepatch55148.acSwingLeftRight:setSwitch':
              fields.push({ name: 'swing_lr', value: args[0] === 'on' }); break;
            case 'vehiclepatch55148.acLight:setSwitch':
              fields.push({ name: 'light', value: args[0] === 'on' }); break;
            case 'vehiclepatch55148.acTurbo:setSwitch':
              fields.push({ name: 'turbo', value: args[0] === 'on' }); break;
            case 'vehiclepatch55148.acMute:setSwitch':
              fields.push({ name: 'mute', value: args[0] === 'on' }); break;
            default:
              console.log('Unhandled command:', c.capability, c.command);
          }
        } catch (e) {
          console.error('Command build error:', e);
        }
      }

      let updatedDevice;
      try {
        if (fields.length > 0) {
          updatedDevice = await setDeviceFields(freshAccess, freshId, deviceId, fields);
          console.log('COMMAND - updatedDevice from setDeviceFields:', JSON.stringify(updatedDevice));
        }
      } catch (e) {
        console.error('Tadiran command failed:', e);
        dev.setError(e.message, DeviceErrorTypes.DEVICE_UNAVAILABLE);
        continue;
      }

      // Reply with updated states if we got a shadow back, else re-fetch device list as fallback
      if (Array.isArray(updatedDevice) && updatedDevice.length > 0) {
        const configs = fieldsArrayToConfigurations(updatedDevice, true);
        console.log('COMMAND - converted configurations:', JSON.stringify(configs));
        for (const s of deviceToStates({ device_id: deviceId, configurations: configs })) {
          dev.addState(s.component, s.capability, s.attribute, s.value, s.unit);
        }
      } else if (updatedDevice && updatedDevice.configurations) {
        for (const s of deviceToStates({ device_id: deviceId, configurations: updatedDevice.configurations })) {
          dev.addState(s.component, s.capability, s.attribute, s.value, s.unit);
        }
      } else {
        try {
          const devices = await getDevices(freshAccess, freshId);
          const found = devices.find(d => getDeviceExternalId(d) === deviceId);
          console.log('COMMAND - fallback found device:', JSON.stringify(found));
          if (found) {
            for (const s of deviceToStates(found)) {
              dev.addState(s.component, s.capability, s.attribute, s.value, s.unit);
            }
          } else {
            console.log('COMMAND - device not found in fallback list, using optimistic local state');
            const optimistic = { configurations: {} };
            for (const f of fields) optimistic.configurations[f.name] = f.value;
            for (const s of deviceToStates({ device_id: deviceId, configurations: optimistic.configurations })) {
              dev.addState(s.component, s.capability, s.attribute, s.value, s.unit);
            }
          }
        } catch (e) {
          console.error('Fallback fetch error:', e);
          dev.setError('State unavailable after command', DeviceErrorTypes.DEVICE_UNAVAILABLE);
        }
      }
    }
  })
  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    let record = await getTokenRecord(accessToken);
    let keyToSaveUnder = accessToken;
    if (!record) {
      // The access token SmartThings used here may have already rotated out of our
      // table (Cognito tokens expire hourly, and our refresh flow deletes the old
      // key). Fall back to matching by the stable Cognito "sub" claim instead.
      const sub = decodeJwtSub(accessToken);
      if (sub) {
        const allRecords = await scanAllTokenRecords();
        const match = allRecords.find(r => r.cognitoAccessToken && decodeJwtSub(r.cognitoAccessToken) === sub);
        if (match) {
          record = match;
          keyToSaveUnder = match.accessToken;
        }
      }
    }
    if (!record) {
      console.error('PROACTIVE SYNC SETUP - callbackAccessHandler: no matching account found for token ending', accessToken.slice(-6));
      return;
    }
    await saveTokenRecord(keyToSaveUnder, {
      ...record,
      callbackAuthentication,
      callbackUrls
    });
    console.log('PROACTIVE SYNC SETUP - saved callback credentials for account ending', keyToSaveUnder.slice(-6));
  })
  .integrationDeletedHandler(async (accessToken) => {
    await deleteTokenRecord(accessToken).catch(() => {});
  });

// =====================================================================
// HTTP handlers for OAuth-style account linking (/authorize, /token)
// =====================================================================

function htmlResponse(body, statusCode = 200) {
  return { statusCode, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body };
}
function redirectResponse(location) {
  return { statusCode: 302, headers: { Location: location }, body: '' };
}
function jsonResponse(obj, statusCode = 200) {
  return { statusCode, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}

function phoneForm(error) {
  return `<!DOCTYPE html><html><body style="font-family:sans-serif;max-width:400px;margin:40px auto">
    <h2>Connect your Tadiran account</h2>
    ${error ? `<p style="color:red">${error}</p>` : ''}
    <form method="POST">
      <input type="hidden" name="step" value="phone">
      <label>Phone number (e.g. +972501234567)</label><br>
      <input type="text" name="phone" required style="width:100%;padding:8px;margin:8px 0"><br>
      <button type="submit" style="padding:10px 20px">Send code</button>
    </form>
  </body></html>`;
}

function escapeHtml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function otpForm(phone, session, error) {
  return `<!DOCTYPE html><html><body style="font-family:sans-serif;max-width:400px;margin:40px auto">
    <h2>Enter the code sent to ${escapeHtml(phone)}</h2>
    ${error ? `<p style="color:red">${error}</p>` : ''}
    <form method="POST">
      <input type="hidden" name="step" value="otp">
      <input type="hidden" name="phone" value="${escapeHtml(phone)}">
      <input type="hidden" name="session" value="${escapeHtml(session)}">
      <label>OTP code</label><br>
      <input type="text" name="otp" required style="width:100%;padding:8px;margin:8px 0"><br>
      <button type="submit" style="padding:10px 20px">Verify</button>
    </form>
  </body></html>`;
}

async function handleAuthorize(event) {
  const method = event.httpMethod || (event.requestContext && event.requestContext.http && event.requestContext.http.method);
  const qs = event.queryStringParameters || {};
  const body = event.body ? Object.fromEntries(new URLSearchParams(event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body)) : {};

  if (method === 'GET') {
    return htmlResponse(phoneForm());
  }

  if (method === 'POST') {
    if (body.step === 'phone') {
      try {
        const normalizedPhone = normalizeIsraeliPhone(body.phone);
        const resp = await cognitoInitiateAuth(normalizedPhone);
        return htmlResponse(otpForm(normalizedPhone, resp.Session));
      } catch (e) {
        console.error(e);
        return htmlResponse(phoneForm('Could not send code. Check the phone number format.'));
      }
    }

    if (body.step === 'otp') {
      try {
        const auth = await cognitoRespondToChallenge(body.phone, body.session, body.otp);
        const now = Date.now();
        await saveTokenRecord(auth.AccessToken, {
          cognitoAccessToken: auth.AccessToken,
          cognitoIdToken: auth.IdToken,
          cognitoRefreshToken: auth.RefreshToken,
          cognitoExpiresAt: now + (auth.ExpiresIn * 1000),
          phone: body.phone
        });

        // Redirect back to SmartThings with our "code" (we just reuse the Cognito access token as the code)
        const redirectUri = qs.redirect_uri || '';
        const state = qs.state || '';
        const url = `${redirectUri}?code=${encodeURIComponent(auth.AccessToken)}&state=${encodeURIComponent(state)}`;
        return redirectResponse(url);
      } catch (e) {
        console.error(e);
        return htmlResponse(otpForm(body.phone, body.session, 'Invalid code, try again.'));
      }
    }
  }

  return htmlResponse('Bad request', 400);
}

async function handleToken(event) {
  const body = event.body ? Object.fromEntries(new URLSearchParams(event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body)) : {};

  if (body.grant_type === 'authorization_code') {
    // Our "code" IS the Cognito access token already stored in DynamoDB
    const record = await getTokenRecord(body.code);
    if (!record) return jsonResponse({ error: 'invalid_grant' }, 400);
    return jsonResponse({
      access_token: record.cognitoAccessToken,
      refresh_token: record.cognitoRefreshToken,
      token_type: 'Bearer',
      expires_in: Math.floor((record.cognitoExpiresAt - Date.now()) / 1000)
    });
  }

  if (body.grant_type === 'refresh_token') {
    // Find the record - SmartThings sends back the refresh_token we gave it.
    // We stored records keyed by access token, refresh token is same across refreshes typically,
    // so look for it by scanning is avoided: instead, SmartThings should also echo back a way to find it.
    // Simplify: treat the incoming refresh_token itself as lookup by calling Cognito directly.
    try {
      const auth = await cognitoRefresh(body.refresh_token);
      const now = Date.now();
      await saveTokenRecord(auth.AccessToken, {
        cognitoAccessToken: auth.AccessToken,
        cognitoIdToken: auth.IdToken,
        cognitoRefreshToken: body.refresh_token, // Cognito refresh tokens are long-lived/reusable
        cognitoExpiresAt: now + (auth.ExpiresIn * 1000)
      });
      return jsonResponse({
        access_token: auth.AccessToken,
        refresh_token: body.refresh_token,
        token_type: 'Bearer',
        expires_in: auth.ExpiresIn
      });
    } catch (e) {
      console.error(e);
      return jsonResponse({ error: 'invalid_grant' }, 400);
    }
  }

  return jsonResponse({ error: 'unsupported_grant_type' }, 400);
}

// =====================================================================
// Main Lambda entry point
// =====================================================================

exports.handler = async (event, context) => {
  console.log('Event:', JSON.stringify(event));

  // EventBridge scheduled rule (no requestContext, has a 'source' of 'aws.events')
  if (event.source === 'aws.events') {
    await proactiveSyncAll();
    return { statusCode: 200 };
  }

  // HTTP API Gateway events have requestContext with http/routeKey.
  // Direct SmartThings invocations do NOT have requestContext (per LG project lesson).
  if (event.requestContext) {
    const path = event.rawPath || event.path || '';
    if (path.includes('/authorize')) {
      return handleAuthorize(event);
    }
    if (path.includes('/token')) {
      return handleToken(event);
    }
    return { statusCode: 404, body: 'Not found' };
  }

  // Otherwise, this is a direct SmartThings Schema Connector invocation
  return new Promise((resolve, reject) => {
    connector.handleLambdaCallback(event, context, (err, result) => {
      if (err) {
        console.error('handleLambdaCallback error:', err);
        reject(err);
      } else {
        resolve(result);
      }
    });
  });
};
