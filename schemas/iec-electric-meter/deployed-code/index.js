'use strict';

const { SchemaConnector } = require('st-schema');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand } = require('@aws-sdk/lib-dynamodb');
const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');

// The DynamoDB table only exists in us-east-1 - pin to it explicitly so this Lambda works
// correctly even when deployed to other regions (SmartThings invokes region-specific Lambda
// ARNs based on the user's location, e.g. eu-west-1 for Israel-based accounts).
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: process.env.DYNAMO_REGION || 'us-east-1' }));
const TABLE = process.env.TABLE_NAME || 'IecSchemaConnectorTokens';

// iecapi.iec.co.il blocks requests from AWS's us-east-1/eu-west-1 (confirmed via a WAF 403).
// All actual IEC/Okta calls happen in a separate Lambda deployed to il-central-1 (Israel),
// invoked directly over the AWS SDK - no public endpoint, no third-party proxy, no home relay.
const ilCallerClient = new LambdaClient({ region: 'il-central-1' });
const IL_CALLER_FUNCTION_ARN = process.env.IL_CALLER_FUNCTION_ARN;

// The ID of a custom Device Profile you create in the Developer Workspace/CLI with:
//   capabilities: energyMeter, healthCheck, refresh
// (none of the pre-made "c2c-*" Device Handler Types cleanly cover a plain energy meter,
// so a custom profile - same as you already did for the Dolphin boiler - is the right call.)
const DEVICE_PROFILE_ID = process.env.DEVICE_PROFILE_ID;

// Connection capacity (e.g. "3-phase, 40A") is a static, rarely-changing string - not something
// energyMeter covers. Created via `smartthings capabilities:create` (see capability-connection-capacity.json).
const CONNECTION_CAPACITY_CAPABILITY = 'vehiclepatch55148.iecConnectionCapacity';

// contract.smartMeter is already fetched (from getContracts) and was only used internally
// for the device model name before - surfacing it as its own visible tile too.
const METER_TYPE_CAPABILITY = 'vehiclepatch55148.iecMeterType';

// Plain Wh number, no unit auto-scaling - energyMeter's own detail-view chart auto-scales to
// MWh above a magnitude threshold with no documented override (confirmed unfixable). Custom
// capabilities using the "state" display type don't have that built-in scaling behavior at
// all, so this sidesteps it entirely by just being a different capability.
const METER_READING_WH_CAPABILITY = 'vehiclepatch55148.iecMeterReadingWh';

// Real usage over real time windows, computed by us from tracked daily snapshots of the
// cumulative reading (stored in DynamoDB) - not from IEC's own daily/period breakdown, which
// is unreliable (came back empty when tested). daily = today's reading - yesterday's stored
// snapshot; weekly = today - 7 days ago; monthly = today - 30 days ago. Needs a few days/weeks
// of history to build up before weekly/monthly have anything to show.
const DAILY_USAGE_CAPABILITY = 'vehiclepatch55148.iecDailyUsage';
const WEEKLY_USAGE_CAPABILITY = 'vehiclepatch55148.iecWeeklyUsage';
const MONTHLY_USAGE_CAPABILITY = 'vehiclepatch55148.iecMonthlyUsage';

// User-editable rate (ILS/kWh), since suppliers vary and IEC's own published tariff doesn't
// apply once you switch to a private supplier. Rendered as an editable numberField in the
// app - not a real device preference (Schema Connectors don't have those), just a normal
// custom capability command, same pattern as the water meter's tariff fields.
const ENERGY_RATE_CAPABILITY = 'vehiclepatch55148.iecEnergyRate';
const DEFAULT_ENERGY_RATE = 0.61; // rough placeholder (approx IEC low-voltage home rate) until the user sets their own

// Optional: only surface specific contracts (comma-separated contractIds), for accounts where
// IEC's bpNumber has extra contracts attached that aren't actually yours to monitor. Rarely
// useful across a shared deployment since it's a single global allowlist - EXCLUDED_CONTRACT_IDS
// below is the one that's actually safe to use on a multi-user deployment.
// e.g. INCLUDED_CONTRACT_IDS=000345541725
const INCLUDED_CONTRACT_IDS = (process.env.INCLUDED_CONTRACT_IDS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

// Safe to use even on a shared multi-user deployment: contract IDs are globally unique per
// physical IEC contract, so this only ever excludes the specific contract(s) named here -
// e.g. a stale/unused contract on your own account - never anyone else's real contract.
// e.g. EXCLUDED_CONTRACT_IDS=000342010869
const EXCLUDED_CONTRACT_IDS = (process.env.EXCLUDED_CONTRACT_IDS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

// -------------------------------------------------------------------------------------
// Reading-history tracking (for daily/weekly/monthly usage deltas)
// -------------------------------------------------------------------------------------

// Israel's UTC offset in minutes at a given instant (handles DST automatically, no library
// needed) - the difference between Israel wall-clock time and UTC wall-clock time.
function israelOffsetMinutes(date) {
  const utcStr = date.toLocaleString('en-US', { timeZone: 'UTC', hour12: false });
  const ilStr = date.toLocaleString('en-US', { timeZone: 'Asia/Jerusalem', hour12: false });
  return Math.round((new Date(ilStr) - new Date(utcStr)) / 60000);
}

// Israel-local year/month/day/hour/weekday for a given instant.
function israelParts(date) {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Jerusalem',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hour12: false, weekday: 'short',
  });
  const parts = {};
  fmt.formatToParts(date).forEach((p) => { parts[p.type] = p.value; });
  return {
    year: parseInt(parts.year, 10),
    month: parseInt(parts.month, 10),
    day: parseInt(parts.day, 10),
    hour: parseInt(parts.hour, 10) % 24,
    weekday: parts.weekday, // "Sun", "Mon", ...
  };
}

// Converts an Israel-local Y/M/D/hour into the corresponding real UTC instant.
function israelLocalToUtc(year, month, day, hour) {
  const guess = Date.UTC(year, month - 1, day, hour);
  return new Date(guess - israelOffsetMinutes(new Date(guess)) * 60000);
}

function todayIso(now) {
  const p = israelParts(now);
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`;
}

const WEEKDAY_INDEX = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

// Most recent 7:00 Israel time at or before `now` - the start of the "current day".
function dayBoundary(now) {
  const p = israelParts(now);
  let boundary = israelLocalToUtc(p.year, p.month, p.day, 7);
  if (boundary > now) boundary = israelLocalToUtc(p.year, p.month, p.day - 1, 7);
  return boundary;
}

// Most recent Sunday 7:00 Israel time at or before `now` - the start of the "current week".
function weekBoundary(now) {
  const p = israelParts(now);
  const daysSinceSunday = WEEKDAY_INDEX[p.weekday];
  let boundary = israelLocalToUtc(p.year, p.month, p.day - daysSinceSunday, 7);
  if (boundary > now) boundary = israelLocalToUtc(p.year, p.month, p.day - daysSinceSunday - 7, 7);
  return boundary;
}

// Most recent 1st-of-month 7:00 Israel time at or before `now` - the start of the "current month".
function monthBoundary(now) {
  const p = israelParts(now);
  let boundary = israelLocalToUtc(p.year, p.month, 1, 7);
  if (boundary > now) {
    const prevMonth = p.month === 1 ? 12 : p.month - 1;
    const prevYear = p.month === 1 ? p.year - 1 : p.year;
    boundary = israelLocalToUtc(prevYear, prevMonth, 1, 7);
  }
  return boundary;
}

// Entries stored before this change only have `date`, not `timestamp` - fall back to noon
// UTC on that date so old history doesn't break sorting/comparisons. Only affects entries
// already on their way to aging out of the 40-day window; new entries always have a real one.
function entryTimestamp(h) {
  return h.timestamp || `${h.date}T12:00:00Z`;
}

// Earliest snapshot at or after a boundary instant - i.e. the first real reading captured
// after that Sunday/1st-of-month 7am passed (we only poll ~once a day, so this is rarely the
// exact boundary moment itself, just the closest we actually have data for). Used for weekly/
// monthly, which span multiple distinct calendar-day entries.
function earliestReadingAtOrAfter(history, boundary) {
  const sorted = [...history].sort((a, b) => new Date(entryTimestamp(a)) - new Date(entryTimestamp(b)));
  return sorted.find((h) => new Date(entryTimestamp(h)) >= boundary) || null;
}

// Most recent snapshot strictly before now - i.e. "yesterday's" stored reading. Daily can't
// use the same earliest-at-or-after-boundary approach as weekly/monthly: we only keep one
// snapshot per calendar day (continuously overwritten through the day), so there's no separate
// "reading at today's 7am" distinct from today's own current reading to compare against - the
// only real baseline available is whatever we last recorded before today.
function latestReadingBefore(history, boundary) {
  const sorted = [...history].sort((a, b) => new Date(entryTimestamp(a)) - new Date(entryTimestamp(b)));
  const candidates = sorted.filter((h) => new Date(entryTimestamp(h)) < boundary);
  return candidates.length ? candidates[candidates.length - 1] : null;
}

async function getReadingHistory(contractId) {
  const item = await ddb.send(new GetCommand({ TableName: TABLE, Key: { pk: `READINGS#${contractId}` } }));
  return (item.Item && item.Item.history) || [];
}

async function saveReadingHistory(contractId, history) {
  // ~40 days covers a full calendar month plus margin for the weekly/monthly boundary lookups.
  const trimmed = history.slice(-40);
  await ddb.send(new PutCommand({ TableName: TABLE, Item: { pk: `READINGS#${contractId}`, history: trimmed } }));
}

// Records today's reading (once per Israel-local calendar day) and computes daily/weekly/
// monthly deltas. Weekly resets Sunday 7:00 Israel time; monthly resets the 1st at 7:00 -
// both real calendar boundaries, not rolling 7/30-day windows. Returns nulls for any window
// that doesn't have a real snapshot on the far side of its boundary yet.
async function computeUsageDeltas(contractId, currentReading) {
  const now = new Date();
  let history = await getReadingHistory(contractId);
  const today = todayIso(now);

  const last = history[history.length - 1];
  if (last && last.date === today) {
    last.reading = currentReading; // keep the latest same-day reading
    last.timestamp = now.toISOString();
  } else {
    history.push({ date: today, reading: currentReading, timestamp: now.toISOString() });
  }
  history.sort((a, b) => new Date(entryTimestamp(a)) - new Date(entryTimestamp(b)));
  await saveReadingHistory(contractId, history);

  const priorHistory = history.filter((h) => h.date !== today);
  const yesterday = latestReadingBefore(priorHistory, dayBoundary(now));
  const weekStart = earliestReadingAtOrAfter(priorHistory, weekBoundary(now));
  const monthStart = earliestReadingAtOrAfter(priorHistory, monthBoundary(now));

  return {
    daily: yesterday ? currentReading - yesterday.reading : null,
    weekly: weekStart ? currentReading - weekStart.reading : null,
    monthly: monthStart ? currentReading - monthStart.reading : null,
  };
}

function formatUsage(kwh, sinceLabel) {
  if (kwh == null) return 'Building history...';
  return sinceLabel ? `${kwh.toFixed(2)} kWh (${sinceLabel})` : `${kwh.toFixed(2)} kWh`;
}

function formatWh(kwh) {
  return String(Math.round(kwh * 1000));
}

async function getRate(contractId) {
  const item = await ddb.send(new GetCommand({ TableName: TABLE, Key: { pk: `RATE#${contractId}` } }));
  return (item.Item && item.Item.rate) ?? DEFAULT_ENERGY_RATE;
}

async function setRate(contractId, value) {
  await ddb.send(new PutCommand({ TableName: TABLE, Item: { pk: `RATE#${contractId}`, rate: value } }));
}

// Fetches everything needed to describe/refresh this user's contracts+readings in one go,
// by invoking the il-central-1 Lambda (which does the actual IEC/Okta calls).
async function loadIecAccount(accessToken) {
  const item = await ddb.send(new GetCommand({ TableName: TABLE, Key: { pk: `TOKEN#${accessToken}` } }));
  if (!item.Item) throw new Error('Unknown or expired access token - user needs to re-link their IEC account');

  const invokeRes = await ilCallerClient.send(new InvokeCommand({
    FunctionName: IL_CALLER_FUNCTION_ARN,
    Payload: Buffer.from(JSON.stringify({
      iecRefreshToken: item.Item.iecRefreshToken,
      includedContractIds: INCLUDED_CONTRACT_IDS,
      excludedContractIds: EXCLUDED_CONTRACT_IDS,
    })),
  }));

  const payload = JSON.parse(Buffer.from(invokeRes.Payload).toString('utf8'));
  if (invokeRes.FunctionError || payload.errorMessage) {
    throw new Error(`il-central-1 caller failed: ${payload.errorMessage || invokeRes.FunctionError}`);
  }

  return payload.contracts; // [{ contract, reading, capacity }]
}

// -------------------------------------------------------------------------------------
// Schema Connector
// -------------------------------------------------------------------------------------
const connector = new SchemaConnector()
  .enableEventLogging(2)
  .discoveryHandler(async (accessToken, response) => {
    const accounts = await loadIecAccount(accessToken);

    for (const { contract, capacity } of accounts) {
      const label = `IEC Meter - ${contract.address || contract.contractId}`;
      response
        .addDevice(contract.contractId, label, DEVICE_PROFILE_ID)
        .manufacturerName('Israel Electric Corporation')
        .modelName(capacity ? `Meter (${capacity.label})` : contract.smartMeter ? 'Smart Meter' : 'Meter')
        .roomName('');
    }
  })
  .stateRefreshHandler(async (accessToken, response) => {
    const accounts = await loadIecAccount(accessToken);

    for (const { contract, reading, capacity } of accounts) {
      const device = response.addDevice(contract.contractId);
      const component = device.addComponent('main');

      if (reading && reading.reading != null) {
        // energyMeter's "energy" attribute is defined in kWh - IEC's reading values are already that unit.
        component.addState('st.energyMeter', 'energy', reading.reading, 'kWh');
        component.addState('st.healthCheck', 'healthStatus', 'online');
        component.addState(METER_READING_WH_CAPABILITY, 'value', formatWh(reading.reading));

        const usage = await computeUsageDeltas(contract.contractId, reading.reading).catch(() => ({ daily: null, weekly: null, monthly: null }));
        component.addState(DAILY_USAGE_CAPABILITY, 'value', formatUsage(usage.daily, 'since 7AM'));
        component.addState(WEEKLY_USAGE_CAPABILITY, 'value', formatUsage(usage.weekly, 'since Sun 7AM'));
        component.addState(MONTHLY_USAGE_CAPABILITY, 'value', formatUsage(usage.monthly, 'since 1st 7AM'));
      } else {
        // No reading available (e.g. account has no smart meter yet, or IEC is lagging -
        // per their own docs this can be delayed up to ~2 days) - report offline rather
        // than guessing a value.
        component.addState('st.healthCheck', 'healthStatus', 'offline');
      }

      if (capacity) {
        component.addState(CONNECTION_CAPACITY_CAPABILITY, 'capacity', `${capacity.phase}-phase, ${capacity.size}A (${capacity.label})`);
      }

      component.addState(METER_TYPE_CAPABILITY, 'value', contract.smartMeter ? 'Smart Meter' : 'Normal Meter');

      const rate = await getRate(contract.contractId).catch(() => DEFAULT_ENERGY_RATE);
      component.addState(ENERGY_RATE_CAPABILITY, 'rate', rate, 'ILS/kWh');
    }
  })
  .integrationDeletedHandler(async (accessToken) => {
    // Best-effort cleanup; the TOKEN#/REFRESH# items also expire on their own via TTL.
    try {
      await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { pk: `TOKEN#${accessToken}` } }));
    } catch (e) {
      console.error('Cleanup failed', e);
    }
  })
  .commandHandler(async (accessToken, response, devices) => {
    for (const device of devices) {
      const { externalDeviceId, commands } = device;
      const resultStates = [];

      for (const cmd of commands) {
        const { capability, command, arguments: cmdArgs } = cmd;
        const value = cmdArgs && cmdArgs[0];

        try {
          if (capability === ENERGY_RATE_CAPABILITY && command === 'setRate') {
            await setRate(externalDeviceId, value);
            resultStates.push({ component: 'main', capability, attribute: 'rate', value, unit: 'ILS/kWh' });
          }
        } catch (err) {
          console.error(`Command ${command} failed for ${externalDeviceId}:`, err.message);
        }
      }

      response.addDevice(externalDeviceId, resultStates);
    }
  });

exports.handler = async (event, context) => {
  await connector.handleLambdaCallback(event, context);
};
