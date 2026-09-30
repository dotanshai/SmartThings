'use strict';

// Tornado AC SmartThings Schema Connector (AUX cloud)
// Architecture cloned from TadiranAcSchema; reuses the vehiclepatch55148.ac* capabilities
// and the "Tadiran AC v8" device profile.
// AUX API client ported from romfreiman/tornado-aircon-custom-component (MIT).

const { SchemaConnector, DeviceErrorTypes, StateUpdateRequest } = require('st-schema');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand, ScanCommand } = require('@aws-sdk/lib-dynamodb');
const https = require('https');
const crypto = require('crypto');

// ---- Config (env vars) ----
const TABLE_NAME = process.env.TABLE_NAME || 'TornadoAcTokens';
const DYNAMO_REGION = process.env.DYNAMO_REGION || 'us-east-1';
const ST_CLIENT_ID = process.env.ST_CLIENT_ID;
const ST_CLIENT_SECRET = process.env.ST_CLIENT_SECRET;
const DEVICE_PROFILE_ID = process.env.DEVICE_PROFILE_ID;
const OAUTH_CLIENT_ID = process.env.OAUTH_CLIENT_ID;         // the OAuth client id you enter in schema:create
const OAUTH_CLIENT_SECRET = process.env.OAUTH_CLIENT_SECRET; // the OAuth client secret you enter in schema:create
const ENC_KEY = process.env.ENC_KEY;                         // 64 hex chars (32 bytes) - SAME value in both regions
const TOKEN_TTL_SECONDS = 365 * 24 * 3600;

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: DYNAMO_REGION }));

// =====================================================================
// AUX cloud constants (from the Tornado WIFI 3 / AUX app)
// =====================================================================
const TIMESTAMP_KEY = 'kdixkdqp54545^#*';
const PASSWORD_KEY = '4969fj#k23#';
const BODY_KEY = 'xgx3d*fe3478$ukx';
const AES_IV = Buffer.from([-22, -86, -86, 58, -69, 88, 98, -94, 25, 24, -75, 119, 29, 22, 21, -86].map(b => (b + 256) % 256));
const LICENSE = 'PAFbJJ3WbvDxH5vvWezXN5BujETtH/iuTtIIW5CE/SeHN7oNKqnEajgljTcL0fBQQWM0XAAAAAAnBh' +
  'JyhMi7zIQMsUcwR/PEwGA3uB5HLOnr+xRrci+FwHMkUtK7v4yo0ZHa+jPvb6djelPP893k7SagmffZ' +
  'mOkLSOsbNs8CAqsu8HuIDs2mDQAAAAA=';
const LICENSE_ID = '3c015b249dd66ef0f11f9bef59ecd737';
const COMPANY_ID = '48eb1b36cf0202ab2ef07b880ecda60d';
const SERVERS = {
  usa: 'https://app-service-usa-fd7cc04c.smarthomecs.com',
  eu: 'https://app-service-deu-f0e9ebbb.smarthomecs.de'
};
const SESSION_EXPIRED = -30129;

// AUX value <-> SmartThings value maps
const MODE_TO_ST = { 0: 'COOL', 1: 'HEAT', 2: 'DRY', 3: 'FAN', 4: 'AUTO' };
const ST_TO_MODE = { COOL: 0, HEAT: 1, DRY: 2, FAN: 3, AUTO: 4 };
// ac_mark: 0 auto, 1 low, 2 medium, 3 high, 4 turbo, 5 silent
// turbo -> acTurbo toggle, silent -> acMute toggle (capabilities reused from Tadiran)
const FAN_TO_ST = { 0: 'AUTO', 1: 'LOW', 2: 'MEDIUM', 3: 'HIGH', 4: 'HIGH', 5: 'LOW' };
const ST_TO_FAN = { AUTO: 0, LOW: 1, MEDIUM: 2, MEDIUM_HIGH: 3, HIGH: 3 };
const FAN_TURBO = 4;
const FAN_SILENT = 5;

// =====================================================================
// Password encryption at rest (AES-256-GCM)
// =====================================================================
function encKey() {
  if (!ENC_KEY || ENC_KEY.length !== 64) throw new Error('ENC_KEY env var missing or not 64 hex chars');
  return Buffer.from(ENC_KEY, 'hex');
}
function encrypt(text) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', encKey(), iv);
  const enc = Buffer.concat([c.update(text, 'utf8'), c.final()]);
  return [iv, c.getAuthTag(), enc].map(b => b.toString('base64')).join('.');
}
function decrypt(s) {
  const [iv, tag, enc] = s.split('.').map(x => Buffer.from(x, 'base64'));
  const d = crypto.createDecipheriv('aes-256-gcm', encKey(), iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(enc), d.final()]).toString('utf8');
}

// =====================================================================
// AUX cloud client
// =====================================================================
function httpPost(urlStr, body, headers) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const buf = Buffer.isBuffer(body) ? body : Buffer.from(body || '', 'utf8');
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname + u.search,
      method: 'POST',
      headers: { ...headers, 'Content-Length': buf.length },
      timeout: 15000
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8'); // join chunks before decoding (UTF-8 split lesson)
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(raw);
        else reject(new Error(`AUX ${u.pathname} HTTP ${res.statusCode}: ${raw.slice(0, 300)}`));
      });
    });
    req.on('timeout', () => req.destroy(new Error('AUX request timeout')));
    req.on('error', reject);
    req.write(buf);
    req.end();
  });
}

class AuxClient {
  constructor(server, session = '', userid = '') {
    this.server = server;
    this.url = SERVERS[server];
    this.session = session;
    this.userid = userid;
  }

  headers(extra = {}) {
    return {
      'Content-Type': 'application/x-java-serialized-object',
      licenseId: LICENSE_ID,
      lid: LICENSE_ID,
      language: 'en',
      appVersion: '2.2.10.456537160',
      'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 12; SM-G991B Build/SP1A.210812.016)',
      system: 'android',
      appPlatform: 'android',
      loginsession: this.session || '',
      userid: this.userid || '',
      ...extra
    };
  }

  async login(email, password) {
    const ts = (Date.now() / 1000).toString();
    const body = JSON.stringify({
      email,
      password: crypto.createHash('sha1').update(password + PASSWORD_KEY).digest('hex'),
      companyid: COMPANY_ID,
      lid: LICENSE_ID
    });
    const token = crypto.createHash('md5').update(body + BODY_KEY).digest('hex');
    const key = crypto.createHash('md5').update(ts + TIMESTAMP_KEY).digest();
    const raw = Buffer.from(body, 'utf8');
    const padded = Buffer.concat([raw, Buffer.alloc(16 - (raw.length % 16))]); // zero padding (always adds 1-16 bytes)
    const cipher = crypto.createCipheriv('aes-128-cbc', key, AES_IV);
    cipher.setAutoPadding(false);
    const enc = Buffer.concat([cipher.update(padded), cipher.final()]);

    const j = JSON.parse(await httpPost(`${this.url}/account/login`, enc, this.headers({ timestamp: ts, token })));
    if (j.status !== 0) throw new Error(`AUX login failed: ${j.msg || JSON.stringify(j)}`);
    this.session = j.loginsession;
    this.userid = j.userid;
    return j;
  }

  async post(path, body = '', extra = {}) {
    const j = JSON.parse(await httpPost(this.url + path, body, this.headers(extra)));
    if (j.status === SESSION_EXPIRED) throw new Error('AUX session expired');
    return j;
  }

  async listDevices() {
    const fams = await this.post('/appsync/group/member/getfamilylist');
    if (fams.status !== 0) throw new Error(`AUX family list failed: ${JSON.stringify(fams).slice(0, 300)}`);
    const out = [];
    const seen = new Set();
    const add = (d) => { if (d && d.endpointId && !seen.has(d.endpointId)) { seen.add(d.endpointId); out.push(d); } };

    for (const f of (fams.data && fams.data.familyList) || []) {
      const own = await this.post('/appsync/group/dev/query?action=select', '{"pids":[]}', { familyid: f.familyid });
      if (own.status === 0) ((own.data && own.data.endpoints) || []).forEach(add);
      const shared = await this.post('/appsync/group/sharedev/querylist?querytype=shared', '{"endpointId":""}', { familyid: f.familyid });
      if (shared.status === 0) ((shared.data && shared.data.shareFromOther) || []).forEach(s => add(s.devinfo));
    }
    return out;
  }

  async control(dev, act, params, vals, ambient = false) {
    const c = JSON.parse(Buffer.from(dev.cookie, 'base64').toString('utf8'));
    const mappedCookie = Buffer.from(JSON.stringify({
      device: {
        id: c.terminalid, key: c.aeskey, devSession: dev.devSession, aeskey: c.aeskey,
        did: dev.endpointId, pid: dev.productId, mac: dev.mac
      }
    })).toString('base64');
    const payload = { act, params, vals };
    if (ambient) {
      payload.did = dev.endpointId;
      payload.vals = [[{ val: 0, idx: 1 }]];
    }
    const data = {
      directive: {
        header: {
          namespace: 'DNA.KeyValueControl', name: 'KeyValueControl', interfaceVersion: '2',
          senderId: 'sdk', messageId: `${dev.endpointId}-${Math.floor(Date.now() / 1000)}`
        },
        endpoint: {
          devicePairedInfo: {
            did: dev.endpointId, pid: dev.productId, mac: dev.mac,
            devicetypeflag: dev.devicetypeFlag, cookie: mappedCookie
          },
          endpointId: dev.endpointId, cookie: {}, devSession: dev.devSession
        },
        payload
      }
    };
    const j = await this.post(`/device/control/v2/sdkcontrol?license=${encodeURIComponent(LICENSE)}`, JSON.stringify(data));
    const d = j.event && j.event.payload && j.event.payload.data;
    if (!d) throw new Error(`AUX ${act} failed: ${JSON.stringify(j).slice(0, 300)}`);
    const r = JSON.parse(d);
    const out = {};
    r.params.forEach((p, i) => { out[p] = r.vals[i][0].val; });
    return out;
  }

  getParams(dev) { return this.control(dev, 'get', [], []); }

  async getAmbient(dev) {
    const p = await this.control(dev, 'get', ['mode'], [], true);
    return p.envtemp;
  }

  setParams(dev, values) {
    return this.control(dev, 'set', Object.keys(values), Object.values(values).map(v => [{ val: v, idx: 1 }]));
  }
}

// =====================================================================
// DynamoDB record helpers - keyed by our own opaque accessToken (stable, never moves)
// =====================================================================
async function saveRecord(accessToken, record) {
  await ddb.send(new PutCommand({ TableName: TABLE_NAME, Item: { ...record, accessToken, updatedAt: Date.now() } }));
}
async function getRecord(accessToken) {
  if (!accessToken) return undefined;
  const resp = await ddb.send(new GetCommand({ TableName: TABLE_NAME, Key: { accessToken } }));
  return resp.Item;
}
async function deleteRecord(accessToken) {
  await ddb.send(new DeleteCommand({ TableName: TABLE_NAME, Key: { accessToken } }));
}

// Runs fn(aux) with the cached AUX session; on any failure re-logs in once and retries.
async function withAux(accessToken, record, fn) {
  const aux = new AuxClient(record.server, record.auxSession, record.auxUserid);
  const relogin = async () => {
    await aux.login(record.email, decrypt(record.passwordEnc));
    record.auxSession = aux.session;
    record.auxUserid = aux.userid;
    await saveRecord(accessToken, record);
  };
  if (!aux.session) await relogin();
  try {
    return await fn(aux);
  } catch (e) {
    console.warn('AUX call failed, re-login and retry:', e.message);
    await relogin();
    return fn(aux);
  }
}

// =====================================================================
// AUX params -> SmartThings states
// =====================================================================
function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

function paramsToStates(p, extId, online = true) {
  const on = p.pwr ? 'on' : 'off';
  const setC = (typeof p.temp === 'number') ? p.temp / 10 : 24;
  const setInt = clamp(Math.round(setC), 16, 30);
  const mode = MODE_TO_ST[p.ac_mode] || 'COOL';
  const states = [
    { capability: 'st.switch', attribute: 'switch', value: on },
    { capability: 'st.thermostatCoolingSetpoint', attribute: 'coolingSetpoint', value: setC, unit: 'C' },
    { capability: 'vehiclepatch55148.acTemperature', attribute: 'tempSet', value: setInt },
    { capability: 'vehiclepatch55148.acMode', attribute: 'mode', value: mode },
    { capability: 'vehiclepatch55148.acFanSpeed', attribute: 'fanSpeed', value: FAN_TO_ST[p.ac_mark] || 'AUTO' },
    { capability: 'vehiclepatch55148.acSwingUpDown', attribute: 'switch', value: p.ac_vdir ? 'on' : 'off' },
    { capability: 'vehiclepatch55148.acSwingLeftRight', attribute: 'switch', value: p.ac_hdir ? 'on' : 'off' },
    { capability: 'vehiclepatch55148.acLight', attribute: 'switch', value: p.scrdisp ? 'on' : 'off' },
    { capability: 'vehiclepatch55148.acTurbo', attribute: 'switch', value: p.ac_mark === FAN_TURBO ? 'on' : 'off' },
    { capability: 'vehiclepatch55148.acMute', attribute: 'switch', value: p.ac_mark === FAN_SILENT ? 'on' : 'off' },
    { capability: 'vehiclepatch55148.acStatus', attribute: 'statusSwitch', value: on },
    { capability: 'vehiclepatch55148.acStatus', attribute: 'statusMode', value: mode },
    { capability: 'vehiclepatch55148.acStatus', attribute: 'statusTempSet', value: setInt },
    { capability: 'vehiclepatch55148.acStatus2', attribute: 'statusMode', value: mode },
    { capability: 'vehiclepatch55148.acStatus2', attribute: 'statusTempSet', value: setInt },
    { capability: 'vehiclepatch55148.acDeviceId', attribute: 'shortId', value: String(extId).slice(-8) },
    { capability: 'st.healthCheck', attribute: 'checkInterval', value: 3600 },
    { capability: 'st.healthCheck', attribute: 'healthStatus', value: online ? 'online' : 'offline' }
  ];
  if (typeof p.envtemp === 'number') {
    states.push({ capability: 'st.temperatureMeasurement', attribute: 'temperature', value: p.envtemp / 10, unit: 'C' });
    states.push({ capability: 'vehiclepatch55148.acTemperature', attribute: 'tempCurrent', value: Math.round(p.envtemp / 10) });
  }
  return states;
}

function addStates(dev, states) {
  for (const s of states) dev.addState('main', s.capability, s.attribute, s.value, s.unit);
}

// SmartThings command -> AUX params (merged into one set call)
function commandsToValues(commands) {
  const v = {};
  for (const c of commands) {
    const a = (c.arguments || [])[0];
    switch (`${c.capability}:${c.command}`) {
      case 'st.switch:on': v.pwr = 1; break;
      case 'st.switch:off': v.pwr = 0; break;
      case 'vehiclepatch55148.acTemperature:setTempSet':
      case 'st.thermostatCoolingSetpoint:setCoolingSetpoint':
        v.temp = Math.round(clamp(Number(a), 16, 32) * 10); break;
      case 'vehiclepatch55148.acMode:setMode':
        if (a in ST_TO_MODE) v.ac_mode = ST_TO_MODE[a]; break;
      case 'vehiclepatch55148.acFanSpeed:setFanSpeed':
        if (a in ST_TO_FAN) v.ac_mark = ST_TO_FAN[a]; break;
      case 'vehiclepatch55148.acSwingUpDown:setSwitch': v.ac_vdir = a === 'on' ? 1 : 0; break;
      case 'vehiclepatch55148.acSwingLeftRight:setSwitch': v.ac_hdir = a === 'on' ? 1 : 0; break;
      case 'vehiclepatch55148.acLight:setSwitch': v.scrdisp = a === 'on' ? 1 : 0; break;
      case 'vehiclepatch55148.acTurbo:setSwitch': v.ac_mark = a === 'on' ? FAN_TURBO : 0; break;
      case 'vehiclepatch55148.acMute:setSwitch': v.ac_mark = a === 'on' ? FAN_SILENT : 0; break;
      default: console.log('Unhandled command:', c.capability, c.command);
    }
  }
  return v;
}

// =====================================================================
// st-schema connector
// =====================================================================
const connector = new SchemaConnector()
  .clientId(ST_CLIENT_ID)
  .clientSecret(ST_CLIENT_SECRET)
  .discoveryHandler(async (accessToken, response) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    const devices = await withAux(accessToken, record, aux => aux.listDevices());
    console.log('DISCOVERY - devices:', devices.map(d => `${d.endpointId} ${d.friendlyName}`).join(', '));
    for (const d of devices) {
      response.addDevice(d.endpointId, d.friendlyName || 'Tornado AC', DEVICE_PROFILE_ID)
        .manufacturerName('Tornado')
        .modelName(`AUX ${String(d.productId || '').slice(-8)}`);
    }
  })
  .stateRefreshHandler(async (accessToken, response) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    await withAux(accessToken, record, async (aux) => {
      const devices = await aux.listDevices();
      for (const d of devices) {
        const dev = response.addDevice(d.endpointId);
        try {
          const p = await aux.getParams(d);
          try { p.envtemp = await aux.getAmbient(d); } catch (e) { console.warn('ambient failed:', e.message); }
          console.log('STATE REFRESH -', d.endpointId, JSON.stringify(p));
          addStates(dev, paramsToStates(p, d.endpointId));
        } catch (e) {
          console.error('STATE REFRESH failed for', d.endpointId, e.message);
          dev.addState('main', 'st.healthCheck', 'healthStatus', 'offline');
        }
      }
    });
  })
  .commandHandler(async (accessToken, response, devices) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    await withAux(accessToken, record, async (aux) => {
      const all = await aux.listDevices();
      for (const cmd of devices) {
        console.log('COMMAND -', JSON.stringify(cmd));
        const dev = response.addDevice(cmd.externalDeviceId);
        const d = all.find(x => x.endpointId === cmd.externalDeviceId);
        if (!d) {
          dev.setError('Device not found in Tornado account', DeviceErrorTypes.DEVICE_DELETED);
          continue;
        }
        try {
          const values = commandsToValues(cmd.commands || []);
          const p = Object.keys(values).length ? await aux.setParams(d, values) : await aux.getParams(d);
          try { p.envtemp = await aux.getAmbient(d); } catch (e) { console.warn('ambient failed:', e.message); }
          console.log('COMMAND - sent', JSON.stringify(values), 'state now', JSON.stringify(p));
          addStates(dev, paramsToStates(p, d.endpointId));
        } catch (e) {
          console.error('COMMAND failed:', e.message);
          dev.setError(e.message, DeviceErrorTypes.DEVICE_UNAVAILABLE);
        }
      }
    });
  })
  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    await saveRecord(accessToken, { ...record, callbackAuthentication, callbackUrls });
  })
  .integrationDeletedHandler(async (accessToken) => {
    await deleteRecord(accessToken).catch(() => {});
  });

// =====================================================================
// Proactive sync (EventBridge every 5 min) - pushes fresh state to SmartThings
// so changes made in the Tornado app / remote show up without a manual refresh
// =====================================================================
async function scanAllRecords() {
  const items = [];
  let ExclusiveStartKey;
  do {
    const r = await ddb.send(new ScanCommand({ TableName: TABLE_NAME, ExclusiveStartKey }));
    items.push(...(r.Items || []));
    ExclusiveStartKey = r.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return items;
}

async function syncOne(rec) {
  if (!rec.callbackAuthentication || !rec.callbackUrls || !rec.passwordEnc) return 'skipped (no callback)';
  const deviceState = await withAux(rec.accessToken, rec, async (aux) => {
    const out = [];
    for (const d of await aux.listDevices()) {
      try {
        const p = await aux.getParams(d);
        try { p.envtemp = await aux.getAmbient(d); } catch (e) { /* ambient is best-effort */ }
        out.push({
          externalDeviceId: d.endpointId,
          states: paramsToStates(p, d.endpointId).map(s => ({
            component: 'main', capability: s.capability, attribute: s.attribute, value: s.value,
            ...(s.unit ? { unit: s.unit } : {})
          }))
        });
      } catch (e) {
        out.push({
          externalDeviceId: d.endpointId,
          states: [{ component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: 'offline' }]
        });
      }
    }
    return out;
  });
  if (!deviceState.length) return 'no devices';

  let refreshed = null;
  await new StateUpdateRequest(ST_CLIENT_ID, ST_CLIENT_SECRET)
    .updateState(rec.callbackUrls, rec.callbackAuthentication, deviceState, (auth) => { refreshed = auth; });
  if (refreshed) {
    rec.callbackAuthentication = refreshed;
    await saveRecord(rec.accessToken, rec);
  }
  return `pushed ${deviceState.length} device(s)${refreshed ? ' (callback token refreshed)' : ''}`;
}

async function runSync() {
  const records = await scanAllRecords();
  const results = await Promise.allSettled(records.map(syncOne));
  results.forEach((r, i) => {
    const id = String(records[i].accessToken).slice(0, 8);
    if (r.status === 'fulfilled') console.log(`SYNC ${id}: ${r.value}`);
    else console.error(`SYNC ${id}: FAILED ${r.reason && r.reason.message}`);
  });
  return { synced: records.length };
}

// =====================================================================
// OAuth account linking (/authorize, /token) via API Gateway
// =====================================================================
const esc = (s) => String(s || '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const randHex = (n) => crypto.randomBytes(n).toString('hex');
const safeEq = (a, b) => {
  const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || ''));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

function htmlResponse(body, statusCode = 200) {
  return { statusCode, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body };
}
function redirectResponse(location) {
  return { statusCode: 302, headers: { Location: location }, body: '' };
}
function jsonResponse(obj, statusCode = 200) {
  return { statusCode, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, body: JSON.stringify(obj) };
}
function parseBody(event) {
  if (!event.body) return {};
  const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body;
  return Object.fromEntries(new URLSearchParams(raw));
}

function loginForm(error, email) {
  return `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
  <body style="font-family:sans-serif;max-width:400px;margin:40px auto;padding:0 16px">
    <h2>Connect your Tornado account</h2>
    <p>Use the email and password of your <b>Tornado WIFI 3</b> app.</p>
    ${error ? `<p style="color:red">${esc(error)}</p>` : ''}
    <form method="POST">
      <label>Email</label><br>
      <input type="email" name="email" value="${esc(email)}" required style="width:100%;padding:8px;margin:8px 0;box-sizing:border-box"><br>
      <label>Password</label><br>
      <input type="password" name="password" required style="width:100%;padding:8px;margin:8px 0;box-sizing:border-box"><br>
      <button type="submit" style="padding:10px 20px">Connect</button>
    </form>
  </body></html>`;
}

async function handleAuthorize(event) {
  const method = event.httpMethod || (event.requestContext && event.requestContext.http && event.requestContext.http.method);
  const qs = event.queryStringParameters || {};

  if (method === 'GET') return htmlResponse(loginForm());
  if (method !== 'POST') return htmlResponse('Bad request', 400);

  const body = parseBody(event);
  const email = (body.email || '').trim();
  const password = body.password || '';

  // Try USA first (Israeli accounts live there), then EU
  let aux = null;
  for (const server of ['usa', 'eu']) {
    try {
      const a = new AuxClient(server);
      await a.login(email, password);
      aux = a;
      break;
    } catch (e) {
      console.log(`AUTHORIZE - login on ${server} failed:`, e.message);
    }
  }
  if (!aux) return htmlResponse(loginForm('Login failed. Check your Tornado email and password.', email));

  const accessToken = randHex(32);
  const codeSecret = randHex(16);
  await saveRecord(accessToken, {
    email,
    passwordEnc: encrypt(password),
    server: aux.server,
    auxSession: aux.session,
    auxUserid: aux.userid,
    codeSecret,
    refreshSecret: randHex(32),
    createdAt: Date.now()
  });

  const redirectUri = qs.redirect_uri || '';
  const state = qs.state || '';
  const code = `${accessToken}.${codeSecret}`;
  return redirectResponse(`${redirectUri}?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`);
}

function clientCredentials(event, body) {
  const h = event.headers || {};
  const auth = h.authorization || h.Authorization || '';
  if (auth.startsWith('Basic ')) {
    const [id, ...rest] = Buffer.from(auth.slice(6), 'base64').toString().split(':');
    return { id: decodeURIComponent(id), secret: decodeURIComponent(rest.join(':')) };
  }
  return { id: body.client_id, secret: body.client_secret };
}

async function handleToken(event) {
  const body = parseBody(event);

  // Validate the OAuth client (the Tadiran TODO, fixed here from day one)
  if (OAUTH_CLIENT_ID && OAUTH_CLIENT_SECRET) {
    const c = clientCredentials(event, body);
    if (!safeEq(c.id, OAUTH_CLIENT_ID) || !safeEq(c.secret, OAUTH_CLIENT_SECRET)) {
      console.warn('TOKEN - invalid client credentials');
      return jsonResponse({ error: 'invalid_client' }, 401);
    }
  } else {
    console.warn('TOKEN - OAUTH_CLIENT_ID/SECRET not set, skipping client validation');
  }

  const splitToken = (t) => {
    const i = String(t || '').indexOf('.');
    return i < 0 ? [null, null] : [t.slice(0, i), t.slice(i + 1)];
  };

  if (body.grant_type === 'authorization_code') {
    const [accessToken, secret] = splitToken(body.code);
    const record = await getRecord(accessToken);
    if (!record || !record.codeSecret || !safeEq(secret, record.codeSecret)) {
      return jsonResponse({ error: 'invalid_grant' }, 400);
    }
    delete record.codeSecret; // one-time code
    await saveRecord(accessToken, record);
    return jsonResponse({
      access_token: accessToken,
      refresh_token: `${accessToken}.${record.refreshSecret}`,
      token_type: 'Bearer',
      expires_in: TOKEN_TTL_SECONDS
    });
  }

  if (body.grant_type === 'refresh_token') {
    const [accessToken, secret] = splitToken(body.refresh_token);
    const record = await getRecord(accessToken);
    if (!record || !safeEq(secret, record.refreshSecret)) {
      return jsonResponse({ error: 'invalid_grant' }, 400);
    }
    return jsonResponse({
      access_token: accessToken,
      refresh_token: body.refresh_token,
      token_type: 'Bearer',
      expires_in: TOKEN_TTL_SECONDS
    });
  }

  return jsonResponse({ error: 'unsupported_grant_type' }, 400);
}

// =====================================================================
// Main entry point
// =====================================================================
exports.handler = async (event, context) => {
  // EventBridge scheduled sync
  if (event.source === 'aws.events' || event.sync === true) return runSync();

  // API Gateway events have requestContext; direct SmartThings invocations don't.
  if (event.requestContext) {
    const path = event.rawPath || event.path || '';
    console.log('HTTP', path); // don't log the full event: it contains the password on /authorize POST
    if (path.includes('/authorize')) return handleAuthorize(event);
    if (path.includes('/token')) return handleToken(event);
    return { statusCode: 404, body: 'Not found' };
  }

  console.log('Event:', JSON.stringify(event));
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

// exported for local tests
exports._internal = { AuxClient, paramsToStates, commandsToValues, encrypt, decrypt };
