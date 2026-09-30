// OAuth handling for the Schema Connector, behind API Gateway.
// Two DIFFERENT OAuth relationships are chained here:
//
//  1. Schema OAuth: SmartThings is the CLIENT, WE are the SERVER.
//     (GET/POST /authorize, POST /token below) - lets SmartThings call our
//     webhook Lambda with a bearer token.
//
//  2. OAuth-In: WE are the CLIENT, SmartThings is the SERVER.
//     (GET /oauth-in-callback below) - lets US call the SmartThings API
//     to resolve the installing location's lat/long automatically.
//     Requires a SEPARATE app registration of type OAuth-In in the
//     Developer Workspace (its own client_id/client_secret), because the
//     Schema app's credentials only cover relationship #1.
//
// Full user-facing flow:
//   GET  /authorize          -> offset entry form (candle/havdalah minutes)
//   POST /authorize (step=offsets) -> stores offsets, sends browser to
//                                     SmartThings' own OAuth to resolve location
//   GET  /oauth-in-callback  -> resolves location, lists any fridge devices
//                               that support samsungce.sabbathMode, shows a
//                               fridge-picker screen (skippable)
//   POST /authorize (step=fridge)  -> stores fridge choice, computes this
//                                     week's real times, shows a confirmation
//                                     screen
//   POST /authorize (step=confirm) -> finalizes, redirects back to SmartThings
//   POST /token               -> SmartThings exchanges the code for a token
//
// Reopening the invite link later re-runs this whole flow, which is the
// supported way to change offsets or the fridge selection - handleToken()
// detects a returning locationId and updates the existing device record
// instead of creating a duplicate.
//
// The OAuth-In token obtained in the callback is now PERSISTED on the
// install record (not just used transiently to look up the location),
// because sending the actual samsungce.sabbathMode command later from the
// trigger Lambda requires a token with x:devices:* scope. This means one
// re-authorization covers both the picker and future fridge control - no
// separate re-auth needed down the line. The OAuth-In app's registered
// scope must include r:devices:* and x:devices:* (added 2026-08 alongside
// r:locations:*) for this to work; existing installs need to reopen the
// invite link once to pick up device access.
//
// Env vars needed:
//   INSTALLS_TABLE, CODES_TABLE
//   OAUTH_IN_CLIENT_ID, OAUTH_IN_CLIENT_SECRET, OAUTH_IN_REDIRECT_URI
//     (OAUTH_IN_REDIRECT_URI must be this Lambda's /oauth-in-callback URL,
//      registered exactly on the OAuth-In app record)
//   CANDLE_BASE_OFFSET_MIN (default 18), HAVDALAH_BASE_OFFSET_MIN (default 42)

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, PutCommand, GetCommand, DeleteCommand, ScanCommand } = require('@aws-sdk/lib-dynamodb');
const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');
const lambdaClient = new LambdaClient({});
const crypto = require('crypto');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.INSTALLS_TABLE;
const CODES_TABLE = process.env.CODES_TABLE;
const CANDLE_BASE_OFFSET_MIN = parseInt(process.env.CANDLE_BASE_OFFSET_MIN || '18', 10);
const HAVDALAH_BASE_OFFSET_MIN = parseInt(process.env.HAVDALAH_BASE_OFFSET_MIN || '42', 10);

// SmartThings' /authorize call encodes several colon-separated fields
// inside the JWT payload of the `state` param: locationId(unused),
// installedSchemaAppId, timestamp, a hex id, then the LOCALE (e.g.
// "en-US" or "he-IL"), then some trailing flags. We use the locale to
// generate content (location name, time formatting) in the installer's
// own language instead of hardcoding Hebrew.
function decodeStateInfo(state) {
  if (!state) return null;
  try {
    const payloadSegment = state.split('.')[1];
    const padded = payloadSegment + '='.repeat((4 - (payloadSegment.length % 4)) % 4);
    return Buffer.from(padded, 'base64url').toString('utf-8');
  } catch (err) {
    console.error(`Failed to decode state payload: ${err.message}`);
    return null;
  }
}

function extractLocale(state) {
  const decoded = decodeStateInfo(state);
  if (!decoded) return 'en-US';
  const parts = decoded.split(':');
  // Locale looks like "en-US" or "he-IL" - find the field matching that shape
  const localeField = parts.find((p) => /^[a-z]{2}-[A-Z]{2}$/.test(p));
  return localeField || 'en-US';
}

exports.handler = async (event) => {
  const method = event.requestContext.http.method;
  const path = event.rawPath;
  console.log(`${method} ${path} isBase64Encoded=${event.isBase64Encoded} contentType=${event.headers && event.headers['content-type']}`);

  if (method === 'GET' && path.endsWith('/authorize')) return renderOffsetForm(event);
  if (method === 'POST' && path.endsWith('/authorize')) return handleAuthorizePost(event);
  if (method === 'POST' && path.endsWith('/token')) return handleToken(event);
  if (method === 'GET' && path.endsWith('/oauth-in-callback')) return handleOAuthInCallback(event);
  console.warn(`No route matched for ${method} ${path}`);
  return { statusCode: 404, body: 'Not found' };
};

// Reverse-geocodes lat/long into a human-readable "City, Country" string
// using OpenStreetMap's free Nominatim service (no API key needed). Called
// once per install/reconfigure, not on every state update, to stay well
// within Nominatim's usage policy (max ~1 request/second, valid User-Agent
// required).
async function reverseGeocode(latitude, longitude, locale) {
  try {
    const lang = (locale || 'en-US').split('-')[0];
    const url = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${latitude}&lon=${longitude}&zoom=10&addressdetails=1&accept-language=${lang}`;
    const res = await fetch(url, {
      headers: { 'User-Agent': 'ShabbatSwitchSchemaConnector/1.0 (SmartThings community integration)' },
    });
    if (!res.ok) {
      console.error(`Nominatim reverse geocode failed: HTTP ${res.status}`);
      return null;
    }
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

// ---- Fetch devices at this location that support samsungce.sabbathMode.
// Filtering by capability (rather than device type/name) means the picker
// only ever shows fridges that genuinely expose the feature via the API -
// on some models (e.g. certain Dacor units) the capability is present but
// disabled server-side and won't appear here at all, which is the correct
// behavior since commanding it would fail anyway.
//
// Samsung's own device profiles have been observed to bundle this
// capability onto unrelated appliances (e.g. a robot vacuum) even where
// it's functionally meaningless - the capability filter alone can't catch
// that, since it's genuinely present on those devices per the API. So we
// also check each candidate's actual device category and only keep ones
// that are plausibly a fridge/freezer, filtering out anything else.
const FRIDGE_CATEGORIES = new Set(['Refrigerator', 'Freezer']);

async function fetchSabbathCapableDevices(accessToken, locationId) {
  try {
    const url = `https://api.smartthings.com/v1/devices?locationId=${encodeURIComponent(locationId)}&capability=samsungce.sabbathMode`;
    const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
    if (!res.ok) {
      console.error(`Device list fetch failed: HTTP ${res.status}`);
      return [];
    }
    const data = await res.json();
    const candidates = (data.items || []).map((d) => ({ deviceId: d.deviceId, label: d.label || d.name }));

    const checked = await Promise.all(candidates.map(async (d) => {
      try {
        const detailRes = await fetch(`https://api.smartthings.com/v1/devices/${d.deviceId}`, {
          headers: { Authorization: `Bearer ${accessToken}` },
        });
        if (!detailRes.ok) return null;
        const detail = await detailRes.json();
        const categories = (detail.components || []).flatMap((c) => (c.categories || []).map((cat) => cat.name));
        const isFridge = categories.some((name) => FRIDGE_CATEGORIES.has(name));
        if (!isFridge) {
          console.log(`Excluding ${d.deviceId} (${d.label}) - categories [${categories.join(', ')}] not fridge/freezer`);
          return null;
        }
        return d;
      } catch (err) {
        console.error(`Device detail fetch failed for ${d.deviceId}: ${err.message}`);
        return null;
      }
    }));

    return checked.filter(Boolean);
  } catch (err) {
    console.error(`Device list fetch error: ${err.message}`);
    return [];
  }
}

// ---- Hebcal helper: fetch this week's candle-lighting/Havdalah, treating
// an entire contiguous holy-day span (e.g. Yom Tov running into Shabbat) as
// ONE on/off cycle - first candle-lighting to last Havdalah. Explicitly
// excludes Chanukah, which Hebcal does not return under "candles" from this
// endpoint by default, but we filter defensively anyway.
async function fetchUpcomingShabbatWindow(latitude, longitude, tzid, candleExtraMin, havdalahExtraMin) {
  const start = new Date();
  const end = new Date();
  end.setDate(end.getDate() + 8);
  const fmt8 = (d) => d.toISOString().slice(0, 10);

  const url = `https://www.hebcal.com/hebcal?v=1&cfg=json&maj=on&min=off&mod=off&nx=off&mf=off&s=on` +
    `&c=on&geo=pos&latitude=${latitude}&longitude=${longitude}&tzid=${encodeURIComponent(tzid)}` +
    `&b=${CANDLE_BASE_OFFSET_MIN}&m=${HAVDALAH_BASE_OFFSET_MIN}&start=${fmt8(start)}&end=${fmt8(end)}&leyning=off`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Hebcal returned ${res.status}`);
  const data = await res.json();

  const isChanukah = (item) => /chanukah|hanukkah|חנוכה/i.test(`${item.title || ''} ${item.memo || ''} ${item.hebrew || ''}`);
  const events = (data.items || [])
    .filter((i) => (i.category === 'candles' || i.category === 'havdalah') && !isChanukah(i))
    .map((i) => ({ type: i.category, date: new Date(i.date) }))
    .sort((a, b) => a.date - b.date);

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
  if (!cycles.length) throw new Error('No candle/havdalah cycles in Hebcal response');
  const nextCycle = cycles[0];

  const candleTime = new Date(nextCycle.start);
  candleTime.setMinutes(candleTime.getMinutes() - candleExtraMin);
  const havdalahTime = new Date(nextCycle.end);
  havdalahTime.setMinutes(havdalahTime.getMinutes() + havdalahExtraMin);

  return {
    candleTime,
    havdalahTime,
    locationTitle: data.location ? data.location.title : null,
  };
}

// ---- Step 0: offset entry form ----
function renderOffsetForm(event) {
  const qs = event.queryStringParameters || {};
  const { client_id, redirect_uri, state } = qs;
  if (!redirect_uri) return { statusCode: 400, body: 'Missing redirect_uri' };

  const lang = detectLanguage(event);
  const t = lang === 'he' ? {
    title: 'הגדרות מתג שבת',
    intro: 'אפשר לכוון את המתג להידלק כמה דקות לפני הדלקת הנרות, ולהיכבות כמה דקות אחרי הבדלה.',
    langLabel: 'שפת התוכן במתג',
    langHint: 'קובע את השפה של המיקום והשעות שיוצגו במתג (בלי קשר לשפת האפליקציה)',
    candleLabel: 'דקות לפני הדלקת נרות',
    candleHint: "לדוגמה: 5 = המתג ידלק 5 דקות מוקדם יותר",
    havdalahLabel: 'דקות אחרי הבדלה',
    havdalahHint: 'לדוגמה: 10 = המתג יכבה 10 דקות מאוחר יותר',
    button: 'המשך',
  } : {
    title: 'Shabbat Switch Settings',
    intro: 'You can set the switch to turn on some minutes before candle-lighting, and turn off some minutes after Havdalah.',
    langLabel: 'Switch display language',
    langHint: "Sets the language of the location and times shown on the switch (independent of the app's own language)",
    candleLabel: 'Minutes before candle-lighting',
    candleHint: 'Example: 5 = the switch turns on 5 minutes earlier',
    havdalahLabel: 'Minutes after Havdalah',
    havdalahHint: 'Example: 10 = the switch turns off 10 minutes later',
    button: 'Continue',
  };

  const html = htmlPage(t.title, `
    <p>${t.intro}</p>
    <form method="POST" action="">
      <input type="hidden" name="step" value="offsets">
      <input type="hidden" name="client_id" value="${escapeHtml(client_id || '')}">
      <input type="hidden" name="redirect_uri" value="${escapeHtml(redirect_uri)}">
      <input type="hidden" name="state" value="${escapeHtml(state || '')}">

      <label for="displayLang">${t.langLabel}</label>
      <select id="displayLang" name="displayLang" style="width:100%;padding:8px;font-size:16px;margin-top:6px;box-sizing:border-box;">
        <option value="he-IL"${lang === 'he' ? ' selected' : ''}>עברית</option>
        <option value="en-US"${lang === 'en' ? ' selected' : ''}>English</option>
      </select>
      <p class="hint">${t.langHint}</p>

      <label for="candleOffset">${t.candleLabel}</label>
      <input type="number" id="candleOffset" name="candleOffset" value="0" step="1">
      <p class="hint">${t.candleHint}</p>

      <label for="havdalahOffset">${t.havdalahLabel}</label>
      <input type="number" id="havdalahOffset" name="havdalahOffset" value="0" step="1">
      <p class="hint">${t.havdalahHint}</p>

      <button type="submit">${t.button}</button>
    </form>`, lang);
  return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0', 'Pragma': 'no-cache' }, body: html };
}

// ---- POST /authorize dispatches on the hidden "step" field ----
async function handleAuthorizePost(event) {
  const rawBody = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf-8') : event.body;
  const form = new URLSearchParams(rawBody);
  const step = form.get('step');

  if (step === 'confirm') return handleConfirm(form);
  if (step === 'fridge') return handleFridgeSubmit(form);
  return handleOffsetsSubmit(form);
}

// ---- Step 1: offsets submitted -> send browser to SmartThings' OWN
// authorize endpoint to get a real API token for their location ----
async function handleOffsetsSubmit(form) {
  const client_id = form.get('client_id');
  const redirect_uri = form.get('redirect_uri');
  const state = form.get('state');
  const candleOffsetMin = parseInt(form.get('candleOffset') || '0', 10) || 0;
  const havdalahOffsetMin = parseInt(form.get('havdalahOffset') || '0', 10) || 0;
  const locale = form.get('displayLang') || 'he-IL';
  console.log(`Offsets submitted: candleOffsetMin=${candleOffsetMin} havdalahOffsetMin=${havdalahOffsetMin} locale=${locale}`);
  console.log(`Decoded state payload (for reference only): ${decodeStateInfo(state)}`);

  if (!redirect_uri) return { statusCode: 400, body: 'Missing redirect_uri' };

  const pending = crypto.randomUUID();
  await ddb.send(new PutCommand({
    TableName: CODES_TABLE,
    Item: {
      code: pending,
      kind: 'pending-authorize',
      schemaClientId: client_id,
      schemaRedirectUri: redirect_uri,
      schemaState: state || null,
      candleOffsetMin,
      havdalahOffsetMin,
      locale,
      expiresAt: Math.floor(Date.now() / 1000) + 600,
    },
  }));

  const stAuthUrl = new URL('https://api.smartthings.com/oauth/authorize');
  stAuthUrl.searchParams.set('client_id', process.env.OAUTH_IN_CLIENT_ID);
  stAuthUrl.searchParams.set('redirect_uri', process.env.OAUTH_IN_REDIRECT_URI);
  stAuthUrl.searchParams.set('response_type', 'code');
  stAuthUrl.searchParams.set('scope', 'r:locations:* r:devices:* x:devices:*');
  stAuthUrl.searchParams.set('state', pending);

  console.log(`Redirecting browser to OAuth-In: ${stAuthUrl.toString()}`);
  return { statusCode: 302, headers: { Location: stAuthUrl.toString() } };
}

// ---- Step 2: SmartThings' own OAuth server sends the user back here.
// Resolve the location, preview this week's real times, and show a
// confirmation screen instead of finishing immediately. ----
async function handleOAuthInCallback(event) {
  const qs = event.queryStringParameters || {};
  const { code, state: pendingId } = qs;

  const { Item: pending } = await ddb.send(new GetCommand({ TableName: CODES_TABLE, Key: { code: pendingId } }));
  if (!pending) return { statusCode: 400, body: 'Unknown or expired authorization' };

  const basicAuth = Buffer.from(`${process.env.OAUTH_IN_CLIENT_ID}:${process.env.OAUTH_IN_CLIENT_SECRET}`).toString('base64');
  const tokenRes = await fetch('https://auth-global.api.smartthings.com/oauth/token', {
    method: 'POST',
    headers: { Authorization: `Basic ${basicAuth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: process.env.OAUTH_IN_REDIRECT_URI,
    }),
  });
  if (!tokenRes.ok) return { statusCode: 400, body: `ST token exchange failed: ${await tokenRes.text()}` };
  const stTokens = await tokenRes.json();

  let latitude, longitude, timeZoneId, resolvedLocationId;
  const locListRes = await fetch('https://api.smartthings.com/v1/locations', {
    headers: { Authorization: `Bearer ${stTokens.access_token}` },
  });
  if (!locListRes.ok) return { statusCode: 400, body: `Failed to list locations: HTTP ${locListRes.status}` };
  const locList = await locListRes.json();
  console.log(`Locations visible to this token: ${JSON.stringify(locList)}`);
  const items = locList.items || [];
  if (!items.length) return { statusCode: 400, body: 'No locations visible to this account' };

  // Take the first location. Fine for a single-location household; worth
  // revisiting if the group turns out to have multi-location users.
  resolvedLocationId = items[0].locationId;
  const locDetailRes = await fetch(`https://api.smartthings.com/v1/locations/${resolvedLocationId}`, {
    headers: { Authorization: `Bearer ${stTokens.access_token}` },
  });
  if (!locDetailRes.ok) return { statusCode: 400, body: `Failed to fetch location detail: HTTP ${locDetailRes.status}` };
  const loc = await locDetailRes.json();
  const hasValidCoords = typeof loc.latitude === 'number' && typeof loc.longitude === 'number'
    && !Number.isNaN(loc.latitude) && !Number.isNaN(loc.longitude);
  if (!hasValidCoords) {
    const lang = pending.locale && pending.locale.startsWith('en') ? 'en' : 'he';
    const msg = lang === 'he'
      ? htmlPage('חסר מיקום', `<p>למיקום שלך ב-SmartThings אין עדיין כתובת/קואורדינטות מוגדרות, ולכן אי אפשר לחשב זמני שבת.</p><p>יש להיכנס לאפליקציית SmartThings, לפתוח את הגדרות המיקום (Location Settings) ולהזין כתובת, ואז לנסות שוב.</p>`, 'he')
      : htmlPage('Missing Location', `<p>Your SmartThings location doesn't have an address/coordinates set yet, so Shabbat times can't be calculated.</p><p>Please open the SmartThings app, go to Location Settings, enter an address, and try again.</p>`, 'en');
    return { statusCode: 400, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body: msg };
  }
  latitude = String(loc.latitude);
  longitude = String(loc.longitude);
  timeZoneId = loc.timeZoneId || 'Asia/Jerusalem';
  const locationName = await reverseGeocode(latitude, longitude, pending.locale);

  const candleOffsetMin = pending.candleOffsetMin || 0;
  const havdalahOffsetMin = pending.havdalahOffsetMin || 0;

  const fridgeDevices = await fetchSabbathCapableDevices(stTokens.access_token, resolvedLocationId);
  console.log(`Sabbath-capable devices at this location: ${JSON.stringify(fridgeDevices)}`);

  const fridgePendingId = crypto.randomUUID();
  await ddb.send(new PutCommand({
    TableName: CODES_TABLE,
    Item: {
      code: fridgePendingId,
      kind: 'fridge-pending',
      schemaRedirectUri: pending.schemaRedirectUri,
      schemaState: pending.schemaState,
      resolvedLocationId,
      latitude, longitude, timeZoneId,
      locationTitle: locationName,
      candleOffsetMin, havdalahOffsetMin,
      locale: pending.locale,
      // Persisted so the trigger Lambda can later command the fridge -
      // see the top-of-file comment for why this is stored now instead
      // of only being used transiently.
      oauthInAccessToken: stTokens.access_token,
      oauthInRefreshToken: stTokens.refresh_token,
      expiresAt: Math.floor(Date.now() / 1000) + 600,
    },
  }));
  await ddb.send(new DeleteCommand({ TableName: CODES_TABLE, Key: { code: pendingId } }));

  const lang = pending.locale && pending.locale.startsWith('en') ? 'en' : 'he';
  const t = lang === 'he' ? {
    title: 'חיבור מקרר (אופציונלי)',
    intro: 'אם יש לך מקרר סמסונג עם מצב שבת, אפשר לחבר אותו כאן - המתג יפעיל וייכבה אותו אוטומטית יחד עם שאר הבית.',
    noneFound: 'לא נמצא מקרר תואם בחשבון הזה.',
    skipOption: 'לא כעת / אין לי מקרר לחיבור',
    button: 'המשך',
  } : {
    title: 'Connect a Fridge (optional)',
    intro: "If you have a Samsung fridge with Sabbath mode, you can connect it here - the switch will turn it on and off automatically along with everything else.",
    noneFound: 'No matching fridge found on this account.',
    skipOption: "Not now / I don't have a fridge to connect",
    button: 'Continue',
  };

  const options = fridgeDevices.map((d) => `
      <label style="display:block; font-weight:normal; margin:8px 0;">
        <input type="radio" name="fridgeDeviceId" value="${escapeHtml(d.deviceId)}">
        ${escapeHtml(d.label)}
      </label>`).join('');

  const html = htmlPage(t.title, `
    <p>${t.intro}</p>
    <form method="POST" action="/authorize">
      <input type="hidden" name="step" value="fridge">
      <input type="hidden" name="pendingId" value="${fridgePendingId}">
      ${fridgeDevices.length ? options : `<p class="hint">${t.noneFound}</p>`}
      <label style="display:block; font-weight:normal; margin:8px 0;">
        <input type="radio" name="fridgeDeviceId" value="" checked>
        ${t.skipOption}
      </label>
      <button type="submit">${t.button}</button>
    </form>`, lang);

  return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0', 'Pragma': 'no-cache' }, body: html };
}

// ---- Step 2b: fridge choice submitted -> compute this week's real times
// and show the final confirmation screen ----
async function handleFridgeSubmit(form) {
  const fridgePendingId = form.get('pendingId');
  const fridgeDeviceId = form.get('fridgeDeviceId') || null;

  const { Item: pending } = await ddb.send(new GetCommand({ TableName: CODES_TABLE, Key: { code: fridgePendingId } }));
  if (!pending) return { statusCode: 400, body: 'Unknown or expired authorization' };

  const { latitude, longitude, timeZoneId, locationTitle: locationName, candleOffsetMin, havdalahOffsetMin, resolvedLocationId } = pending;

  let fridgeLabel = null;
  if (fridgeDeviceId) {
    const devices = await fetchSabbathCapableDevices(pending.oauthInAccessToken, resolvedLocationId);
    const match = devices.find((d) => d.deviceId === fridgeDeviceId);
    fridgeLabel = match ? match.label : null;
  }

  let preview;
  try {
    preview = await fetchUpcomingShabbatWindow(latitude, longitude, timeZoneId, candleOffsetMin, havdalahOffsetMin);
  } catch (err) {
    console.error(`Hebcal preview failed: ${err.message}`);
    return { statusCode: 400, body: `Could not compute Shabbat times: ${err.message}` };
  }

  const confirmToken = crypto.randomUUID();
  await ddb.send(new PutCommand({
    TableName: CODES_TABLE,
    Item: {
      code: confirmToken,
      kind: 'confirm-pending',
      schemaRedirectUri: pending.schemaRedirectUri,
      schemaState: pending.schemaState,
      resolvedLocationId,
      latitude, longitude, timeZoneId,
      locationTitle: locationName,
      candleOffsetMin, havdalahOffsetMin,
      locale: pending.locale,
      fridgeDeviceId, fridgeLabel,
      oauthInAccessToken: pending.oauthInAccessToken,
      oauthInRefreshToken: pending.oauthInRefreshToken,
      expiresAt: Math.floor(Date.now() / 1000) + 600,
    },
  }));
  await ddb.send(new DeleteCommand({ TableName: CODES_TABLE, Key: { code: fridgePendingId } }));

  const lang = pending.locale && pending.locale.startsWith('en') ? 'en' : 'he';
  const fmt = (d) => new Intl.DateTimeFormat(pending.locale || 'he-IL', { timeZone: timeZoneId, weekday: 'long', hour: '2-digit', minute: '2-digit' }).format(d);
  const t = lang === 'he' ? {
    title: 'אישור הגדרות',
    location: 'מיקום',
    candle: 'הדלקת נרות (השבוע הקרוב)',
    havdalah: 'הבדלה (השבוע הקרוב)',
    offsets: 'ההיסט שבחרת',
    offsetsText: `${candleOffsetMin} דקות לפני הדלקה, ${havdalahOffsetMin} דקות אחרי הבדלה`,
    fridge: 'מקרר מחובר',
    noFridge: 'לא נבחר מקרר',
    button: 'אישור וסיום',
  } : {
    title: 'Confirm Settings',
    location: 'Location',
    candle: 'Candle-lighting (this coming week)',
    havdalah: 'Havdalah (this coming week)',
    offsets: 'Your chosen offset',
    offsetsText: `${candleOffsetMin} min before candle-lighting, ${havdalahOffsetMin} min after Havdalah`,
    fridge: 'Connected fridge',
    noFridge: 'No fridge selected',
    button: 'Confirm & Finish',
  };

  const html = htmlPage(t.title, `
    <p><strong>${t.location}:</strong> ${escapeHtml(locationName || `${latitude}, ${longitude}`)}</p>
    <p><strong>${t.candle}:</strong> ${escapeHtml(fmt(preview.candleTime))}</p>
    <p><strong>${t.havdalah}:</strong> ${escapeHtml(fmt(preview.havdalahTime))}</p>
    <p><strong>${t.offsets}:</strong> ${t.offsetsText}</p>
    <p><strong>${t.fridge}:</strong> ${fridgeLabel ? escapeHtml(fridgeLabel) : t.noFridge}</p>
    <form method="POST" action="/authorize">
      <input type="hidden" name="step" value="confirm">
      <input type="hidden" name="confirmToken" value="${confirmToken}">
      <button type="submit">${t.button}</button>
    </form>`, lang);

  return { statusCode: 200, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0', 'Pragma': 'no-cache' }, body: html };
}

// ---- Step 3: confirmation submitted -> mint our schema code and
// redirect back to SmartThings, finishing the original request ----
async function handleConfirm(form) {
  const confirmToken = form.get('confirmToken');
  const { Item: confirmRecord } = await ddb.send(new GetCommand({ TableName: CODES_TABLE, Key: { code: confirmToken } }));
  if (!confirmRecord) return { statusCode: 400, body: 'Unknown or expired confirmation' };

  const schemaCode = crypto.randomUUID();
  await ddb.send(new PutCommand({
    TableName: CODES_TABLE,
    Item: {
      code: schemaCode,
      kind: 'schema-code',
      locationId: confirmRecord.resolvedLocationId,
      latitude: confirmRecord.latitude,
      longitude: confirmRecord.longitude,
      timeZoneId: confirmRecord.timeZoneId,
      locationTitle: confirmRecord.locationTitle,
      candleOffsetMin: confirmRecord.candleOffsetMin || 0,
      havdalahOffsetMin: confirmRecord.havdalahOffsetMin || 0,
      locale: confirmRecord.locale,
      fridgeDeviceId: confirmRecord.fridgeDeviceId || null,
      fridgeLabel: confirmRecord.fridgeLabel || null,
      oauthInAccessToken: confirmRecord.oauthInAccessToken,
      oauthInRefreshToken: confirmRecord.oauthInRefreshToken,
      expiresAt: Math.floor(Date.now() / 1000) + 300,
    },
  }));
  await ddb.send(new DeleteCommand({ TableName: CODES_TABLE, Key: { code: confirmToken } }));

  const redirect = new URL(confirmRecord.schemaRedirectUri);
  redirect.searchParams.set('code', schemaCode);
  if (confirmRecord.schemaState) redirect.searchParams.set('state', confirmRecord.schemaState);
  console.log(`Redirecting browser back to SmartThings: ${redirect.toString()}`);
  return { statusCode: 302, headers: { Location: redirect.toString() } };
}

async function handleToken(event) {
  const rawBody = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf-8') : event.body;
  const isForm = (event.headers['content-type'] || '').includes('application/x-www-form-urlencoded');
  const params = isForm ? new URLSearchParams(rawBody) : JSON.parse(rawBody || '{}');
  const grantType = params.get ? params.get('grant_type') : params.grant_type;
  console.log(`Token request: grantType=${grantType} rawBody=${rawBody}`);

  if (grantType === 'authorization_code') {
    const code = params.get ? params.get('code') : params.code;
    const { Item: codeRecord } = await ddb.send(new GetCommand({ TableName: CODES_TABLE, Key: { code } }));
    if (!codeRecord || codeRecord.kind !== 'schema-code' || codeRecord.expiresAt < Math.floor(Date.now() / 1000)) {
      return jsonResponse(400, { error: 'invalid_grant' });
    }
    await ddb.send(new DeleteCommand({ TableName: CODES_TABLE, Key: { code } }));

    // If this location already has an install (user reopened the invite
    // link to change offsets), UPDATE that record and keep its
    // externalDeviceId so SmartThings treats it as the same device
    // instead of creating a duplicate.
    let existing = null;
    if (codeRecord.locationId) {
      const scan = await ddb.send(new ScanCommand({
        TableName: TABLE,
        FilterExpression: 'locationId = :loc',
        ExpressionAttributeValues: { ':loc': codeRecord.locationId },
      }));
      existing = scan.Items && scan.Items[0];
    }

    const accessToken = crypto.randomUUID();
    const refreshToken = crypto.randomUUID();

    if (existing) {
      await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { accessToken: existing.accessToken } }));
    }

    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: {
        accessToken,
        refreshToken,
        locationId: codeRecord.locationId,
        latitude: codeRecord.latitude,
        longitude: codeRecord.longitude,
        timeZoneId: codeRecord.timeZoneId,
        locationTitle: codeRecord.locationTitle,
        candleOffsetMin: codeRecord.candleOffsetMin || 0,
        havdalahOffsetMin: codeRecord.havdalahOffsetMin || 0,
        locale: codeRecord.locale,
        externalDeviceId: existing ? existing.externalDeviceId : crypto.randomUUID(),
        switchState: existing ? existing.switchState : 'off',
        // Callback access gets re-granted fresh after this via
        // grantCallbackAccess, so we don't carry over the old Schema
        // connector tokens. The OAuth-In device token below is a
        // DIFFERENT credential (see top-of-file comment) and IS carried
        // forward here on purpose - it's what lets the trigger Lambda
        // command the fridge later. If no fridge was selected, these are
        // null/undefined and the trigger simply skips fridge control.
        fridgeDeviceId: codeRecord.fridgeDeviceId || null,
        fridgeLabel: codeRecord.fridgeLabel || null,
        oauthInAccessToken: codeRecord.oauthInAccessToken,
        oauthInRefreshToken: codeRecord.oauthInRefreshToken,
      },
    }));

    // New (or re-confirmed) install - schedule it immediately rather than
    // waiting for the weekly Sunday cron, so this Shabbat works even if
    // someone installs mid-week. Fire-and-forget: this must never block or
    // fail the actual token response back to SmartThings, so errors here
    // are only logged, not thrown. The scheduler Lambda re-schedules ALL
    // installs each run (cheap at this scale), so this is safe to call
    // even if it overlaps with the real weekly run.
    if (process.env.WEEKLY_SCHEDULER_ARN) {
      try {
        await lambdaClient.send(new InvokeCommand({
          FunctionName: process.env.WEEKLY_SCHEDULER_ARN,
          InvocationType: 'Event',
          Payload: JSON.stringify({}),
        }));
      } catch (err) {
        console.error(`Failed to trigger immediate scheduling: ${err.message}`);
      }
    }

    return jsonResponse(200, { access_token: accessToken, refresh_token: refreshToken, token_type: 'Bearer', expires_in: 86399 });
  }

  if (grantType === 'refresh_token') {
    const oldRefreshToken = params.get ? params.get('refresh_token') : params.refresh_token;
    const scan = await ddb.send(new ScanCommand({
      TableName: TABLE,
      FilterExpression: 'refreshToken = :r',
      ExpressionAttributeValues: { ':r': oldRefreshToken },
    }));
    const record = scan.Items && scan.Items[0];
    if (!record) return jsonResponse(400, { error: 'invalid_grant' });

    const newAccessToken = crypto.randomUUID();
    const newRefreshToken = crypto.randomUUID();
    await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { accessToken: record.accessToken } }));
    await ddb.send(new PutCommand({ TableName: TABLE, Item: { ...record, accessToken: newAccessToken, refreshToken: newRefreshToken } }));

    return jsonResponse(200, { access_token: newAccessToken, refresh_token: newRefreshToken, token_type: 'Bearer', expires_in: 86399 });
  }

  return jsonResponse(400, { error: 'unsupported_grant_type' });
}

function jsonResponse(statusCode, obj) {
  return { statusCode, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}

function escapeHtml(str) {
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function htmlPage(title, bodyHtml, lang = 'he') {
  const dir = lang === 'he' ? 'rtl' : 'ltr';
  return `<!DOCTYPE html>
<html lang="${lang}" dir="${dir}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)}</title>
  <style>
    body { font-family: sans-serif; max-width: 420px; margin: 40px auto; padding: 0 16px; }
    label { display: block; margin-top: 16px; font-weight: bold; }
    input[type=number] { width: 100%; padding: 8px; font-size: 16px; margin-top: 6px; box-sizing: border-box; }
    button { margin-top: 24px; width: 100%; padding: 12px; font-size: 16px; background: #5b3a29; color: white; border: none; border-radius: 6px; }
    p.hint { color: #666; font-size: 14px; margin: 16px 0 0; }
  </style>
</head>
<body>
  <h2>${escapeHtml(title)}</h2>
  ${bodyHtml}
</body>
</html>`;
}

// Detects the visitor's likely language from the browser's own
// Accept-Language header - far more reliable than SmartThings' own
// session locale (confirmed elsewhere to consistently report en-US
// regardless of the app's actual display language). Defaults to Hebrew
// only when the header is missing entirely; otherwise Hebrew is used
// only if it's explicitly the top preference, English otherwise.
function detectLanguage(event) {
  const header = (event.headers && (event.headers['accept-language'] || event.headers['Accept-Language'])) || '';
  if (!header) return 'he';
  return header.toLowerCase().startsWith('he') ? 'he' : 'en';
}
