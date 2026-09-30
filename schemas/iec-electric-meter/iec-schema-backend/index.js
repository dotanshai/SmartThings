'use strict';

const { SchemaConnector, StateUpdateRequest } = require('st-schema');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand, ScanCommand } = require('@aws-sdk/lib-dynamodb');
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

// Needed only for proactive state callbacks (pushing updates to SmartThings the moment we
// see new IEC data, rather than waiting for their next scheduled poll of us). Same Schema App
// client ID/secret used throughout - set as env vars on this Lambda (not hardcoded, since it's
// a real secret) via deploy.ps1 or the AWS console.
const ST_CLIENT_ID = process.env.ST_CLIENT_ID;
const ST_CLIENT_SECRET = process.env.ST_CLIENT_SECRET;

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
const ENERGY_RATE_CAPABILITY = 'vehiclepatch55148.iecEnergyRate3'; // v3: shekel symbol in unit (in-place update to v2's enum didn't propagate to platform validation - known caching quirk, needed a genuinely new capability again)
const DEFAULT_ENERGY_RATE = 0.61; // rough placeholder (approx IEC low-voltage home rate) until the user sets their own

// User-editable display language for our own generated content (period labels, meter type,
// connection capacity phrasing). This is separate from - and doesn't affect - the card TITLES
// (e.g. "Daily Usage"), which already auto-translate via capability translations tied to the
// SmartThings account's own language. This only covers the dynamic VALUE text we generate.
const LANGUAGE_CAPABILITY = 'vehiclepatch55148.iecLanguage';
const DEFAULT_LANGUAGE = 'en';

const TRANSLATIONS = {
  en: {
    yesterday: 'yesterday',
    lastWeek: 'last week',
    lastMonth: 'last month',
    buildingHistory: 'Building history...',
    smartMeter: 'Smart Meter',
    normalMeter: 'Normal Meter',
    kwh: 'kWh',
    currency: 'NIS',
    rateUnit: 'ILS/kWh',
    phase: (n) => `${n}-phase`,
    amps: (n) => `${n}A`,
  },
  he: {
    yesterday: 'אתמול',
    lastWeek: 'השבוע שעבר',
    lastMonth: 'החודש שעבר',
    buildingHistory: 'אוסף נתונים...',
    smartMeter: 'מונה חכם',
    normalMeter: 'מונה רגיל',
    kwh: 'קוט"ש',
    currency: 'ש"ח',
    rateUnit: '₪/קוט"ש',
    // Hebrew fallback for other phase counts.
    phase: (n) => (Number(n) === 1 ? 'חד פאזי' : Number(n) === 3 ? 'תלת פאזי' : `${n}-פאזי`),
    amps: (n) => `${n} אמפר`,
  },};

function t(language) {
  return TRANSLATIONS[language] || TRANSLATIONS[DEFAULT_LANGUAGE];
}

// Mixing Hebrew text with numbers/punctuation (׳³ֲ³ײ²ֲ²׳²ֲ²ײ²ֲ²׳³ֲ²ײ²ֲ²׳²ֲ²ײ²ֲ·, quotes, slashes, parens) can get visually
// reordered by the RTL bidi algorithm in ways that don't match the order written here -
// wrapping in Unicode RTL isolate marks (U+2067/U+2069) keeps the internal layout as authored
// regardless of the surrounding app's text direction. No-op for English.
// Mixing text with numbers/punctuation (׳³ֲ³ײ²ֲ²׳²ֲ²ײ²ֲ²׳³ֲ²ײ²ֲ²׳²ֲ²ײ²ֲ·, quotes, hyphens, parens) can get visually
// reordered by the RTL bidi algorithm - and this isn't only a risk for Hebrew content.
// Confirmed in practice: a user with our language toggle set to English, but a Hebrew-
// language phone/app, saw "3-phase, 25A (3X25)" rendered as "phase, 25A (3X25)-3" - the
// surrounding app UI's RTL direction depends on the phone's own locale, not our internal
// toggle, so English content needs isolating too, just with the opposite (LTR) direction.
function bidiSafe(text, language) {
  const LRM = '\u200E'; // Left-to-Right Mark
  const RLM = '\u200F'; // Right-to-Left Mark
    const mark = language === 'he' ? RLM : LRM;
  return `${mark}${text}${mark}`;
}

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

// Most recent Sunday 7:00 Israel time at or before `now` - the start of the "current week".
function weekBoundary(now) {
  const p = israelParts(now);
  const daysSinceSunday = WEEKDAY_INDEX[p.weekday];
  let boundary = israelLocalToUtc(p.year, p.month, p.day - daysSinceSunday, 2);
  if (boundary > now) boundary = israelLocalToUtc(p.year, p.month, p.day - daysSinceSunday - 7, 2);
  return boundary;
}

// Most recent 1st-of-month 7:00 Israel time at or before `now` - the start of the "current month".
function monthBoundary(now) {
  const p = israelParts(now);
  let boundary = israelLocalToUtc(p.year, p.month, 1, 2);
  if (boundary > now) {
    const prevMonth = p.month === 1 ? 12 : p.month - 1;
    const prevYear = p.month === 1 ? p.year - 1 : p.year;
    boundary = israelLocalToUtc(prevYear, prevMonth, 1, 2);
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
// exact boundary moment itself, just the closest we actually have data for).
function isMorningAnchorWindow(now) {
  const fmt = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Jerusalem', hour: '2-digit', minute: '2-digit', hour12: false });
  const parts = {};
  fmt.formatToParts(now).forEach((p) => { parts[p.type] = p.value; });
  const minutesOfDay = parseInt(parts.hour, 10) * 60 + parseInt(parts.minute, 10);
  return minutesOfDay >= 5 * 60 + 30 && minutesOfDay < 8 * 60 + 30;
}

function earliestReadingAtOrAfter(history, boundary) {
  const sorted = [...history].sort((a, b) => new Date(entryTimestamp(a)) - new Date(entryTimestamp(b)));
  return sorted.find((h) => new Date(entryTimestamp(h)) >= boundary) || null;
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

// Proactive callback credentials - captured once by callbackAccessHandler, then reused any
// time we want to push an update to SmartThings ourselves rather than waiting for their next
// poll. Keyed by accessToken since that's what callbackAccessHandler (and every other handler)
// receives - we don't get externalDeviceId/contractId at that point, only later when we
// actually poll IEC via loadIecAccount(accessToken).
async function saveCallbackCredentials(accessToken, callbackAuthentication, callbackUrls) {
  await ddb.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: `CALLBACK#${accessToken}`, callbackAuthentication, callbackUrls, savedAt: new Date().toISOString() },
  }));
}

async function deleteCallbackCredentials(accessToken) {
  await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { pk: `CALLBACK#${accessToken}` } }));
}

// Every stored accessToken that has proactive callback credentials - i.e. every installation
// that's opted into push updates. Used by the scheduled poll to know who to check.
// Uses a table Scan (filtering client-side by key prefix) rather than a Query, since this
// table's primary key isn't structured for an efficient prefix query - fine at this group's
// current scale (a few dozen installs), but would need a proper GSI if this grows much larger.
async function getAllCallbackAccessTokens() {
  const results = [];
  let ExclusiveStartKey;
  do {
    const page = await ddb.send(new ScanCommand({
      TableName: TABLE,
      FilterExpression: 'begins_with(pk, :prefix)',
      ExpressionAttributeValues: { ':prefix': 'CALLBACK#' },
      ExclusiveStartKey,
    }));
    for (const item of page.Items || []) {
      results.push({
        accessToken: item.pk.replace('CALLBACK#', ''),
        callbackAuthentication: item.callbackAuthentication,
        callbackUrls: item.callbackUrls,
      });
    }
    ExclusiveStartKey = page.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return results;
}

// Fallback for when a poll genuinely fails to get a fresh reading from IEC (a transient API
// blip, temporary lag, etc.) - rather than immediately flashing "offline" for every single
// failed poll, use the last known good reading if it's recent enough to still be trustworthy.
// Read-only - doesn't write anything, so it can't corrupt the real history or interfere with
// the next successful poll's own today-entry logic.
async function getMostRecentEntry(contractId) {
  const history = await getReadingHistory(contractId);
  if (!history.length) return null;
  const sorted = [...history].sort((a, b) => new Date(entryTimestamp(a)) - new Date(entryTimestamp(b)));
  return { entry: sorted[sorted.length - 1], history };
}

async function getLastKnownReading(contractId, maxAgeHours = 48) {
  const recent = await getMostRecentEntry(contractId);
  if (!recent) return null;
  const ageMs = Date.now() - new Date(entryTimestamp(recent.entry)).getTime();
  if (ageMs > maxAgeHours * 3600 * 1000) return null; // too old to still call "current"
  return { reading: recent.entry.reading, history: recent.history };
}

// Sanity-check a new reading against the last known good one before trusting it. IEC's own
// API has been observed to occasionally return a wildly wrong value for a single poll -
// confirmed in practice: one account briefly showed 84,367 kWh instead of ~2,850 kWh, a
// physically impossible jump. Rather than guessing at an arbitrary "too big" threshold, use
// the account's own connection capacity (amps + phase, which we already know) to compute the
// actual physical ceiling on how much power that connection could ever deliver, then check
// whether the implied power draw between the two readings exceeds that - with a generous
// safety margin, since this is meant to catch obviously-broken data, not flag genuinely heavy
// but real usage.
function isPlausibleReading(newReading, recentEntry, capacity, now) {
  if (!recentEntry) return true; // nothing to compare against yet - can't evaluate, don't block
  const deltaKwh = newReading - recentEntry.reading;
  const hoursElapsed = (now - new Date(entryTimestamp(recentEntry))) / 3600000;
  if (hoursElapsed <= 0) return true; // clock oddity - don't block on it, not what this guards against
  const impliedKw = Math.abs(deltaKwh) / hoursElapsed;

  const VOLTS = 230;
  const SAFETY_MARGIN = 2; // generous - catches obviously-broken data, not heavy-but-real days
  let maxPlausibleKw = 50; // fallback ceiling if capacity info isn't available at all
  if (capacity && capacity.size) {
    const amps = Number(capacity.size);
    const phase = Number(capacity.phase) || 1;
    const theoreticalKw = (phase === 3 ? Math.sqrt(3) : 1) * VOLTS * amps / 1000;
    maxPlausibleKw = theoreticalKw * SAFETY_MARGIN;
  }
  return impliedKw <= maxPlausibleKw;
}

// The boundary immediately before a given one, using the same boundary function - i.e. "one
// full period earlier". E.g. priorBoundary(weekBoundary, thisWeeksBoundary) = last week's boundary.
function priorBoundary(boundaryFn, boundary) {
  return boundaryFn(new Date(boundary.getTime() - 1));
}

// Usage over the most recently *completed* period (yesterday/last week/last month), not a
// live "so far this period" figure - matches how a utility bill reports a fixed prior total,
// and only changes once per period when a new boundary is crossed, rather than growing on
// every refresh. Computed as (reading at the start of the current period) - (reading at the
// start of the period before that) - both are past, completed boundaries, so this works
// identically for daily/weekly/monthly despite daily only having one snapshot per calendar day.
// How close to a period's true start we need a real reading to trust it as genuinely
// representing that period's beginning - not just the earliest thing we happen to have. Used
// by both periodDelta (weekly/monthly) and dailyYesterday, so a partial/incomplete period
// (e.g. the very first month ever tracked, where history didn't reach back to that month's
// actual 1st) shows "Building history..." rather than a real but understated number.
const PERIOD_START_TOLERANCE_MS = 48 * 3600 * 1000;
const DAILY_GAP_TOLERANCE_MS = 72 * 3600 * 1000; // more forgiving than week/month - a single missed poll day shouldn't block daily usage

function periodDelta(history, boundaryFn, now) {
  const end = boundaryFn(now);
  const start = priorBoundary(boundaryFn, end);
  const endReading = earliestReadingAtOrAfter(history, end);
  const startReading = earliestReadingAtOrAfter(history, start);
  if (!endReading || !startReading) return null;
  // If the "start" search landed on the same (or a later) reading as the "end" search, there's
  // no real data actually within the period - e.g. history only goes back a few days but we're
  // asking about a month-old boundary. Report as not-yet-available rather than a false 0.
  if (new Date(entryTimestamp(startReading)) >= end) return null;
  // Only trust this as genuinely covering the whole period if we actually have a reading
  // close to when it began - not just the earliest thing available, which could be from
  // partway through if our own tracking started mid-period. Prefer "still collecting data"
  // over a real but silently-partial (understated) total.
  if (new Date(entryTimestamp(startReading)) - start > PERIOD_START_TOLERANCE_MS) return null;
  return endReading.reading - startReading.reading;
}

// Records weekly/monthly usage for the most recently completed period. Weekly resets Sunday
// 7:00 Israel time; monthly resets the 1st at 7:00 - real calendar boundaries.
// Daily needs its own logic, separate from weekly/monthly's boundary search. Because we only
// keep ONE stored entry per calendar day (continuously overwritten as today's polls come in),
// the boundary-search approach used for weekly/monthly would end up comparing TODAY's still-
// growing reading against yesterday's fixed one - silently including part of today's ongoing
// usage in what's labeled "yesterday", so the number would keep climbing all day instead of
// staying fixed. This never touches today's entry at all - only the two most recent COMPLETED
// past days - so it's genuinely fixed until tomorrow, and gracefully tolerates a data gap
// (e.g. a missed poll) the same way, just by using whichever two past days are most recent.
function dailyYesterday(history, now) {
  const today = todayIso(now);
  const pastDays = history
    .filter((h) => h.date !== today)
    .sort((a, b) => (a.date < b.date ? -1 : 1));
  if (pastDays.length < 2) return null;
  const yesterday = pastDays[pastDays.length - 1];
  const dayBefore = pastDays[pastDays.length - 2];
  // If these two readings are more than ~a day apart (a missed poll left a gap), the result
  // would actually span more than one real day - not genuinely "yesterday". Prefer "still
  // collecting data" over a real but mislabeled/inflated number.
  const gapMs = new Date(entryTimestamp(yesterday)) - new Date(entryTimestamp(dayBefore));
  if (gapMs > DAILY_GAP_TOLERANCE_MS) return null;
  const daySpan = Math.max(1, Math.round(gapMs / (24 * 3600 * 1000))); return { value: (yesterday.reading - dayBefore.reading) / daySpan, daySpan };
}

async function computeUsageDeltas(contractId, currentReading) {
  const now = new Date();
  let history = await getReadingHistory(contractId);
  const today = todayIso(now);

  const last = history[history.length - 1];
  if (last && last.date === today) {
    if (!last.anchored) { last.reading = currentReading; if (isMorningAnchorWindow(now)) last.anchored = true;
    last.timestamp = now.toISOString(); }
  } else {
    history.push({ date: today, reading: currentReading, timestamp: now.toISOString(), anchored: isMorningAnchorWindow(now) });
  }
  history.sort((a, b) => new Date(entryTimestamp(a)) - new Date(entryTimestamp(b)));
  await saveReadingHistory(contractId, history);

  return {
    daily: dailyYesterday(history, now),
    weekly: periodDelta(history, weekBoundary, now),
    monthly: periodDelta(history, monthBoundary, now),
  };
}

// The daily/weekly/monthly capabilities' value field has a hard 32-character limit (set when
// they were first created) - this format is deliberately compact (whole kWh, no parens/bullet)
// to reliably fit both languages even at large numbers, since Hebrew words run longer and the
// RTL isolate marks add 2 more characters on top.
function formatUsage(kwh, periodKey, rate, language, daySpan) {
  const dict = t(language);
  if (kwh == null) return dict.buildingHistory;
  const periodLabel = periodKey ? dict[periodKey] : null;
  // Rounded to whole shekels intentionally - this is an estimate off a user-entered flat
  // rate, not a real bill (no tiered/time-of-use pricing, no VAT nuance) - showing false
  // decimal precision would overstate how accurate it actually is.
  // Solar/net-metered accounts can have a genuinely negative delta (exported more than
  // imported) - put the minus sign before the ׳³ֲ³ײ²ֲ³׳³ג€™׳’ג€ֲ¬׳’ג€ֲ¢׳³ֲ³׳’ג‚¬ג„¢׳³ג€™׳’ג‚¬ֲײ²ֲ¬׳²ֲ²ײ²ֲ׳³ֲ²ײ²ֲ³׳³ג€™׳’ג€ֲ¬׳’ג‚¬ֲ symbol (-׳³ֲ³ײ²ֲ³׳³ג€™׳’ג€ֲ¬׳’ג€ֲ¢׳³ֲ³׳’ג‚¬ג„¢׳³ג€™׳’ג‚¬ֲײ²ֲ¬׳²ֲ²ײ²ֲ׳³ֲ²ײ²ֲ³׳³ג€™׳’ג€ֲ¬׳’ג‚¬ֲ26) rather than after it (׳³ֲ³ײ²ֲ³׳³ג€™׳’ג€ֲ¬׳’ג€ֲ¢׳³ֲ³׳’ג‚¬ג„¢׳³ג€™׳’ג‚¬ֲײ²ֲ¬׳²ֲ²ײ²ֲ׳³ֲ²ײ²ֲ³׳³ג€™׳’ג€ֲ¬׳’ג‚¬ֲ-26)
  // so it reads naturally instead of looking like a stray hyphen next to the currency mark.
  let costPart = '';
  if (rate != null) {
    const cost = Math.round(kwh * rate);
    costPart = cost < 0 ? ` -${Math.abs(cost)} ${dict.currency}` : ` ${cost} ${dict.currency}`;
  }
  const result = periodLabel
    ? `${Math.round(kwh)} ${dict.kwh} ${periodLabel}${costPart}`
    : `${Math.round(kwh)} ${dict.kwh}${costPart}`;
  return bidiSafe(daySpan > 1 ? result + ' (' + daySpan + 'd avg)' : result, language);
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

async function getLanguage(contractId) {
  const item = await ddb.send(new GetCommand({ TableName: TABLE, Key: { pk: `LANG#${contractId}` } }));
  return (item.Item && item.Item.language) || DEFAULT_LANGUAGE;
}

async function setLanguage(contractId, value) {
  await ddb.send(new PutCommand({ TableName: TABLE, Item: { pk: `LANG#${contractId}`, language: value } }));
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

// Builds the full state array for one contract - shared by the regular stateRefreshHandler
// response and the proactive push path, so both stay in sync (plausibility check, last-known-
// reading fallback, translations, bidi handling) rather than maintaining two copies. Returns
// a plain array of {component, capability, attribute, value, unit?} objects.
async function buildContractStates(contract, reading, capacity) {
  const states = [];
  const rate = await getRate(contract.contractId).catch(() => DEFAULT_ENERGY_RATE);
  const language = await getLanguage(contract.contractId).catch(() => DEFAULT_LANGUAGE);
  const dict = t(language);

  let effectiveReading = null;
  if (reading && reading.reading != null) {
    const recent = await getMostRecentEntry(contract.contractId).catch(() => null);
    if (isPlausibleReading(reading.reading, recent && recent.entry, capacity, new Date())) {
      effectiveReading = reading.reading;
    } else {
      console.error(`Implausible reading rejected for ${contract.contractId}: got ${reading.reading}, last known was ${recent && recent.entry.reading}`);
    }
  }

  if (effectiveReading != null) {
    // energyMeter's "energy" attribute is defined in kWh - IEC's reading values are already that unit.
    states.push({ component: 'main', capability: 'st.energyMeter', attribute: 'energy', value: effectiveReading, unit: 'kWh' });
    states.push({ component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: 'online' });
    states.push({ component: 'main', capability: METER_READING_WH_CAPABILITY, attribute: 'value', value: formatWh(effectiveReading) });

    const usage = await computeUsageDeltas(contract.contractId, effectiveReading).catch(() => ({ daily: null, weekly: null, monthly: null }));
    states.push({ component: 'main', capability: DAILY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(usage.daily && usage.daily.value, 'yesterday', rate, language, usage.daily && usage.daily.daySpan) });
    states.push({ component: 'main', capability: WEEKLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(usage.weekly, 'lastWeek', rate, language) });
    states.push({ component: 'main', capability: MONTHLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(usage.monthly, 'lastMonth', rate, language) });
  } else {
    // No fresh, trustworthy reading this poll (either genuinely missing, or rejected by the
    // plausibility check above) - before reporting offline, check if we have a recent enough
    // cached reading to fall back to. This makes a single transient IEC/network blip - or a
    // single bad reading - invisible rather than flashing offline or showing garbage until
    // the next poll. Genuinely offline (or IEC lagging beyond the tolerance window) still
    // reports as such.
    const fallback = await getLastKnownReading(contract.contractId).catch(() => null);
    if (fallback) {
      states.push({ component: 'main', capability: 'st.energyMeter', attribute: 'energy', value: fallback.reading, unit: 'kWh' });
      states.push({ component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: 'online' });
      states.push({ component: 'main', capability: METER_READING_WH_CAPABILITY, attribute: 'value', value: formatWh(fallback.reading) });

      const nowTs = new Date();
      const daily = dailyYesterday(fallback.history, nowTs);
      const weekly = periodDelta(fallback.history, weekBoundary, nowTs);
      const monthly = periodDelta(fallback.history, monthBoundary, nowTs);
      states.push({ component: 'main', capability: DAILY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(daily && daily.value, 'yesterday', rate, language, daily && daily.daySpan) });
      states.push({ component: 'main', capability: WEEKLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(weekly, 'lastWeek', rate, language) });
      states.push({ component: 'main', capability: MONTHLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(monthly, 'lastMonth', rate, language) });
    } else {
      states.push({ component: 'main', capability: 'st.healthCheck', attribute: 'healthStatus', value: 'offline' });
    }
  }

  if (capacity) {
    const capacityText = `${dict.phase(capacity.phase)}, ${dict.amps(capacity.size)} (${capacity.label})`;
    states.push({ component: 'main', capability: CONNECTION_CAPACITY_CAPABILITY, attribute: 'capacity', value: bidiSafe(capacityText, language) });
  }

  states.push({ component: 'main', capability: METER_TYPE_CAPABILITY, attribute: 'value', value: contract.smartMeter ? dict.smartMeter : dict.normalMeter });
  // Unit is locked to this exact enum value by the capability's own schema (defined at
  // creation time) - can't be translated without a capability version bump. Must match exactly
  // - no bidi wrapping.
  states.push({ component: 'main', capability: ENERGY_RATE_CAPABILITY, attribute: 'rate', value: rate, unit: dict.rateUnit });
  states.push({ component: 'main', capability: LANGUAGE_CAPABILITY, attribute: 'language', value: language });

  return states;
}

// -------------------------------------------------------------------------------------
// Schema Connector
// -------------------------------------------------------------------------------------
const connector = new SchemaConnector()
  .clientId(ST_CLIENT_ID)
  .clientSecret(ST_CLIENT_SECRET)
  .enableEventLogging(2)
  .discoveryHandler(async (accessToken, response) => {
    const accounts = await loadIecAccount(accessToken);

    for (const { contract, reading, capacity } of accounts) {
      // Skip contracts with no real reading available (old addresses, closed contracts still
      // attached to the account's bpNumber, etc.) - same check stateRefreshHandler already
      // uses to decide online/offline, just applied before the device gets created at all,
      // so these never show up rather than showing up offline and needing manual removal.
      if (!reading || reading.reading == null) continue;

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
      const states = await buildContractStates(contract, reading, capacity);
      for (const s of states) {
        component.addState(s.capability, s.attribute, s.value, s.unit);
      }
    }
  })
  .integrationDeletedHandler(async (accessToken) => {
    // Best-effort cleanup; the TOKEN#/REFRESH# items also expire on their own via TTL.
    try {
      await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { pk: `TOKEN#${accessToken}` } }));
      await deleteCallbackCredentials(accessToken);
    } catch (e) {
      console.error('Cleanup failed', e);
    }
  })
  .callbackAccessHandler(async (accessToken, callbackAuthentication, callbackUrls) => {
    // Fires once per installation, giving us what we need to push proactive updates to
    // SmartThings ourselves later, rather than only ever responding to their own polls.
    try {
      await saveCallbackCredentials(accessToken, callbackAuthentication, callbackUrls);
    } catch (e) {
      console.error('Failed to save callback credentials', e);
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
            const language = await getLanguage(externalDeviceId).catch(() => DEFAULT_LANGUAGE);
            resultStates.push({ component: 'main', capability, attribute: 'rate', value, unit: t(language).rateUnit });

            // Give instant feedback on the cost figures too, rather than making the user
            // wait for the next full state refresh - reuses already-stored reading history,
            // no new IEC/Okta call needed for this.
            const now = new Date();
            const history = await getReadingHistory(externalDeviceId).catch(() => []);
            const daily = dailyYesterday(history, now);
            const weekly = periodDelta(history, weekBoundary, now);
            const monthly = periodDelta(history, monthBoundary, now);
            resultStates.push({ component: 'main', capability: DAILY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(daily && daily.value, 'yesterday', value, language, daily && daily.daySpan) });
            resultStates.push({ component: 'main', capability: WEEKLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(weekly, 'lastWeek', value, language) });
            resultStates.push({ component: 'main', capability: MONTHLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(monthly, 'lastMonth', value, language) });
          }

          if (capability === LANGUAGE_CAPABILITY && command === 'setLanguage') {
            await setLanguage(externalDeviceId, value);
            resultStates.push({ component: 'main', capability, attribute: 'language', value });

            // Instant feedback for the daily/weekly/monthly labels and rate unit too, same
            // pattern as setRate above. Meter type and connection capacity aren't re-rendered
            // here since we don't cache the raw contract data (smartMeter flag, capacity)
            // between real IEC calls - those two will pick up the new language on the next
            // full refresh rather than instantly, a small known gap rather than adding a
            // second cache.
            const rate = await getRate(externalDeviceId).catch(() => DEFAULT_ENERGY_RATE);
            resultStates.push({ component: 'main', capability: ENERGY_RATE_CAPABILITY, attribute: 'rate', value: rate, unit: t(value).rateUnit });
            const now = new Date();
            const history = await getReadingHistory(externalDeviceId).catch(() => []);
            const daily = dailyYesterday(history, now);
            const weekly = periodDelta(history, weekBoundary, now);
            const monthly = periodDelta(history, monthBoundary, now);
            resultStates.push({ component: 'main', capability: DAILY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(daily && daily.value, 'yesterday', rate, value, daily && daily.daySpan) });
            resultStates.push({ component: 'main', capability: WEEKLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(weekly, 'lastWeek', rate, value) });
            resultStates.push({ component: 'main', capability: MONTHLY_USAGE_CAPABILITY, attribute: 'value', value: formatUsage(monthly, 'lastMonth', rate, value) });
          }
        } catch (err) {
          console.error(`Command ${command} failed for ${externalDeviceId}:`, err.message);
        }
      }

      response.addDevice(externalDeviceId, resultStates);
    }
  });

exports.handler = async (event, context) => {
  // Distinguish a real ST Schema HTTP callback (has an "authentication" or "interactionType"
  // body shape) from an EventBridge scheduled trigger (has a "source": "aws.events" shape) -
  // same Lambda, two different jobs. Keeping both in one function avoids a second deployment
  // pipeline for what's a small amount of additional code.
  if (event.source === 'aws.events') {
    return checkForUpdatesAndPush();
  }
  await connector.handleLambdaCallback(event, context);
};

// Proactive push: checks every installation that's opted into callbacks (i.e. completed the
// OAuth flow that triggers callbackAccessHandler) for a changed reading, and if found, pushes
// the update to SmartThings immediately via StateUpdateRequest - rather than waiting for
// SmartThings' own next scheduled poll of us. Triggered on a schedule (EventBridge), not by
// SmartThings itself. Still bounded by how often IEC's own data actually changes - this makes
// us notice and push a change the moment we see it, not make IEC publish data any faster.
async function checkForUpdatesAndPush() {
  if (!ST_CLIENT_ID || !ST_CLIENT_SECRET) {
    console.error('ST_CLIENT_ID/ST_CLIENT_SECRET not set - cannot push proactive updates');
    return;
  }

  const registrations = await getAllCallbackAccessTokens().catch((e) => {
    console.error('Failed to list callback registrations', e);
    return [];
  });

  for (const { accessToken, callbackAuthentication, callbackUrls } of registrations) {
    try {
      const accounts = await loadIecAccount(accessToken);
      const deviceStates = [];

      for (const { contract, reading, capacity } of accounts) {
        // Skip pushing if the reading hasn't actually changed since we last recorded it -
        // no point notifying SmartThings of "new" data that isn't actually new. Usage/cost
        // figures can still shift day-to-day even with the same reading (a new boundary
        // crossing), so this is deliberately just checking the raw meter reading, the
        // clearest, cheapest signal that something genuinely changed.
        const recent = await getMostRecentEntry(contract.contractId).catch(() => null);
        const readingChanged = reading && reading.reading != null
          && (!recent || recent.entry.reading !== reading.reading);
        if (!readingChanged) continue;

        const states = await buildContractStates(contract, reading, capacity);
        deviceStates.push({ externalDeviceId: contract.contractId, states });
      }

      if (deviceStates.length) {
        const updateRequest = new StateUpdateRequest(ST_CLIENT_ID, ST_CLIENT_SECRET);
        await updateRequest.updateState(callbackUrls, callbackAuthentication, deviceStates);
        console.log(`Pushed proactive update for ${deviceStates.length} device(s), accessToken ending ...${accessToken.slice(-6)}`);
      }
    } catch (e) {
      // One installation's failure (expired callback token, IEC error, etc.) shouldn't stop
      // the rest of the group from getting checked.
      console.error(`Proactive check failed for accessToken ending ...${accessToken.slice(-6)}:`, e.message);
    }
  }
}

