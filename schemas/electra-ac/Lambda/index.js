'use strict';

// Electra A/C SmartThings Schema Connector (Electra Smart cloud, app.ecpiot.co.il)
// Architecture cloned from TornadoAcSchema; reuses the vehiclepatch55148.ac* capabilities
// and the "Tadiran AC v8" device profile.
// Electra API ported from pyElectra (jafar-atili/pyElectra, used by Home Assistant).

const { SchemaConnector, DeviceErrorTypes, StateUpdateRequest, DiscoveryRequest, DiscoveryDevice } = require('st-schema');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand, ScanCommand, UpdateCommand } = require('@aws-sdk/lib-dynamodb');
const https = require('https');
const crypto = require('crypto');

// ---- Config (env vars) ----
const TABLE_NAME = process.env.TABLE_NAME || 'ElectraAcTokens';
const DYNAMO_REGION = process.env.DYNAMO_REGION || 'us-east-1';
const ST_CLIENT_ID = process.env.ST_CLIENT_ID;
const ST_CLIENT_SECRET = process.env.ST_CLIENT_SECRET;
// Device profiles (chosen per device at discovery). Devices linked earlier stay on Tadiran v8 ("v8").
const PROFILE_STD = 'f9ca0e97-5909-4d51-8762-68e54046a5d0'; // "Electra AC"    - no Light/Mute
const PROFILE_RA  = '4ffc1df5-a8f4-4372-85f4-8c4df3238527'; // "Electra AC RA" - + Return Air row
const profileIdFor = (kind) => (kind === 'ra' ? PROFILE_RA : PROFILE_STD);
const OAUTH_CLIENT_ID = process.env.OAUTH_CLIENT_ID;
const OAUTH_CLIENT_SECRET = process.env.OAUTH_CLIENT_SECRET;
const ENC_KEY = process.env.ENC_KEY;                         // 64 hex chars - SAME value in both regions
const TOKEN_TTL_SECONDS = 365 * 24 * 3600;

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: DYNAMO_REGION }));

// =====================================================================
// Electra constants
// =====================================================================
const ELECTRA_URL = 'https://app.ecpiot.co.il/mobile/mobilecommand';
const SID_TTL_MS = 13 * 60 * 1000;          // server sid lives 15 min; refresh a bit early
const SID_MIN_GAP_MS = 5 * 60 * 1000;       // requesting a sid more often than 5 min -> "intruder lockout"
const MIN_TEMP = 16, MAX_TEMP = 30;

const ELECTRA_MODES = ['COOL', 'HEAT', 'AUTO', 'DRY', 'FAN'];
const FAN_TO_ST = { LOW: 'LOW', MED: 'MEDIUM', HIGH: 'HIGH', AUTO: 'AUTO' };
const ST_TO_FAN = { AUTO: 'AUTO', LOW: 'LOW', MEDIUM: 'MED', MEDIUM_HIGH: 'HIGH', HIGH: 'HIGH' };

// =====================================================================
// Token encryption at rest (AES-256-GCM)
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
// Electra client
// =====================================================================
function httpPostJson(urlStr, obj, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const buf = Buffer.from(JSON.stringify(obj), 'utf8');
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'User-Agent': 'Electra Client', 'Content-Length': buf.length },
      timeout: timeoutMs
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8'); // join before decoding (Hebrew names!)
        if (res.statusCode < 200 || res.statusCode >= 300) return reject(new Error(`Electra HTTP ${res.statusCode}: ${raw.slice(0, 300)}`));
        try { resolve(JSON.parse(raw)); } catch (e) { reject(new Error(`Electra bad JSON: ${raw.slice(0, 300)}`)); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('Electra request timeout')));
    req.on('error', reject);
    req.write(buf);
    req.end();
  });
}

const resOk = (j) => j && j.status === 0 && j.data && (j.data.res === undefined || j.data.res === 0);
const resDesc = (j) => (j && j.data && j.data.res_desc) || JSON.stringify(j).slice(0, 300);

// Israeli mobile: accept 05XXXXXXXX, +9725XXXXXXXX, 9725XXXXXXXX (with spaces/dashes)
function normalizePhone(p) {
  let d = String(p || '').replace(/\D/g, '');
  if (d.startsWith('972')) d = '0' + d.slice(3);
  return /^05\d{8}$/.test(d) ? d : null;
}
function generateImei() {
  return '2b950000' + String(Math.floor(1e7 + Math.random() * 9e7)); // same format as pyElectra
}

const Electra = {
  sendOtp: (phone, imei) =>
    httpPostJson(ELECTRA_URL, { pvdid: 1, id: 99, cmd: 'SEND_OTP', data: { imei, phone } }),
  checkOtp: (phone, imei, code) =>
    httpPostJson(ELECTRA_URL, { pvdid: 1, id: 99, cmd: 'CHECK_OTP', data: { imei, phone, code, os: 'android', osver: 'M4B30Z' } }),
  validateToken: (imei, token) =>
    httpPostJson(ELECTRA_URL, { pvdid: 1, id: 99, cmd: 'VALIDATE_TOKEN', data: { imei, token, os: 'android', osver: 'M4B30Z' } })
};

class ElectraSession {
  constructor(sid) { this.sid = sid; }

  async cmd(cmd, data, timeoutMs) {
    const payload = { pvdid: 1, id: 99, cmd, sid: this.sid };
    if (data) payload.data = data;
    const t0 = Date.now();
    const j = await httpPostJson(ELECTRA_URL, payload, timeoutMs);
    console.log(`ELECTRA ${cmd} ${Date.now() - t0}ms`);
    if (!resOk(j)) {
      const e = new Error(`Electra ${cmd} failed: ${resDesc(j)}`);
      e.electra = true;
      throw e;
    }
    return j.data;
  }

  async listDevices() {
    const d = await this.cmd('GET_DEVICES');
    return (d.devices || []).filter(x => x.deviceTypeName === 'A/C');
  }

  // Returns { oper, measured, rat, calc, timeDelta }
  // rat = I_RAT (return air, what the Electra app shows), calc = I_CALC_AT (calculated room temp, some units only)
  async getState(deviceId) {
    const d = await this.cmd('GET_LAST_TELEMETRY', { id: Number(deviceId), commandName: 'OPER,DIAG_L2' });
    if (!d || !d.commandJson || !d.commandJson.OPER) { console.warn('NO_OPER', deviceId, JSON.stringify(d).slice(0, 1500)); throw new Error('A/C has not reported its state to the Electra cloud (offline?)'); }
    const oper = JSON.parse(d.commandJson.OPER).OPER;
    let measured = null, rat = null, calc = null;
    try {
      const diag = JSON.parse(d.commandJson.DIAG_L2).DIAG_L2;
      if (diag.I_RAT !== undefined && diag.I_RAT !== '') rat = Number(diag.I_RAT);
      if (diag.I_CALC_AT !== undefined && diag.I_CALC_AT !== '') calc = Number(diag.I_CALC_AT);
      measured = calc !== null ? calc : rat;
    } catch (e) { /* diag is best-effort */ }
    return { oper, measured, rat, calc, timeDelta: Number(d.timeDelta) || 0 };
  }

  async setOper(deviceId, oper) {
    const o = { ...oper };
    if ('AC_STSRC' in o) o.AC_STSRC = 'WI-FI';
    return this.cmd('SEND_COMMAND', { id: Number(deviceId), commandJson: JSON.stringify({ OPER: o }) }, 22000);
  }
}

// =====================================================================
// DynamoDB record helpers - keyed by our own opaque accessToken
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
// Partial update, so a sid refresh never overwrites callback fields written by another invocation
async function updateFields(accessToken, fields) {
  const keys = Object.keys(fields);
  await ddb.send(new UpdateCommand({
    TableName: TABLE_NAME,
    Key: { accessToken },
    UpdateExpression: 'SET ' + keys.map((k, i) => `#k${i} = :v${i}`).join(', '),
    ExpressionAttributeNames: Object.fromEntries(keys.map((k, i) => [`#k${i}`, k])),
    ExpressionAttributeValues: Object.fromEntries(keys.map((k, i) => [`:v${i}`, fields[k]]))
  }));
}

// Runs fn(session) with a cached sid. Gets a new sid when expired, or once on failure -
// but never more than once per 5 min (Electra locks out clients that ask too often).
async function withElectra(accessToken, record, fn) {
  const newSid = async () => {
    const now = Date.now();
    if (record.sidRequestedAt && now - record.sidRequestedAt < SID_MIN_GAP_MS) {
      throw new Error('Electra sid requested <5 min ago; skipping to avoid lockout');
    }
    const j = await Electra.validateToken(record.imei, decrypt(record.tokenEnc));
    await updateFields(accessToken, { sidRequestedAt: now }); // record the attempt even if it fails
    record.sidRequestedAt = now;
    if (!j || !j.data || !j.data.sid) throw new Error(`Electra VALIDATE_TOKEN failed: ${resDesc(j)}`);
    record.sid = j.data.sid;
    record.sidExpiresAt = now + SID_TTL_MS;
    await updateFields(accessToken, { sid: record.sid, sidExpiresAt: record.sidExpiresAt });
  };

  if (!record.sid || Date.now() > (record.sidExpiresAt || 0)) {
    try { await newSid(); } catch (e) { if (!record.sid) throw e; console.warn(e.message, '- trying old sid'); }
  }
  try {
    return await fn(new ElectraSession(record.sid));
  } catch (e) {
    if (!e.electra) throw e;
    console.warn('Electra call failed, refreshing sid and retrying:', e.message);
    await newSid();
    return fn(new ElectraSession(record.sid));
  }
}

// =====================================================================
// Electra OPER -> SmartThings states
// =====================================================================
function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

function isOn(oper) {
  if ('TURN_ON_OFF' in oper) return oper.TURN_ON_OFF === 'ON';
  return oper.AC_MODE !== 'STBY';
}

// kind: 'v8' (legacy Tadiran profile), 'std' ("Electra AC"), 'ra' ("Electra AC RA")
function stateToStates(st, extId, kind = 'v8') {
  const { oper, measured, rat } = st;
  const on = isOn(oper) ? 'on' : 'off';
  const setInt = clamp(parseInt(oper.SPT, 10) || 24, MIN_TEMP, MAX_TEMP);
  const mode = ELECTRA_MODES.includes(oper.AC_MODE) ? oper.AC_MODE : 'COOL'; // STBY -> show COOL
  // timeDelta = seconds since the A/C last changed state (grows while idle), NOT a heartbeat,
  // so a successful telemetry read means online; read failures mark offline in the handlers.
  const states = [
    { capability: 'st.switch', attribute: 'switch', value: on },
    { capability: 'st.thermostatCoolingSetpoint', attribute: 'coolingSetpoint', value: setInt, unit: 'C' },
    { capability: 'vehiclepatch55148.acTemperature', attribute: 'tempSet', value: setInt },
    { capability: 'vehiclepatch55148.acMode', attribute: 'mode', value: mode },
    { capability: 'vehiclepatch55148.acFanSpeed', attribute: 'fanSpeed', value: FAN_TO_ST[oper.FANSPD] || 'AUTO' },
    { capability: 'vehiclepatch55148.acStatus', attribute: 'statusSwitch', value: on },
    { capability: 'vehiclepatch55148.acStatus', attribute: 'statusMode', value: mode },
    { capability: 'vehiclepatch55148.acStatus', attribute: 'statusTempSet', value: setInt },
    { capability: 'vehiclepatch55148.acStatus2', attribute: 'statusMode', value: mode },
    { capability: 'vehiclepatch55148.acStatus2', attribute: 'statusTempSet', value: setInt },
    { capability: 'vehiclepatch55148.acDeviceId', attribute: 'shortId', value: String(extId).slice(-8) },
    { capability: 'st.healthCheck', attribute: 'checkInterval', value: 3600 },
    { capability: 'st.healthCheck', attribute: 'healthStatus', value: 'online' }
  ];
  const onOff = (k) => (oper[k] === 'ON' ? 'on' : 'off');
  if (kind !== 'ra') { // "central" (RA) units have no swing/turbo
    states.push({ capability: 'vehiclepatch55148.acSwingUpDown', attribute: 'switch', value: onOff('VSWING') });
    states.push({ capability: 'vehiclepatch55148.acSwingLeftRight', attribute: 'switch', value: onOff('HSWING') });
    states.push({ capability: 'vehiclepatch55148.acTurbo', attribute: 'switch', value: onOff('TURBO') });
  }
  if (kind !== 'v8') { // new Electra profiles
    states.push({ capability: 'vehiclepatch55148.acSleep', attribute: 'switch', value: onOff('SLEEP') });
    states.push({ capability: 'vehiclepatch55148.acShabbat', attribute: 'switch', value: onOff('SHABAT') });
    states.push({ capability: 'vehiclepatch55148.acIfeel', attribute: 'switch', value: onOff('IFEEL') });
    states.push({ capability: 'vehiclepatch55148.acFilter', attribute: 'status', value: oper.CLEAR_FILT === 'ON' ? 'clean' : 'ok' });
  }
  if (kind === 'v8') { // legacy profile has Light/Mute rows; Electra doesn't support them
    states.push({ capability: 'vehiclepatch55148.acLight', attribute: 'switch', value: 'off' });
    states.push({ capability: 'vehiclepatch55148.acMute', attribute: 'switch', value: 'off' });
  }
  if (kind === 'ra' && typeof rat === 'number' && !isNaN(rat)) {
    states.push({ capability: 'vehiclepatch55148.acReturnAir', attribute: 'temperature', value: Math.round(rat) });
  }
  if (typeof measured === 'number' && !isNaN(measured)) {
    states.push({ capability: 'st.temperatureMeasurement', attribute: 'temperature', value: measured, unit: 'C' });
    states.push({ capability: 'vehiclepatch55148.acTemperature', attribute: 'tempCurrent', value: Math.round(measured) });
  }
  return states;
}

const kindOf = (record, id) => (record.deviceProfiles && record.deviceProfiles[id]) || 'v8';

// Units reporting both sensors get the Return Air profile
async function detectKind(s, id) {
  try { const st = await s.getState(id); return st.calc !== null && st.rat !== null ? 'ra' : 'std'; }
  catch (e) { if (e.electra) throw e; return 'std'; }
}

function addStates(dev, states) {
  for (const s of states) dev.addState('main', s.capability, s.attribute, s.value, s.unit);
}

// Applies SmartThings commands to a copy of the current OPER. Returns { oper, changed }.
function applyCommands(currentOper, commands) {
  const o = { ...currentOper };
  let changed = false, handled = false;
  const set = (k, v) => { handled = true; if (o[k] !== v) { o[k] = v; changed = true; } };
  const hasOnOff = 'TURN_ON_OFF' in o;

  for (const c of commands) {
    const a = (c.arguments || [])[0];
    switch (`${c.capability}:${c.command}`) {
      case 'st.switch:on':
        if (hasOnOff) set('TURN_ON_OFF', 'ON');
        else if (o.AC_MODE === 'STBY') set('AC_MODE', 'COOL');
        break;
      case 'st.switch:off':
        if (hasOnOff) set('TURN_ON_OFF', 'OFF'); else set('AC_MODE', 'STBY');
        break;
      case 'vehiclepatch55148.acTemperature:setTempSet':
      case 'st.thermostatCoolingSetpoint:setCoolingSetpoint':
        set('SPT', String(Math.round(clamp(Number(a), MIN_TEMP, MAX_TEMP)))); break;
      case 'vehiclepatch55148.acMode:setMode':
        if (ELECTRA_MODES.includes(a)) set('AC_MODE', a); break;
      case 'vehiclepatch55148.acFanSpeed:setFanSpeed':
        if (a in ST_TO_FAN) set('FANSPD', ST_TO_FAN[a]); break;
      case 'vehiclepatch55148.acSwingUpDown:setSwitch':
        if ('VSWING' in o) set('VSWING', a === 'on' ? 'ON' : 'OFF'); break;
      case 'vehiclepatch55148.acSwingLeftRight:setSwitch':
        if ('HSWING' in o) set('HSWING', a === 'on' ? 'ON' : 'OFF'); break;
      case 'vehiclepatch55148.acTurbo:setSwitch':
        if ('TURBO' in o) set('TURBO', a === 'on' ? 'ON' : 'OFF'); break;
      case 'vehiclepatch55148.acSleep:setSwitch':
        if ('SLEEP' in o) set('SLEEP', a === 'on' ? 'ON' : 'OFF'); break;
      case 'vehiclepatch55148.acShabbat:setSwitch':
        if ('SHABAT' in o) set('SHABAT', a === 'on' ? 'ON' : 'OFF'); break;
      case 'vehiclepatch55148.acIfeel:setSwitch':
        if ('IFEEL' in o) set('IFEEL', a === 'on' ? 'ON' : 'OFF'); break;
      default: console.log('Unhandled/unsupported command:', c.capability, c.command);
    }
  }
  return { oper: o, changed, handled };
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
    const { devices, kinds } = await withElectra(accessToken, record, async (s) => {
      const list = await s.listDevices();
      const k = {};
      for (const d of list) k[String(d.id)] = await detectKind(s, String(d.id));
      return { devices: list, kinds: k };
    });
    console.log('DISCOVERY - devices:', devices.map(d => `${d.id} ${d.name} [${kinds[String(d.id)]}]`).join(', '));
    await updateFields(accessToken, {
      knownDeviceIds: devices.map(d => String(d.id)),
      deviceProfiles: { ...(record.deviceProfiles || {}), ...kinds }
    });
    for (const d of devices) {
      response.addDevice(String(d.id), d.name || 'Electra AC', profileIdFor(kinds[String(d.id)]))
        .manufacturerName('Electra')
        .modelName(String(d.model || 'Electra AC'));
    }
  })
  .stateRefreshHandler(async (accessToken, response, requested) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    await withElectra(accessToken, record, async (s) => {
      const ids = (requested && requested.length)
        ? requested.map(d => d.externalDeviceId)
        : (await s.listDevices()).map(d => String(d.id));
      for (const id of ids) {
        const dev = response.addDevice(id);
        try {
          const st = await s.getState(id);
          console.log('STATE REFRESH -', id, JSON.stringify(st));
          addStates(dev, stateToStates(st, id, kindOf(record, id)));
        } catch (e) {
          if (e.electra) throw e; // let withElectra refresh the sid
          console.error('STATE REFRESH failed for', id, e.message);
          dev.addState('main', 'st.healthCheck', 'healthStatus', 'offline');
        }
      }
    });
  })
  .commandHandler(async (accessToken, response, devices) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    for (const cmd of devices) {
      console.log('COMMAND -', JSON.stringify(cmd));
      const id = cmd.externalDeviceId;
      const dev = response.addDevice(id);
      try {
        const st = await withElectra(accessToken, record, async (s) => {
          const cur = await s.getState(id);
          const { oper, changed, handled } = applyCommands(cur.oper, cmd.commands || []);
          // Always send a recognized command, even if telemetry says it's already in that state
          // (telemetry can lag behind the real A/C).
          if (handled) {
            try {
              await s.setOper(id, oper);
            } catch (e) {
              if (e.electra) throw e;            // API error -> withElectra refreshes sid and retries
              // Timeout/network: Electra often applies the command anyway. Report the new state
              // optimistically instead of an error (an error makes SmartThings show "offline");
              // the 5-min sync corrects it if the command really didn't land.
              console.warn('COMMAND - SEND_COMMAND did not confirm:', e.message);
            }
          }
          console.log('COMMAND - handled:', handled, 'changed:', changed, 'OPER now', JSON.stringify(oper));
          return { ...cur, oper, timeDelta: 0 }; // optimistic: report what we just sent
        });
        addStates(dev, stateToStates(st, id, kindOf(record, id)));
      } catch (e) {
        console.error('COMMAND failed:', e.message);
        dev.setError(e.message, DeviceErrorTypes.DEVICE_UNAVAILABLE);
      }
    }
  })
  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    const record = await getRecord(accessToken);
    if (!record) return;
    await updateFields(accessToken, { callbackAuthentication, callbackUrls });
  })
  .integrationDeletedHandler(async (accessToken) => {
    await deleteRecord(accessToken).catch(() => {});
  });

// =====================================================================
// Proactive sync (EventBridge every 5 min)
// =====================================================================
function rawPost(urlStr, obj) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const buf = Buffer.from(JSON.stringify(obj), 'utf8');
    const req = https.request({ hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': buf.length }, timeout: 15000 }, (res) => {
      const chunks = []; res.on('data', c => chunks.push(c));
      res.on('end', () => resolve(`HTTP ${res.statusCode} ${Buffer.concat(chunks).toString('utf8')}`));
    });
    req.on('timeout', () => req.destroy(new Error('timeout'))); req.on('error', reject);
    req.write(buf); req.end();
  });
}

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
  if (!rec.callbackAuthentication || !rec.callbackUrls || !rec.tokenEnc) return 'skipped (no callback)';
  let newDevices = [];
  const newKinds = {};
  const deviceState = await withElectra(rec.accessToken, rec, async (s) => {
    const all = await s.listDevices();
    const ids = all.map(d => String(d.id));

    // Records linked before this feature have no list yet: assume current devices already exist in ST.
    if (!Array.isArray(rec.knownDeviceIds)) {
      rec.knownDeviceIds = ids;
      await updateFields(rec.accessToken, { knownDeviceIds: ids });
    }
    const known = new Set(rec.knownDeviceIds);
    newDevices = all.filter(d => !known.has(String(d.id)));

    const out = [];
    for (const d of all) {
      const id = String(d.id);
      if (!known.has(id)) { newKinds[id] = await detectKind(s, id); continue; } // state pushed next cycle
      try {
        const st = await s.getState(id);
        out.push({
          externalDeviceId: id,
          states: stateToStates(st, id, kindOf(rec, id)).map(x => ({
            component: 'main', capability: x.capability, attribute: x.attribute, value: x.value,
            ...(x.unit ? { unit: x.unit } : {})
          }))
        });
      } catch (e) {
        if (e.electra) throw e;
        out.push({ externalDeviceId: id, states: [{ component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: 'offline' }] });
      }
    }
    return out;
  });
  let added = '';
  if (newDevices.length) {
    // Proactive discovery: A/C added in the Electra app after linking -> create it in SmartThings
    const req = new DiscoveryRequest(ST_CLIENT_ID, ST_CLIENT_SECRET);
    for (const d of newDevices) {
      req.addDevice(new DiscoveryDevice(String(d.id), d.name || 'Electra AC', profileIdFor(newKinds[String(d.id)]))
        .manufacturerName('Electra')
        .modelName(String(d.model || 'Electra AC')));
    }
    let refreshedD = null;
    await req.sendDiscovery(rec.callbackUrls, rec.callbackAuthentication, (auth) => { refreshedD = auth; });
    if (refreshedD) {
      rec.callbackAuthentication = refreshedD;
      await updateFields(rec.accessToken, { callbackAuthentication: refreshedD });
    }
    const ids = [...rec.knownDeviceIds, ...newDevices.map(d => String(d.id))];
    rec.knownDeviceIds = ids;
    rec.deviceProfiles = { ...(rec.deviceProfiles || {}), ...newKinds };
    await updateFields(rec.accessToken, { knownDeviceIds: ids, deviceProfiles: rec.deviceProfiles });
    added = `, discovered new: ${newDevices.map(d => d.id).join(',')}`;
  }
  if (!deviceState.length) return `no known devices${added}`;

  let refreshed = null;
  try {
    await new StateUpdateRequest(ST_CLIENT_ID, ST_CLIENT_SECRET)
      .updateState(rec.callbackUrls, rec.callbackAuthentication, deviceState, (auth) => { refreshed = auth; });
  } catch (e) {
    // DEBUG: repeat the call ourselves to capture SmartThings' error body
    try {
      const auth = refreshed || rec.callbackAuthentication;
      const body = await rawPost(rec.callbackUrls.stateCallback, {
        headers: { schema: 'st-schema', version: '1.0', interactionType: 'stateCallback', requestId: crypto.randomUUID() },
        authentication: { tokenType: 'Bearer', token: auth.accessToken },
        deviceState
      });
      console.error('SYNC DEBUG - ST response:', body.slice(0, 1500));
      console.error('SYNC DEBUG - payload:', JSON.stringify(deviceState).slice(0, 3000));
    } catch (e2) { console.error('SYNC DEBUG failed:', e2.message); }
    // Fallback: resend without the newest capabilities so the basic values keep working
    const NEW = /acSleep|acShabbat|acIfeel|acFilter|acReturnAir/;
    const slim = deviceState.map(d => ({ ...d, states: d.states.filter(x => !NEW.test(x.capability)) }));
    await new StateUpdateRequest(ST_CLIENT_ID, ST_CLIENT_SECRET)
      .updateState(rec.callbackUrls, refreshed || rec.callbackAuthentication, slim, (auth) => { refreshed = auth; });
    if (refreshed) await updateFields(rec.accessToken, { callbackAuthentication: refreshed });
    return `pushed ${slim.length} device(s) WITHOUT new capabilities (full push got 400)`;
  }
  if (refreshed) await updateFields(rec.accessToken, { callbackAuthentication: refreshed });
  return `pushed ${deviceState.length} device(s)${refreshed ? ' (callback token refreshed)' : ''}${added}`;
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
// OAuth account linking (/authorize, /token) - phone + SMS OTP, 2-step form
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

const PAGE_STYLE = 'font-family:sans-serif;max-width:400px;margin:40px auto;padding:0 16px';
const INPUT_STYLE = 'width:100%;padding:8px;margin:8px 0;box-sizing:border-box;font-size:16px';

function phoneForm(error, phone) {
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
  <body style="${PAGE_STYLE}">
    <h2>Connect your Electra account</h2>
    <p>Enter the phone number registered in the <b>Electra Smart</b> app. You'll get an SMS code.</p>
    <p dir="rtl">הזינו את מספר הטלפון הרשום באפליקציית <b>Electra Smart</b>. יישלח אליכם קוד ב-SMS.</p>
    ${error ? `<p style="color:red">${esc(error)}</p>` : ''}
    <form method="POST" onsubmit="this.querySelector('button').disabled=true">
      <input type="hidden" name="step" value="phone">
      <label>Phone / טלפון</label><br>
      <input type="tel" name="phone" value="${esc(phone)}" placeholder="05XXXXXXXX" required style="${INPUT_STYLE}"><br>
      <button type="submit" style="padding:10px 20px">Send code / שלח קוד</button>
    </form>
  </body></html>`;
}

function otpForm(error, phone, imei) {
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
  <body style="${PAGE_STYLE}">
    <h2>Enter the SMS code</h2>
    <p>Code sent to ${esc(phone)}.</p>
    <p dir="rtl">הזינו את הקוד שקיבלתם ב-SMS.</p>
    ${error ? `<p style="color:red">${esc(error)}</p>` : ''}
    <form method="POST" onsubmit="this.querySelector('button').disabled=true">
      <input type="hidden" name="step" value="otp">
      <input type="hidden" name="phone" value="${esc(phone)}">
      <input type="hidden" name="imei" value="${esc(imei)}">
      <label>Code / קוד</label><br>
      <input type="text" name="otp" inputmode="numeric" autocomplete="one-time-code" required style="${INPUT_STYLE}"><br>
      <button type="submit" style="padding:10px 20px">Connect / התחבר</button>
    </form>
  </body></html>`;
}

async function handleAuthorize(event) {
  const method = event.httpMethod || (event.requestContext && event.requestContext.http && event.requestContext.http.method);
  const qs = event.queryStringParameters || {};

  if (method === 'GET') return htmlResponse(phoneForm());
  if (method !== 'POST') return htmlResponse('Bad request', 400);

  const body = parseBody(event);

  // Step 1: phone -> SEND_OTP
  if (body.step !== 'otp') {
    const phone = normalizePhone(body.phone);
    if (!phone) return htmlResponse(phoneForm('Invalid phone number / מספר לא תקין', body.phone));
    const imei = generateImei();
    console.log('AUTHORIZE - SEND_OTP');
    try {
      const j = await Electra.sendOtp(phone, imei);
      if (!resOk(j)) {
        console.log('AUTHORIZE - SEND_OTP failed:', resDesc(j));
        return htmlResponse(phoneForm('Phone not registered in Electra Smart, or request failed. / המספר לא רשום באפליקציה.', body.phone));
      }
    } catch (e) {
      console.error('AUTHORIZE - SEND_OTP error:', e.message);
      return htmlResponse(phoneForm('Electra server error, try again. / שגיאת שרת, נסו שוב.', body.phone));
    }
    return htmlResponse(otpForm(null, phone, imei));
  }

  // Step 2: OTP -> CHECK_OTP -> token
  const phone = normalizePhone(body.phone);
  const imei = String(body.imei || '');
  const otp = String(body.otp || '').trim();
  if (!phone || !/^2b950000\d{8}$/.test(imei)) return htmlResponse(phoneForm('Session expired, start again.'));

  let token;
  try {
    const j = await Electra.checkOtp(phone, imei, otp);
    if (!resOk(j) || !j.data.token) {
      console.log('AUTHORIZE - CHECK_OTP failed:', resDesc(j));
      return htmlResponse(otpForm('Wrong code / קוד שגוי', phone, imei));
    }
    token = j.data.token;
  } catch (e) {
    console.error('AUTHORIZE - CHECK_OTP error:', e.message);
    return htmlResponse(otpForm('Electra server error, try again. / שגיאת שרת, נסו שוב.', phone, imei));
  }

  const accessToken = randHex(32);
  const codeSecret = randHex(16);
  console.log('AUTHORIZE - CHECK_OTP OK, linking', phone.slice(0, 3) + '****' + phone.slice(-3));
  await saveRecord(accessToken, {
    phone,
    imei,
    tokenEnc: encrypt(token),
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
  if (event.source === 'aws.events' || event.sync === true) return runSync();

  if (event.requestContext) {
    const path = event.rawPath || event.path || '';
    console.log('HTTP', path); // don't log the full event (phone/OTP)
    if (path.includes('/authorize')) return handleAuthorize(event);
    if (path.includes('/token')) return handleToken(event);
    return { statusCode: 404, body: 'Not found' };
  }

  console.log('Event:', JSON.stringify(event));
  return new Promise((resolve, reject) => {
    connector.handleLambdaCallback(event, context, (err, result) => {
      if (err) { console.error('handleLambdaCallback error:', err); reject(err); }
      else resolve(result);
    });
  });
};

exports._internal = { stateToStates, applyCommands, normalizePhone, generateImei, encrypt, decrypt };
