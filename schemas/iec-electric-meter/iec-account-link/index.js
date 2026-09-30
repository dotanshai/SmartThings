'use strict';

/**
 * IEC <-> SmartThings account-link OAuth wrapper.
 *
 * IEC has no real OAuth of its own for third parties - login is:
 *   ID number -> Okta authn -> SMS/email OTP -> Okta PKCE authorize -> token exchange
 * (this is exactly what py-iec-api / the HA custom component do under the hood,
 * against a public native-app Okta client - no client secret required on IEC's side).
 *
 * This Lambda plays the role of a normal OAuth2 authorization server *to SmartThings*,
 * while internally driving the real IEC/Okta login. SmartThings never sees Okta directly.
 *
 * Flow:
 *   GET  /authorize   <- SmartThings sends the user here (account link screen)
 *   POST /iec/start    -> ID number submitted, triggers OTP, shows OTP screen
 *   POST /iec/verify   -> OTP submitted, completes IEC login, redirects back to SmartThings
 *   POST /token        <- SmartThings calls this server-to-server to exchange the code
 *
 * Requires one DynamoDB table (see README.md) with primary key "pk" (String)
 * and TTL attribute "ttl" (Number, epoch seconds).
 */

const crypto = require('crypto');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, PutCommand, GetCommand, DeleteCommand } = require('@aws-sdk/lib-dynamodb');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME || 'IecSchemaConnectorTokens';

// ---- Real IEC/Okta constants (from py-iec-api's login.py - do not change) ----
const OKTA_BASE_URL = 'https://iec-ext.okta.com';
const IEC_OKTA_CLIENT_ID = '0oaqf6zr7yEcQZqqt2p7';
const IEC_APP_REDIRECT_URI = 'com.iecrn:/';

// ---- Your own OAuth server credentials (set these in env vars / SmartThings config) ----
const MY_CLIENT_ID = process.env.MY_CLIENT_ID;
const MY_CLIENT_SECRET = process.env.MY_CLIENT_SECRET;

// =====================================================================================
// Small helpers
// =====================================================================================

function base64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function generatePkce() {
  const verifier = base64url(crypto.randomBytes(32));
  const challenge = base64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
}

function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('hex');
}

// Israeli ID checksum check (same algorithm iec_api.commons.is_valid_israeli_id uses)
function isValidIsraeliId(idNumber) {
  const id = String(idNumber).trim();
  if (!/^\d+$/.test(id) || id.length > 9) return false;
  const padded = id.padStart(9, '0');
  let sum = 0;
  for (let i = 0; i < 9; i++) {
    let d = Number(padded[i]) * (i % 2 === 0 ? 1 : 2);
    if (d > 9) d -= 9;
    sum += d;
  }
  return sum % 10 === 0;
}

function html(body) {
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
    body: `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:420px;margin:40px auto;padding:0 16px;color:#222}
      input{width:100%;padding:12px;font-size:16px;margin:8px 0;box-sizing:border-box;border:1px solid #ccc;border-radius:8px}
      button{width:100%;padding:12px;font-size:16px;background:#0057ff;color:#fff;border:none;border-radius:8px;margin-top:8px}
      .hint{color:#666;font-size:14px}
      .err{color:#c0392b;font-size:14px}
    </style></head><body>${body}</body></html>`,
  };
}

function redirect(location) {
  return { statusCode: 302, headers: { Location: location }, body: '' };
}

function json(status, obj) {
  return { statusCode: status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}

function parseForm(event) {
  const raw = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
  const ct = (event.headers && (event.headers['content-type'] || event.headers['Content-Type'])) || '';
  if (ct.includes('application/json')) return JSON.parse(raw || '{}');
  const params = new URLSearchParams(raw);
  return Object.fromEntries(params.entries());
}

function hiddenFields(fields) {
  return Object.entries(fields)
    .filter(([, v]) => v !== undefined && v !== null)
    .map(([k, v]) => `<input type="hidden" name="${k}" value="${String(v).replace(/"/g, '&quot;')}">`)
    .join('\n');
}

// =====================================================================================
// Real IEC / Okta calls
// =====================================================================================

async function oktaPost(path, { json: jsonBody, form } = {}) {
  const headers = { accept: 'application/json' };
  let body;
  if (jsonBody) {
    headers['content-type'] = 'application/json';
    body = JSON.stringify(jsonBody);
  } else {
    headers['content-type'] = 'application/x-www-form-urlencoded';
    body = new URLSearchParams(form).toString();
  }
  const res = await fetch(`${OKTA_BASE_URL}${path}`, { method: 'POST', headers, body });
  const data = await res.json();
  if (!res.ok) {
    console.error(`Okta ${path} failed (${res.status}):`, JSON.stringify(data));
    const err = new Error(data.errorSummary || data.error_description || `Okta error ${res.status}`);
    err.data = data;
    throw err;
  }
  return data;
}

// Step 1: username -> stateToken + available MFA factors
async function getAuthFactors(idNumber) {
  const data = await oktaPost('/api/v1/authn', { json: { username: `${idNumber}@iec.co.il` } });
  return { stateToken: data.stateToken, factors: (data._embedded && data._embedded.factors) || [] };
}

// IEC/Okta disguises SMS delivery as an "email" factor pointing at an SMS-to-email gateway
// address, not a real inbox, rather than using factorType "sms" directly. Confirmed domains
// seen in the wild so far - add to this list if another one shows up in the logs.
const SMS_GATEWAY_DOMAINS = ['sns.iec.co.il', 'sms.telemessage.com'];

function factorType(factor) {
  const ft = factor.factorType || '';
  const email = (factor.profile && factor.profile.email) || '';
  const domain = (email.split('@')[1] || '').toLowerCase();
  if (ft === 'email' && SMS_GATEWAY_DOMAINS.some((d) => domain === d)) return 'sms';
  return ft;
}

function selectFactor(factors, excludeId) {
  const candidates = excludeId ? factors.filter((f) => f.id !== excludeId) : factors;
  if (!candidates.length) throw new Error('No other MFA factors available on this IEC account');
  const sms = candidates.find((f) => factorType(f) === 'sms');
  return sms || candidates[0];
}

// Step 2: trigger OTP send (no passCode) or verify OTP (with passCode)
async function verifyFactor(factorId, stateToken, passCode) {
  const body = { stateToken };
  if (passCode) body.passCode = passCode;
  const data = await oktaPost(`/api/v1/authn/factors/${factorId}/verify`, { json: body });
  if (data.status !== 'SUCCESS' && data.status !== 'MFA_CHALLENGE') {
    throw new Error(`Unexpected Okta status: ${data.status}`);
  }
  return data.sessionToken; // present once OTP was correct (or on the initial send in some tenants)
}

// Step 3: PKCE authorize using the Okta sessionToken, scrape the hidden "code" field
async function authorizeSession(sessionToken) {
  const { verifier, challenge } = generatePkce();
  const state = randomToken(8);
  const url = `${OKTA_BASE_URL}/oauth2/default/v1/authorize?` + new URLSearchParams({
    client_id: IEC_OKTA_CLIENT_ID,
    response_type: 'id_token code',
    response_mode: 'form_post',
    scope: 'openid email profile offline_access',
    redirect_uri: IEC_APP_REDIRECT_URI,
    state,
    nonce: 'abc123',
    code_challenge_method: 'S256',
    sessionToken,
    code_challenge: challenge,
  }).toString();

  const res = await fetch(url);
  const text = await res.text();
  const match = text.match(/name="code" value="([^"]+)"/);
  if (!match) throw new Error('Could not extract authorization code from Okta response');
  return { code: match[1], verifier };
}

// Step 4: exchange the Okta code for real IEC tokens
async function getIecTokens(code, verifier) {
  return oktaPost('/oauth2/default/v1/token', {
    form: {
      client_id: IEC_OKTA_CLIENT_ID,
      code_verifier: verifier,
      grant_type: 'authorization_code',
      redirect_uri: IEC_APP_REDIRECT_URI,
      code,
    },
  }); // { access_token, refresh_token, id_token, expires_in, token_type, scope }
}

// =====================================================================================
// Route handlers
// =====================================================================================

async function handleAuthorizeGet(event) {
  const q = event.queryStringParameters || {};
  const { client_id, redirect_uri, state, response_type, scope } = q;
  if (!redirect_uri || !state) return json(400, { error: 'invalid_request', error_description: 'missing redirect_uri/state' });

  return html(`
    <h2>Link your IEC account</h2>
    <p class="hint">Enter your Israeli ID number (תעודת זהות). We'll text you a one-time code.</p>
    <form method="POST" action="/iec/start">
      ${hiddenFields({ client_id, redirect_uri, state, response_type, scope })}
      <input name="idNumber" inputmode="numeric" placeholder="ID number" required maxlength="9">
      <button type="submit">Send code</button>
    </form>
  `);
}

async function handleIecStart(event) {
  const f = parseForm(event);
  const { idNumber, client_id, redirect_uri, state, response_type, scope, excludeFactorId } = f;
  const maskedId = idNumber ? `***${String(idNumber).slice(-3)}` : '(none)';

  if (!isValidIsraeliId(idNumber)) {
    console.error(`iec/start: invalid ID checksum for ${maskedId}`);
    return html(`<p class="err">That doesn't look like a valid ID number. Go back and try again.</p>`);
  }

  try {
    console.log(`iec/start: requesting factors for ${maskedId}`);
    const { stateToken, factors } = await getAuthFactors(idNumber);
    console.log(`iec/start: got ${factors.length} factor(s) for ${maskedId}: ${factors.map(factorType).join(', ')}`);
    factors.forEach((f) => {
      const email = f.profile && f.profile.email;
      const phone = f.profile && (f.profile.phoneNumber || f.profile.phone);
      // The fake @sns.iec.co.il address represents SMS delivery internally, not a real inbox -
      // only log it when it's a genuine email factor, and Okta already masks it for us.
      if (email && !email.includes('@sns.iec.co.il')) {
        console.log(`iec/start: email factor for ${maskedId} goes to ${email}`);
      }
      // Haven't confirmed IEC's API actually populates this for SMS factors (only ever seen
      // the fake @sns.iec.co.il email representation so far) - logging defensively in case
      // some accounts do expose it. Masking it ourselves rather than assuming Okta already
      // does, since (unlike the email field) that hasn't been confirmed either way.
      if (phone) {
        const p = String(phone);
        console.log(`iec/start: phone factor for ${maskedId}: ***${p.slice(-3)}`);
      }
    });
    const factor = selectFactor(factors, excludeFactorId);
    await verifyFactor(factor.id, stateToken); // triggers the OTP send, no passCode yet
    console.log(`iec/start: OTP sent via ${factorType(factor)} for ${maskedId}`);

    // Offer a fallback to any other available factor, in case delivery on this one fails
    // silently on IEC/the gateway's side (confirmed happening for at least one real account -
    // "OTP sent" succeeded on our end but the SMS never actually arrived). Each new /iec/start
    // call invalidates whatever code was sent before it - confirmed a real user got tripped up
    // by this (clicked SMS, then "try another", then SMS again, all within ~25s, then tried
    // to use a code from the middle attempt after the third had already superseded it) - so
    // this needs a cooldown and a clear warning, not just being available.
    const hasAlternative = factors.some((f) => f.id !== factor.id);
    const alternativeBlock = hasAlternative ? `
      <form method="POST" action="/iec/start" style="margin-top: 12px;">
        ${hiddenFields({ idNumber, client_id, redirect_uri, state, response_type, scope, excludeFactorId: factor.id })}
        <button type="submit" class="secondary" id="altBtn" disabled>Didn't get it? Try another method (<span id="altCountdown">90</span>s)</button>
      </form>
      <script>
        (function() {
          var btn = document.getElementById('altBtn');
          var span = document.getElementById('altCountdown');
          var remaining = 90;
          var timer = setInterval(function() {
            remaining--;
            if (remaining <= 0) {
              clearInterval(timer);
              btn.disabled = false;
              btn.textContent = "Didn't get it? Try another method";
            } else {
              span.textContent = remaining;
            }
          }, 1000);
        })();
      </script>
    ` : '';

    return html(`
      <h2>Enter the code</h2>
      <p class="hint">We sent a one-time code via ${factorType(factor)}.</p>
      <p class="err" dir="rtl">⚠️ השתמשו רק בקוד מהניסיון הנוכחי. בקשת קוד חדש (דרך הכפתור למטה, או התחלה מחדש) מייצרת קוד OTP חדש ומבטלת את הקוד מנסיון הנוכחי, גם אם כבר קיבלתם אותו.</p>
      <form method="POST" action="/iec/verify" onsubmit="this.querySelector('button').disabled=true; this.querySelector('button').textContent='Verifying...';">
        ${hiddenFields({ client_id, redirect_uri, state, response_type, scope, stateToken, factorId: factor.id })}
        <input name="otpCode" inputmode="numeric" placeholder="OTP code" required maxlength="6">
        <button type="submit">Verify</button>
      </form>
      ${alternativeBlock}
    `);
  } catch (e) {
    console.error(`iec/start: failed for ${maskedId}: ${e.message}`, e.data ? JSON.stringify(e.data) : '');
    return html(`<p class="err">Couldn't start login: ${e.message}. Go back and try again.</p>`);
  }
}

async function handleIecVerify(event) {
  const f = parseForm(event);
  const { otpCode, stateToken, factorId, redirect_uri, state } = f;

  try {
    console.log(`iec/verify: verifying OTP (factor ${factorId})`);
    const sessionToken = await verifyFactor(factorId, stateToken, otpCode);
    if (!sessionToken) {
      console.error('iec/verify: verifyFactor returned no sessionToken (OTP likely wrong or expired)');
      throw new Error('Incorrect code');
    }
    console.log('iec/verify: OTP accepted, got sessionToken, starting PKCE authorize');

    const { code, verifier } = await authorizeSession(sessionToken);
    console.log('iec/verify: got Okta authorization code, exchanging for IEC tokens');
    const iecTokens = await getIecTokens(code, verifier);
    console.log('iec/verify: got real IEC tokens, storing auth code and redirecting back to SmartThings');

    const authCode = randomToken(24);
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: {
        pk: `AUTHCODE#${authCode}`,
        iecRefreshToken: iecTokens.refresh_token,
        iecIdToken: iecTokens.id_token,
        ttl: Math.floor(Date.now() / 1000) + 300, // 5 min, one-time use
      },
    }));

    return redirect(`${redirect_uri}?code=${authCode}&state=${encodeURIComponent(state)}`);
  } catch (e) {
    console.error(`iec/verify: failed: ${e.message}`, e.data ? JSON.stringify(e.data) : '');
    return html(`
      <p class="err">Verification failed: ${e.message}</p>
      <form method="POST" action="/iec/verify">
        ${hiddenFields({ stateToken, factorId, redirect_uri, state })}
        <input name="otpCode" inputmode="numeric" placeholder="OTP code" required maxlength="6">
        <button type="submit">Try again</button>
      </form>
    `);
  }
}

async function handleToken(event) {
  const f = parseForm(event);
  const { grant_type } = f;

  // Basic client authentication (SmartThings sends client_id/secret either in body or Basic auth header)
  const authHeader = (event.headers && (event.headers.authorization || event.headers.Authorization)) || '';
  let clientId = f.client_id;
  let clientSecret = f.client_secret;
  if (!clientId && authHeader.startsWith('Basic ')) {
    const decoded = Buffer.from(authHeader.slice(6), 'base64').toString('utf8');
    [clientId, clientSecret] = decoded.split(':');
  }
  if (MY_CLIENT_ID && (clientId !== MY_CLIENT_ID || clientSecret !== MY_CLIENT_SECRET)) {
    return json(401, { error: 'invalid_client' });
  }

  if (grant_type === 'authorization_code') {
    const { code } = f;
    const item = await ddb.send(new GetCommand({ TableName: TABLE, Key: { pk: `AUTHCODE#${code}` } }));
    if (!item.Item) return json(400, { error: 'invalid_grant', error_description: 'unknown or expired code' });
    await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { pk: `AUTHCODE#${code}` } })); // one-time use

    return issueTokens(item.Item.iecRefreshToken);
  }

  if (grant_type === 'refresh_token') {
    const { refresh_token } = f;
    const item = await ddb.send(new GetCommand({ TableName: TABLE, Key: { pk: `REFRESH#${refresh_token}` } }));
    if (!item.Item) return json(400, { error: 'invalid_grant', error_description: 'unknown refresh token' });

    return issueTokens(item.Item.iecRefreshToken, refresh_token);
  }

  return json(400, { error: 'unsupported_grant_type' });
}

// Mints OUR OWN opaque access/refresh tokens and maps them to the underlying IEC refresh_token.
// (Actually calling IEC's data endpoints happens later, in the discovery/state-refresh Lambda -
// it looks up this same table by the access_token to find which IEC refresh_token to use.)
async function issueTokens(iecRefreshToken, existingRefreshToken) {
  const accessToken = randomToken(32);
  const refreshToken = existingRefreshToken || randomToken(32);
  const now = Math.floor(Date.now() / 1000);

  await ddb.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: `TOKEN#${accessToken}`, iecRefreshToken, ttl: now + 3600 },
  }));
  if (!existingRefreshToken) {
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { pk: `REFRESH#${refreshToken}`, iecRefreshToken }, // long-lived, no ttl
    }));
  }

  return json(200, {
    access_token: accessToken,
    refresh_token: refreshToken,
    token_type: 'Bearer',
    expires_in: 3600,
  });
}

// =====================================================================================
// Entry point
// =====================================================================================

exports.handler = async (event) => {
  const method = event.requestContext?.http?.method || event.httpMethod;
  const path = event.rawPath || event.path || '';
  console.log(`${method} ${path}`);

  try {
    if (method === 'GET' && path === '/authorize') return await handleAuthorizeGet(event);
    if (method === 'POST' && path === '/iec/start') return await handleIecStart(event);
    if (method === 'POST' && path === '/iec/verify') return await handleIecVerify(event);
    if (method === 'POST' && path === '/token') return await handleToken(event);
    console.error(`No route for ${method} ${path}`);
    return json(404, { error: 'not_found' });
  } catch (e) {
    console.error(`Unhandled error on ${method} ${path}:`, e);
    return json(500, { error: 'server_error', error_description: e.message });
  }
};
