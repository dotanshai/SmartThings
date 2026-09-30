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

const { SchemaConnector, StateUpdateRequest, DeviceErrorTypes } = require('st-schema');
const https = require('https');
const crypto = require('crypto');
const { DynamoDBClient, GetItemCommand, PutItemCommand, DeleteItemCommand, ScanCommand } = require('@aws-sdk/client-dynamodb');
const { marshall, unmarshall } = require('@aws-sdk/util-dynamodb');

const TABLE = process.env.TABLE_NAME || 'LgThinqTokens';
const dynamo = new DynamoDBClient({ region: process.env.DYNAMO_REGION || 'us-east-1' });

// Separate OAuth-In app used only for a one-time, best-effort lookup of the
// user's SmartThings location timezone (r:locations:* scope) — see the
// per-user timezone bugfix note in memory for why this exists. Distinct
// from ST_CLIENT_ID/SECRET above, which are for our actual Schema Connector.
const LOCATION_APP_CLIENT_ID = process.env.LOCATION_APP_CLIENT_ID;
const LOCATION_APP_CLIENT_SECRET = process.env.LOCATION_APP_CLIENT_SECRET;
const LOCATION_CALLBACK_URI = 'https://s71sv44fuk.execute-api.eu-west-1.amazonaws.com/location-callback';

const NS = 'vehiclepatch55148'; // reusing your existing custom capability namespace
const MACHINE_STATUS_CAP = `${NS}.washerStatus`;
const LAUNDRY_ERROR_CAP = `${NS}.laundryFaultStatus`;
const CYCLE_TIMERS_CAP = `${NS}.cycleTimer`;
const REMOTE_READY_CAP = `${NS}.remoteReady`;
const LAUNDRY_CYCLES_CAP = `${NS}.laundryCycleStatus`;
const DEVICE_ID_CAP = `${NS}.deviceId`;
const DEVICE_PROFILE_ID = 'e9c83ef1-0f27-4f8f-a2e4-f0533ab32d7f'; // "LG ThinQ Laundry v22" (DEVELOPMENT — testing before publish) — adds visibleCondition on cycleTimer's detailView entry so the Cycle Timers card actually hides during DETECTING/COOL_DOWN (previously the timersVisible attribute was sent but nothing in the presentation used it). Only works for our own dev account until published; v21 (0e97f294...) remains PUBLISHED/live for all other users in the meantime.

// The machineState capability attribute is enum-constrained (required by
// SmartThings' schema validation) — if a DIFFERENT LG model reports a
// status word outside this list, sending it as-is gets the ENTIRE state
// update rejected by SmartThings, not just this one field (confirmed
// during testing). This is the known set from live testing on this
// specific model (F_V7_F___W.A__QEUK); other models may use a subset or
// have additional states not seen here.
const KNOWN_MACHINE_STATES = new Set([
  'RINSE_HOLD', 'POWER_OFF', 'RINSING', 'STEAM_SOFTENING', 'RESERVED',
  'END', 'DRYING', 'INITIAL', 'DETECTING', 'SPINNING', 'COOL_DOWN',
  'ERROR', 'SLEEP', 'RUNNING', 'PAUSE', 'REFRESHING',
]);

function safeMachineState(rawState, lastKnownGoodState) {
  if (KNOWN_MACHINE_STATES.has(rawState)) return rawState;
  console.warn(`Unrecognized machineState "${rawState}" — falling back safely. If you're on a different LG model, this state needs to be added to KNOWN_MACHINE_STATES and the capability's enum.`);
  // Prefer the last known-good value (keeps the schema-valid field
  // sensible); if we have none, fall back to a generic default rather
  // than guessing.
  if (lastKnownGoodState && KNOWN_MACHINE_STATES.has(lastKnownGoodState)) return lastKnownGoodState;
  return 'RUNNING';
}

function capitalizeState(raw) {
  // "COOL_DOWN" -> "COOL DOWN" — all caps, just replace underscores with spaces
  return (raw || '').replace(/_/g, ' ');
}

// Matches the friendly labels already used in the errorCode presentation's
// own automation.conditions alternatives, kept in sync so the value shown
// in the detail view and the value shown when building an automation
// condition always read the same.
const ERROR_CODE_DISPLAY = {
  none: 'No Error',
  LOCKED_MOTOR_ERROR: 'Locked Motor Error',
  WATER_LEVEL_SENSOR_ERROR: 'Water Level Sensor Error',
  TEMPERATURE_SENSOR_ERROR: 'Temperature Sensor Error',
  WATER_DRAIN_ERROR: 'Water Drain Error',
  UNABLE_TO_LOCK_ERROR: 'Unable To Lock Error',
  OUT_OF_BALANCE_ERROR: 'Out Of Balance Error',
  OVERFILL_ERROR: 'Overfill Error',
  DOOR_OPEN_ERROR: 'Door Open Error',
  WATER_SUPPLY_ERROR: 'Water Supply Error',
  POWER_FAIL_ERROR: 'Power Fail Error',
};
function errorCodeDisplay(code) {
  return ERROR_CODE_DISPLAY[code] || 'No Error';
}

function cycleCompleteDisplay(complete) {
  return complete ? 'Complete' : 'Not Complete';
}

function shouldShowTimers(s) {
  // Hide the Cycle Timers card when the machine is off, or during phases
  // that don't have meaningful cycle-time info yet (cool-down at the end,
  // detecting at the start).
  const HIDE_TIMERS_STATES = new Set(['COOL_DOWN', 'DETECTING']);
  return s.isOn && !HIDE_TIMERS_STATES.has(s.runState);
}

// States where the machine is actively mid-cycle — used to detect
// completion even when we never observed the intermediate "paused at
// zero" state directly (see isCycleComplete below).
const ACTIVE_RUN_STATES = new Set([
  'RUNNING', 'RINSING', 'SPINNING', 'DRYING', 'STEAM_SOFTENING', 'COOL_DOWN', 'REFRESHING',
]);

function isCycleComplete(s, previousRunState) {
  // Some LG models report "END" at completion (e.g. Shai's own unit) —
  // other models genuinely report "PAUSE" instead, with no distinct
  // "done" state at all, which breaks any automation expecting to see
  // "Done" (confirmed by a real user, homeagain, whose machines never
  // report END). A raw "PAUSE" alone is ambiguous — it's also what a
  // machine reports if the USER genuinely pauses mid-cycle. The
  // distinguishing signal is remaining time: a true mid-cycle pause still
  // has real time left on the clock, while a "finished but reported as
  // paused" state has already counted down to zero. So: PAUSE + zero
  // remaining time reliably means complete; PAUSE + real time left
  // means genuinely paused, not complete.
  if (s.runState === 'END') return true;
  if (s.runState === 'PAUSE' && (s.remainMinutes || 0) <= 0) return true;
  // BUGFIX (2026-09-10): the two checks above require us to actually
  // observe the "paused at zero" state directly — but our scheduled push
  // only samples every 5 minutes, and some machines transition straight
  // from actively running to POWER_OFF within that window, skipping the
  // intermediate paused-at-zero state entirely (reported by homeagain as
  // "inconsistent" cycle-done detection, most likely explained by this
  // polling gap). Catch this case too: if the PREVIOUS sample was
  // actively mid-cycle and the CURRENT sample is no longer active at
  // all, treat it as complete even without ever seeing the intermediate
  // state — a machine doesn't go from actively washing to fully off
  // without finishing (or being manually stopped, which is a rare
  // enough edge case that erring toward "complete" here is the right
  // tradeoff for the primary "cycle just finished" use case).
  if (previousRunState && ACTIVE_RUN_STATES.has(previousRunState) && !ACTIVE_RUN_STATES.has(s.runState) && s.runState !== 'PAUSE') {
    return true;
  }
  return false;
}

// BUGFIX (2026-09-20): isCycleComplete() above is a "moment in time"
// signal — it only returns true on the single poll where the transition
// is actually observed, and false on every poll before AND after that,
// including once the machine has settled into a stable off state.
// Confirmed via a real user report (homeagain): cycleComplete flipped
// from "yes" back to "no" hours later overnight with nothing happening —
// exactly what this reproduces (POWER_OFF -> POWER_OFF on the next poll
// no longer matches any of isCycleComplete's three conditions, so it
// silently reverts). For a "did the cycle finish" signal meant to drive
// automations, that's the wrong behavior — it should stay "complete"
// until a genuinely new cycle starts, not reset itself while the machine
// just sits there finished. This makes it sticky: stays true once set,
// until runState becomes actively-mid-cycle again (a real new cycle
// starting resets it back to false).
function stickyCycleComplete(cycleJustCompleted, currentRunState, previousSticky) {
  if (ACTIVE_RUN_STATES.has(currentRunState)) return false;
  if (cycleJustCompleted) return true;
  return !!previousSticky;
}

function formatHM(totalMinutes) {
  const h = Math.floor((totalMinutes || 0) / 60);
  const m = (totalMinutes || 0) % 60;
  if (h === 0) return `${m}m`;
  return `${h}h ${m}m`;
}

function shortDeviceId(externalDeviceId) {
  // Last 8 chars of the externalDeviceId hash — short enough to quote in a
  // forum post, still practically unique across the real users we have.
  return (externalDeviceId || '').slice(-8);
}

function estimatedEndTime(remainMinutes, timeZoneId, timeFormat) {
  const end = new Date(Date.now() + (remainMinutes || 0) * 60000);
  // Uses the user's own SmartThings location timezone when we have it
  // (resolved once via a one-time location-lookup consent flow — see the
  // per-user timezone bugfix note in memory). Falls back to Israel time
  // only for accounts that haven't been through that flow yet (e.g.
  // existing installs from before this fix, until they reinstall).
  // Defaults to 12-hour AM/PM (Shai's stated default), but respects the
  // user's own choice via the timeFormat capability's setFormat command
  // once they've set it (stored per-account as data.timeFormat).
  const hour12 = timeFormat !== '24h';
  return new Intl.DateTimeFormat(hour12 ? 'en-US' : 'en-GB', {
    timeZone: timeZoneId || 'Asia/Jerusalem',
    hour: '2-digit',
    minute: '2-digit',
    hour12,
  }).format(end);
}

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

// Country -> region domain prefix. LG ThinQ Connect actually has THREE
// regions, not two — a bug found 2026-08-25 via a real user report
// (InnovarisTy, Philippines, "Not supported domain" error): this table
// was missing "kic" (Korea/Asia-Pacific) entirely, so any APAC country
// silently fell back to "eic" (Europe) and got rejected by LG's backend
// for being routed to the wrong regional domain. Extend as needed.
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
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        // Accumulate as raw Buffer chunks and decode UTF-8 only once at the
        // end — concatenating chunks as strings (`data += c`) is unsafe:
        // a multi-byte character (Hebrew, etc.) that happens to split
        // across two network chunks gets corrupted, since each chunk would
        // be decoded independently mid-character. Confirmed as the real
        // cause of garbled device names (e.g. Hebrew aliases) reaching
        // SmartThings — found 2026-08-31.
        const data = Buffer.concat(chunks).toString('utf8');
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

// Fallback display names when LG doesn't provide info.alias for a device —
// keyed by device type so two unnamed devices on the same account (e.g. a
// washer and a dryer with no alias set) don't both get the exact same
// generic label, which made them look like duplicates in the ST app.
const FALLBACK_DEVICE_NAME = {
  DEVICE_WASHER: 'LG Washer',
  DEVICE_DRYER: 'LG Dryer',
  DEVICE_WASHTOWER: 'LG WashTower',
  DEVICE_WASHCOMBO_MAIN: 'LG Washer/Dryer Combo',
  DEVICE_WASHCOMBO_MINI: 'LG Washer/Dryer Combo (Mini)',
};

// ─── Status normalisation ────────────────────────────────────────────────────

const FRIENDLY_STATE = {
  RINSE_HOLD: 'Rinse Hold', POWER_OFF: 'Off', RINSING: 'Rinsing',
  STEAM_SOFTENING: 'Steaming', RESERVED: 'Reserved', END: 'Done',
  DRYING: 'Drying', INITIAL: 'Ready', DETECTING: 'Detecting',
  SPINNING: 'Spinning', COOL_DOWN: 'Cooling', ERROR: 'Error',
  SLEEP: 'Sleep', RUNNING: 'Washing', PAUSE: 'Paused', REFRESHING: 'Refreshing',
};

function friendlyState(raw) {
  return FRIENDLY_STATE[raw] || raw;
}

const KNOWN_ERROR_CODES = new Set([
  'none', 'LOCKED_MOTOR_ERROR', 'WATER_LEVEL_SENSOR_ERROR', 'TEMPERATURE_SENSOR_ERROR',
  'WATER_DRAIN_ERROR', 'UNABLE_TO_LOCK_ERROR', 'OUT_OF_BALANCE_ERROR', 'OVERFILL_ERROR',
  'DOOR_OPEN_ERROR', 'WATER_SUPPLY_ERROR', 'POWER_FAIL_ERROR',
]);

function normaliseStatus(raw) {
  // LG returns either a single object or (for some models) a list with
  // one entry per location — confirmed live: your washer returns a
  // single-item list.
  const s = Array.isArray(raw) ? (raw[0] || {}) : (raw || {});
  const runState = s.runState?.currentState || 'POWER_OFF';
  const timer = s.timer || {};
  const remainMinutes = (timer.remainHour || 0) * 60 + (timer.remainMinute || 0);
  const totalMinutes = (timer.totalHour || 0) * 60 + (timer.totalMinute || 0);
  // NOT YET CONFIRMED LIVE: we've never seen the machine actually error out,
  // so this field path is a best guess based on the profile's top-level
  // "error" enum list, not a verified response shape. Falls back to "none"
  // safely either way. Worth checking against a real error the next time
  // one happens (e.g. via CloudWatch logs of the raw LG response).
  const rawErrorCode = s.error?.errorCode || s.error || 'none';
  const errorCode = KNOWN_ERROR_CODES.has(rawErrorCode) ? rawErrorCode : 'none';
  return {
    runState,
    isOn: runState !== 'POWER_OFF',
    remainMinutes,
    totalMinutes,
    cycleCount: s.cycle?.cycleCount || 0,
    remoteControlEnabled: !!s.remoteControlEnable?.remoteControlEnabled,
    locationName: s.location?.locationName || 'MAIN',
    errorCode,
  };
}

// ─── Schema Connector ────────────────────────────────────────────────────────

// Set fresh by exports.handler before each invocation reaches the connector
// — see the BUGFIX comment there for why this exists. null means
// "unfiltered" (e.g. not a stateRefreshRequest, or parsing failed).
let lastRequestedRefreshDeviceIds = null;

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

    // TEST (2026-09-01): homeagain's washer consistently, 100% fails to
    // bind on SmartThings' side ("Not connected device") while his dryer
    // — always the FIRST device in LG's own listDevices() order — always
    // succeeds. Testing the hypothesis that SmartThings only properly
    // binds the first device in a multi-device discoveryResponse, by
    // explicitly putting Washer-type devices first regardless of what
    // order LG's API happens to return them in.
    const sortedDevices = [...(devices || [])].sort((a, b) => {
      const aIsWasher = a.deviceInfo?.deviceType === 'DEVICE_WASHER' ? 0 : 1;
      const bIsWasher = b.deviceInfo?.deviceType === 'DEVICE_WASHER' ? 0 : 1;
      return aIsWasher - bIsWasher;
    });

    for (const d of sortedDevices) {
      const info = d.deviceInfo || {};
      if (!LAUNDRY_TYPES.has(info.deviceType)) continue; // laundry-only for v1

      response.addDevice(d.deviceId, info.alias || FALLBACK_DEVICE_NAME[info.deviceType] || 'LG Laundry Appliance', DEVICE_PROFILE_ID)
        .manufacturerName('LG')
        .modelName(info.modelName || 'ThinQ Laundry')
        .swVersion('1.0.0');
    }
  })

  .stateRefreshHandler(async (accessToken, response) => {
    const data = await getData(accessToken);
    if (!data) {
      // No record at all for this specific token — returning a fully
      // empty response makes SmartThings show "BAD-RESPONSE / Empty
      // device state" with zero useful info in the app. We don't have a
      // deviceId to report against here, so there's nothing more
      // specific we can do — but log loudly, since a silent return here
      // is exactly what let this go unnoticed before.
      console.error(`stateRefreshHandler: no data found for accessToken ${accessToken} — refresh will show no data in the app`);
      return;
    }

    // BUGFIX (2026-08-24, corrected): stateRefreshHandler does NOT receive
    // a "devices" list as a third argument the way commandHandler does —
    // that was an incorrect assumption in an earlier fix today and caused
    // "TypeError: devices is not iterable" on every single refresh call,
    // a total outage of the refresh path. The correct pattern (matching
    // discoveryHandler) is to ask LG directly for the account's current
    // device list, then report state for every laundry device found.
    let lgDevices;
    try {
      lgDevices = await LG.listDevices(data.pat, data.clientId, data.countryCode);
    } catch (e) {
      console.error('LG listDevices failed during refresh:', e.message);
      return;
    }

    const laundryDevices = (lgDevices || [])
      .filter(d => LAUNDRY_TYPES.has(d.deviceInfo?.deviceType))
      .filter(d => !lastRequestedRefreshDeviceIds || lastRequestedRefreshDeviceIds.has(d.deviceId));
    const updatedDevices = { ...(data.devices || {}) };

    for (const d of laundryDevices) {
      const deviceId = d.deviceId;
      const deviceResp = response.addDevice(deviceId);
      const component = deviceResp.addComponent('main');
      const lastKnownGoodState = data.devices?.[deviceId]?.lastStatus?.runState;

      try {
        const raw = await LG.getStatus(deviceId, data.pat, data.clientId, data.countryCode);
        const s = normaliseStatus(raw);
        const cycleJustCompleted = isCycleComplete(s, lastKnownGoodState);
        // Sticky display value: stays "complete" until a genuinely new
        // cycle starts, rather than reverting to "not complete" on the
        // very next poll once the machine settles into a stable off
        // state (see stickyCycleComplete's own comment for why).
        const previousSticky = data.devices?.[deviceId]?.lastCycleComplete;
        const stickyComplete = stickyCycleComplete(cycleJustCompleted, s.runState, previousSticky);
        // BUGFIX (2026-09-10): LG's own API doesn't send a cycle count at
        // all for some models (confirmed for homeagain's washer/dryer —
        // raw.cycle is undefined, while other users' devices correctly
        // return it), so s.cycleCount is always 0 for those units. Track
        // our own fallback counter, incremented once per genuine
        // completion (guarded by the PREVIOUS sticky value, so a machine
        // sitting in "complete" across many consecutive polls doesn't get
        // double-counted). Only used when LG's own field is missing —
        // never overrides a real value LG does provide.
        const previousOwnCount = data.devices?.[deviceId]?.ownCycleCount || 0;
        const ownCycleCount = (cycleJustCompleted && !previousSticky) ? previousOwnCount + 1 : previousOwnCount;
        const effectiveCycleCount = s.cycleCount || ownCycleCount;

        component.addState('st.switch', 'switch', s.isOn ? 'on' : 'off');
        component.addState('st.healthCheck', 'healthStatus', 'online');
        component.addState(MACHINE_STATUS_CAP, 'machineState', safeMachineState(s.runState, lastKnownGoodState));
        component.addState(MACHINE_STATUS_CAP, 'machineStateDisplay', capitalizeState(s.runState));
        component.addState(LAUNDRY_ERROR_CAP, 'errorCode', s.errorCode);
        component.addState(LAUNDRY_ERROR_CAP, 'errorCodeDisplay', errorCodeDisplay(s.errorCode));
        component.addState(LAUNDRY_ERROR_CAP, 'errorPresent', s.errorCode !== 'none' ? 'yes' : 'no');
        component.addState(CYCLE_TIMERS_CAP, 'remainingTimeMinutes', s.remainMinutes, 'min');
        component.addState(CYCLE_TIMERS_CAP, 'totalTimeMinutes', s.totalMinutes, 'min');
        component.addState(CYCLE_TIMERS_CAP, 'remainingTimeFormatted', formatHM(s.remainMinutes));
        component.addState(CYCLE_TIMERS_CAP, 'totalTimeFormatted', formatHM(s.totalMinutes));
        component.addState(CYCLE_TIMERS_CAP, 'estimatedEndTime', estimatedEndTime(s.remainMinutes, data.timeZoneId, data.timeFormat));
        component.addState(CYCLE_TIMERS_CAP, 'timersVisible', shouldShowTimers(s) ? 'show' : 'hide');
        component.addState(LAUNDRY_CYCLES_CAP, 'cycleCount', effectiveCycleCount);
        component.addState(LAUNDRY_CYCLES_CAP, 'cycleComplete', stickyComplete ? 'yes' : 'no');
        component.addState(LAUNDRY_CYCLES_CAP, 'cycleCompleteDisplay', cycleCompleteDisplay(stickyComplete));
        component.addState(REMOTE_READY_CAP, 'remoteControlEnabled', s.remoteControlEnabled);
        component.addState(REMOTE_READY_CAP, 'remoteReadyText', s.remoteControlEnabled ? 'Ready' : 'Not Ready');
        component.addState(DEVICE_ID_CAP, 'shortId', shortDeviceId(deviceId));
        component.addState(`${NS}.timeFormat`, 'format', data.timeFormat === '24h' ? '24h' : '12h');

        updatedDevices[deviceId] = { lastStatus: s, lastCycleComplete: stickyComplete, ownCycleCount };
      } catch (err) {
        console.error(`stateRefresh error for ${deviceId}:`, err.message);
        // BUGFIX (2026-09-08): SmartThings' own docs require cloud
        // connectors to signal DEVICE-UNAVAILABLE/DEVICE-DELETED via the
        // proper deviceError mechanism whenever a device can't be reached
        // — we were never doing this anywhere, just sending fake "off"/
        // "offline" state values as if the call had succeeded. Untested
        // hypothesis worth trying: this omission may be why SmartThings'
        // own backend ends up marking a device as permanently "Not
        // connected" instead of correctly tracking it as temporarily
        // unavailable, since we never told it what actually happened.
        deviceResp.setError(err.message || 'LG device temporarily unreachable', DeviceErrorTypes.DEVICE_UNAVAILABLE);
        component.addState('st.switch', 'switch', 'off');
        component.addState('st.healthCheck', 'healthStatus', 'offline');
        component.addState(DEVICE_ID_CAP, 'shortId', shortDeviceId(deviceId));
        // BUGFIX (2026-09-08): previously updatedDevices[deviceId] was only
        // ever set on success — a device whose very first LG.getStatus()
        // call fails (e.g. homeagain's washer, which fails consistently)
        // would NEVER get added to tracking at all, meaning the scheduled
        // push loop (which only iterates over already-tracked devices)
        // would never even attempt it again. Now keep the device tracked
        // with whatever lastStatus we already had (or none, on a genuine
        // first failure) so it stays eligible for retry via the scheduled
        // push, rather than silently falling out of the system forever.
        if (!updatedDevices[deviceId]) {
          updatedDevices[deviceId] = data.devices?.[deviceId] || { lastStatus: null };
        }
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
      const locationName = data.devices?.[deviceId]?.lastStatus?.locationName || 'MAIN';

      for (const cmd of device.commands) {
        const { capability, command } = cmd;
        console.log('Command:', capability, command);

        if (capability === `${NS}.timeFormat` && command === 'setFormat') {
          console.log('setFormat raw command:', JSON.stringify(cmd));
          const value = cmd.arguments?.[0];
          if (value === '12h' || value === '24h') {
            await storeData(accessToken, { ...data, timeFormat: value });
            if (data.parentRefreshToken) {
              const rtData = await getData(data.parentRefreshToken);
              if (rtData) await storeData(data.parentRefreshToken, { ...rtData, timeFormat: value });
            }
            component.addState(`${NS}.timeFormat`, 'format', value);
          } else {
            console.warn('setFormat: unexpected value', value);
          }
          continue;
        }

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
    if (!data) return;
    await storeData(accessToken, { ...data, callbackAuthentication, callbackUrls });
    // BUGFIX (2026-08-26): also propagate to the refresh token's own
    // record, not just this access token's. Previously only the access
    // token got enriched with callbackAuthentication/callbackUrls — the
    // refresh token's record stayed permanently stuck with the bare
    // fields from the original authorization_code exchange. Every later
    // token refresh copied that stale, incomplete data into a brand new
    // access token record, which then had no callbackAuthentication at
    // all — causing stateRefreshHandler to eventually fail with "Empty
    // device state" once enough refreshes had happened that the
    // in-use access token was one of these incomplete copies.
    if (data.parentRefreshToken) {
      const rtData = await getData(data.parentRefreshToken);
      if (rtData) await storeData(data.parentRefreshToken, { ...rtData, callbackAuthentication, callbackUrls });
    }
  })

  .integrationDeletedHandler(async (accessToken) => { await deleteData(accessToken); });

// ─── Scheduled proactive state push ──────────────────────────────────────────
// SmartThings only calls stateRefreshRequest on its own infrequent schedule
// (observed: not on every app view, sometimes 15-30+ min between polls) —
// that's a fallback mechanism, not the primary update path. The correct
// pattern is for US to proactively push state changes via the stateCallback
// URL SmartThings gave us during grantCallbackAccess, which is what this
// does. Triggered on a schedule (see README for the EventBridge rule setup)
// rather than by SmartThings itself — detected via a synthetic event field
// (event.source === 'lg-thinq-scheduled-push') that a CloudWatch Events
// rule's fixed JSON input sets, so this doesn't collide with real
// API-Gateway/Schema-callback invocations.

function buildStateArray(s, lastKnownGoodState, deviceId, statusChanged, timeZoneId, timeFormat, ownCycleCount, stickyComplete) {
  // Remaining time and estimated end time change on nearly every scheduled
  // push cycle (every 5 min) if sent unconditionally, which floods the
  // device's History log with noise unrelated to actual state transitions.
  // They're sent on the scheduled push ONLY when the machine status has
  // genuinely changed since the last push (e.g. RUNNING -> COOL_DOWN) —
  // that keeps the detail view's timer numbers reasonably fresh at
  // meaningful moments, without logging a new History entry every single
  // cycle for a value that's just ticking down. Pull-to-refresh /
  // opening the device (stateRefreshHandler) always sends them regardless.
  const states = [
    { component: 'main', capability: 'st.switch', attribute: 'switch', value: s.isOn ? 'on' : 'off' },
    { component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: 'online' },
    { component: 'main', capability: MACHINE_STATUS_CAP, attribute: 'machineState', value: safeMachineState(s.runState, lastKnownGoodState) },
    { component: 'main', capability: MACHINE_STATUS_CAP, attribute: 'machineStateDisplay', value: capitalizeState(s.runState) },
    { component: 'main', capability: LAUNDRY_ERROR_CAP, attribute: 'errorCode', value: s.errorCode },
    { component: 'main', capability: LAUNDRY_ERROR_CAP, attribute: 'errorCodeDisplay', value: errorCodeDisplay(s.errorCode) },
    { component: 'main', capability: LAUNDRY_ERROR_CAP, attribute: 'errorPresent', value: s.errorCode !== 'none' ? 'yes' : 'no' },
    { component: 'main', capability: CYCLE_TIMERS_CAP, attribute: 'totalTimeMinutes', value: s.totalMinutes, unit: 'min' },
    { component: 'main', capability: CYCLE_TIMERS_CAP, attribute: 'totalTimeFormatted', value: formatHM(s.totalMinutes) },
    { component: 'main', capability: CYCLE_TIMERS_CAP, attribute: 'timersVisible', value: shouldShowTimers(s) ? 'show' : 'hide' },
    { component: 'main', capability: LAUNDRY_CYCLES_CAP, attribute: 'cycleCount', value: s.cycleCount || ownCycleCount || 0 },
    { component: 'main', capability: LAUNDRY_CYCLES_CAP, attribute: 'cycleComplete', value: stickyComplete ? 'yes' : 'no' },
    { component: 'main', capability: LAUNDRY_CYCLES_CAP, attribute: 'cycleCompleteDisplay', value: cycleCompleteDisplay(stickyComplete) },
    { component: 'main', capability: REMOTE_READY_CAP, attribute: 'remoteControlEnabled', value: s.remoteControlEnabled },
    { component: 'main', capability: REMOTE_READY_CAP, attribute: 'remoteReadyText', value: s.remoteControlEnabled ? 'Ready' : 'Not Ready' },
    { component: 'main', capability: DEVICE_ID_CAP, attribute: 'shortId', value: shortDeviceId(deviceId) },
    { component: 'main', capability: `${NS}.timeFormat`, attribute: 'format', value: timeFormat === '24h' ? '24h' : '12h' },
  ];
  if (statusChanged) {
    states.push(
      { component: 'main', capability: CYCLE_TIMERS_CAP, attribute: 'remainingTimeMinutes', value: s.remainMinutes, unit: 'min' },
      { component: 'main', capability: CYCLE_TIMERS_CAP, attribute: 'remainingTimeFormatted', value: formatHM(s.remainMinutes) },
      { component: 'main', capability: CYCLE_TIMERS_CAP, attribute: 'estimatedEndTime', value: estimatedEndTime(s.remainMinutes, timeZoneId, timeFormat) },
    );
  }
  return states;
}

async function scanLinkedAccounts() {
  // Only records that completed grantCallbackAccess (have callbackUrls) and
  // have at least one tracked device are real linked accounts worth polling
  // — session/code records lack this. Each record can now represent
  // multiple physical devices (data.devices is keyed by externalDeviceId),
  // not just one, since an LG account can have a washer AND a dryer.
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

async function diagnosticRawPush(data, deviceState) {
  // st-schema's StateUpdateRequest swallows the response body on error,
  // only exposing statusCode + generic statusText. This bypasses it with
  // the exact same request shape, purely to log what SmartThings actually
  // says is wrong — not used for the real push, just diagnostics.
  return new Promise((resolve) => {
    const body = JSON.stringify({
      headers: { schema: 'st-schema', version: '1.0', interactionType: 'stateCallback', requestId: crypto.randomUUID() },
      authentication: { tokenType: 'Bearer', token: data.callbackAuthentication.accessToken },
      deviceState,
    });
    const url = new URL(data.callbackUrls.stateCallback);
    const req = https.request({
      hostname: url.hostname, path: url.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const respBody = Buffer.concat(chunks).toString('utf8');
        console.error(`Diagnostic raw push status=${res.statusCode} body=${respBody}`);
        resolve();
      });
    });
    req.on('error', (e) => { console.error('Diagnostic raw push request error:', e.message); resolve(); });
    req.write(body);
    req.end();
  });
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
      let deviceState;
      let raw;
      try {
        raw = await LG.getStatus(deviceId, data.pat, data.clientId, data.countryCode);
      } catch (err) {
        // BUGFIX (2026-09-08): previously this failure and a genuine
        // SmartThings-side push rejection shared one catch block below,
        // both triggering the "delete this device from our tracking"
        // cleanup logic whenever the error message happened to contain
        // "Not connected device". But confirmed via lgFetch()'s own error
        // parsing (parsed?.error?.message) that THIS specific failure —
        // LG.getStatus() itself throwing — is LG's OWN API telling us it
        // couldn't reach the device (a transient, LG-side condition, not
        // a signal from SmartThings that the integration was removed).
        // Treating it as a "delete from tracking" signal was very likely
        // wrong, and could explain why the washer kept vanishing from our
        // own device map on a routine LG-side hiccup. Now handled
        // separately: log and skip this device for this cycle only,
        // never delete tracking based on an LG-side failure.
        console.error(`LG getStatus failed for device ${deviceId} (LG-side, not touching account tracking):`, err.message);
        continue;
      }

      try {
        const s = normaliseStatus(raw);
        const previousRunState = data.devices[deviceId]?.lastStatus?.runState;
        const statusChanged = previousRunState === undefined || previousRunState !== s.runState;
        const cycleJustCompleted = isCycleComplete(s, previousRunState);
        const previousSticky = data.devices[deviceId]?.lastCycleComplete;
        const stickyComplete = stickyCycleComplete(cycleJustCompleted, s.runState, previousSticky);
        const previousOwnCount = data.devices[deviceId]?.ownCycleCount || 0;
        const ownCycleCount = (cycleJustCompleted && !previousSticky) ? previousOwnCount + 1 : previousOwnCount;
        deviceState = [{ externalDeviceId: deviceId, states: buildStateArray(s, previousRunState, deviceId, statusChanged, data.timeZoneId, data.timeFormat, ownCycleCount, stickyComplete) }];

        await updater.updateState(
          data.callbackUrls,
          data.callbackAuthentication,
          deviceState,
          async (newCallbackAuth) => {
            // Token was refreshed mid-call — persist it so next run uses the new one.
            await storeData(data.pk, { ...data, devices: updatedDevices, callbackAuthentication: newCallbackAuth });
          }
        );
        updatedDevices[deviceId] = { lastStatus: s, lastCycleComplete: stickyComplete, ownCycleCount };
        console.log(`Pushed update for device ${deviceId}: ${s.runState}`);
      } catch (err) {
        // This catch is now ONLY around the actual push to SmartThings —
        // a "Not connected device" here is a genuine signal from
        // SmartThings' own side, not LG's, so the existing cleanup logic
        // below is now correctly scoped to only this real case.
        console.error(`Push failed for device ${deviceId}:`, err.message);
        if (err.message && err.message.includes('Not connected device')) {
          // SmartThings' own signal that this externalDeviceId no longer
          // exists on their side (e.g. deleted directly via CLI during
          // testing, which bypasses integrationDeletedHandler and leaves a
          // stale record that would otherwise retry — and fail — forever).
          // Safe to drop just THIS device from the account's device map —
          // NOT the whole account record, since a sibling device (e.g. the
          // washer when the dryer went stale) may still be perfectly valid.
          console.warn(`Device ${deviceId} no longer connected on SmartThings' side — removing from account ${data.pk}`);
          delete updatedDevices[deviceId];
          removedAny = true;
          continue;
        }
        if (deviceState) await diagnosticRawPush(data, deviceState);
      }
    }

    if (removedAny && Object.keys(updatedDevices).length === 0) {
      // Every device on this account went stale — the whole record is now
      // dead weight, same cleanup outcome as before this fix.
      await deleteData(data.pk);
    } else {
      await storeData(data.pk, { ...data, devices: updatedDevices });
    }
  }
}

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

  // BUGFIX (2026-08-30): st-schema's stateRefreshHandler callback is only
  // (accessToken, response) — it does NOT expose which specific devices
  // SmartThings actually asked to be refreshed, even though the raw
  // request body always includes a "devices" array. Left unfiltered, our
  // handler was reporting on EVERY laundry device currently on the LG
  // account regardless of what was requested — which SmartThings then
  // rejects with "deviceState[N] does not correspond to any ST device"
  // whenever the response includes anything beyond what was asked for
  // (e.g. after a device is removed/re-added and its old externalDeviceId
  // is requested but no longer exists — our code was substituting a
  // DIFFERENT device's data instead of correctly reporting nothing for
  // the stale id). Extract the requested list here, from the raw body,
  // before handing off to the library, so stateRefreshHandler can filter
  // its response to only what was actually requested.
  lastRequestedRefreshDeviceIds = null;
  try {
    const rawBody = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
    const parsed = JSON.parse(rawBody);
    if (parsed?.headers?.interactionType === 'stateRefreshRequest' && Array.isArray(parsed.devices)) {
      lastRequestedRefreshDeviceIds = new Set(parsed.devices.map(d => d.externalDeviceId));
    }
  } catch (e) {
    // Not JSON, or not a stateRefreshRequest — leave lastRequestedRefreshDeviceIds as null (unfiltered).
  }

  if (event.source === 'lg-thinq-scheduled-push') {
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

      const washer = (devices || []).find(d => LAUNDRY_TYPES.has(d.deviceInfo?.deviceType));
      if (!washer) {
        return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' },
          body: loginPage(sid, 'No washer/dryer found on this LG account') };
      }

      const code = crypto.randomBytes(32).toString('hex');
      // Also carry the ORIGINAL schema-connector redirectUri/state through this
      // record, since we now detour through a second OAuth-In consent step
      // (location access, for per-user timezone) before completing the
      // original flow — /location-callback needs these to finish the redirect
      // back to SmartThings afterward.
      await storeData(code, { pk: code, pat, clientId, countryCode: country, deviceId: washer.deviceId, origRedirectUri: redirectUri, origState: state });
      if (sess) await deleteData('s:' + sid);

      // Detour through a second, separate OAuth-In consent screen to get
      // read access to the user's SmartThings location (for its timeZoneId,
      // used to show cycle times in the user's own local time instead of a
      // hardcoded one). Reusing `code` as this hop's own state value, since
      // it's already a secure random token AND doubles as the lookup key
      // for the record we just stored.
      const locationAuthUrl = new URL('https://api.smartthings.com/oauth/authorize');
      locationAuthUrl.searchParams.set('client_id', LOCATION_APP_CLIENT_ID);
      locationAuthUrl.searchParams.set('scope', 'r:locations:*');
      locationAuthUrl.searchParams.set('response_type', 'code');
      locationAuthUrl.searchParams.set('redirect_uri', LOCATION_CALLBACK_URI);
      locationAuthUrl.searchParams.set('state', code);
      return { statusCode: 302, headers: { Location: locationAuthUrl.toString() }, body: '' };
    }

    if (path === '/location-callback' && method === 'GET') {
      const locCode = qs.code || '';
      const state = qs.state || ''; // this is our own earlier `code` value
      const pending = await getData(state);
      if (!pending) {
        return { statusCode: 400, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: 'Session expired, please try linking again from the SmartThings app.' };
      }

      // Best-effort: if location lookup fails for any reason, don't block
      // the whole install over it — just finish without a timezone, and
      // estimatedEndTime() falls back to its existing default.
      try {
        const tokenResp = await fetch('https://api.smartthings.com/oauth/token', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Authorization': 'Basic ' + Buffer.from(`${LOCATION_APP_CLIENT_ID}:${LOCATION_APP_CLIENT_SECRET}`).toString('base64'),
          },
          body: new URLSearchParams({ grant_type: 'authorization_code', code: locCode, redirect_uri: LOCATION_CALLBACK_URI }),
        });
        const tokenJson = await tokenResp.json();
        const locAccessToken = tokenJson.access_token;

        if (locAccessToken) {
          const locListResp = await fetch('https://api.smartthings.com/v1/locations', {
            headers: { Authorization: `Bearer ${locAccessToken}` },
          });
          const locList = await locListResp.json();
          const firstLocation = locList?.items?.[0];

          if (firstLocation?.locationId) {
            const locDetailResp = await fetch(`https://api.smartthings.com/v1/locations/${firstLocation.locationId}`, {
              headers: { Authorization: `Bearer ${locAccessToken}` },
            });
            const locDetail = await locDetailResp.json();
            if (locDetail?.timeZoneId) {
              await storeData(state, { ...pending, pk: state, timeZoneId: locDetail.timeZoneId });
            }
          }
        }
      } catch (e) {
        console.error('Location lookup failed (non-fatal, continuing without timezone):', e.message);
      }

      const url = new URL(pending.origRedirectUri);
      url.searchParams.set('code', state);
      url.searchParams.set('state', pending.origState);
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
        await storeData(at, { ...stored, pk: at, parentRefreshToken: rt });
        await storeData(rt, { ...stored, pk: rt, isRefresh: true, currentAccessToken: at });
        await deleteData(code);
        return { statusCode: 200, headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ access_token: at, refresh_token: rt, token_type: 'Bearer', expires_in: 31536000 }) };
      }

      if (grantType === 'refresh_token') {
        const rt = params.get('refresh_token');
        const stored = await getData(rt);
        if (!stored) return { statusCode: 400, body: JSON.stringify({ error: 'invalid_grant' }) };
        const at = crypto.randomBytes(32).toString('hex');
        // BUGFIX (2026-09-04): previously created a fresh access-token
        // record on every refresh without ever cleaning up the one it
        // replaced — records accumulated indefinitely (Shai's own account
        // alone had 8-9+ stale records from past refreshes). Real user
        // impact confirmed: this can create a gap between the access
        // token SmartThings currently holds and what we've actually
        // stored, causing "no data found for accessToken" and the device
        // going offline. FIX: the refresh token's own record now tracks
        // which access token is currently "live" (currentAccessToken) —
        // each refresh deletes that previous record before creating the
        // new one, so at most one access-token record exists per account
        // at any time.
        if (stored.currentAccessToken && stored.currentAccessToken !== at) {
          try { await deleteData(stored.currentAccessToken); } catch (e) {
            console.error('Failed to delete stale access token on refresh (non-fatal):', e.message);
          }
        }
        await storeData(at, { ...stored, pk: at, isRefresh: false, parentRefreshToken: rt });
        await storeData(rt, { ...stored, pk: rt, isRefresh: true, currentAccessToken: at });
        return { statusCode: 200, headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ access_token: at, refresh_token: rt, token_type: 'Bearer', expires_in: 31536000 }) };
      }

      return { statusCode: 400, body: JSON.stringify({ error: 'unsupported_grant_type' }) };
    }

    return { statusCode: 404, body: 'Not found' };
  }

  return connector.handleLambdaCallback(event, context);
};
