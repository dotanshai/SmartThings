/**
 * Arad Water Meter - Account Link Lambda (multi-account version)
 *
 * Same OAuth2 flow as before, but now supports linking MULTIPLE Arad
 * accounts (e.g. two different rym-pro.com logins for two separate meters)
 * to a single SmartThings installation.
 *
 * Flow:
 *   1. GET /authorize?client_id=&redirect_uri=&state=  -> login form
 *   2. POST /authorize (email/password + client_id/redirect_uri/state/session)
 *      -> verify against Arad, append to an in-progress "session" (a list of
 *         accounts being collected), show a confirmation page with
 *         "Add another meter" / "Finish" choices
 *   3. "Add another meter" -> back to the login form, carrying the same session id
 *      "Finish" -> GET /finish?session=... -> mints a short-lived auth code
 *      referencing ALL accumulated accounts, redirects to {redirect_uri}?code=&state=
 *   4. SmartThings calls POST /token (authorization_code) -> we store the full
 *      accounts array under a new access_token in TOKENS_TABLE
 *   5. POST /token (refresh_token) -> same simplified rotation as before
 *
 * Env vars required:
 *   ST_CLIENT_ID, ST_CLIENT_SECRET
 *   TOKENS_TABLE          - partition key: accessToken. Item: { accessToken, refreshToken, accounts: [{email,password,aradToken}, ...] }
 *   AUTH_CODES_TABLE       - partition key: code. TTL: expiresAt
 *   AUTH_SESSIONS_TABLE    - partition key: session. TTL: expiresAt. Item: { session, accounts, clientId, redirectUri, state, expiresAt }
 */

const axios = require('axios');
const crypto = require('crypto');
const AWS = require('aws-sdk');

const dynamodb = new AWS.DynamoDB.DocumentClient({ region: process.env.DYNAMODB_REGION || 'us-east-1' });

const TOKENS_TABLE = process.env.TOKENS_TABLE || 'AradWaterMeterTokens';
const AUTH_CODES_TABLE = process.env.AUTH_CODES_TABLE || 'AradWaterMeterAuthCodes';
const AUTH_SESSIONS_TABLE = process.env.AUTH_SESSIONS_TABLE || 'AradWaterMeterAuthSessions';
const ST_CLIENT_ID = process.env.ST_CLIENT_ID;
const ST_CLIENT_SECRET = process.env.ST_CLIENT_SECRET;
const API_BASE = 'https://eu-customerportal-api.harmonyencoremdm.com';

// ---------- helpers ----------

function randomToken() {
  return crypto.randomBytes(32).toString('hex');
}

function htmlResponse(statusCode, body) {
  return { statusCode, headers: { 'Content-Type': 'text/html; charset=utf-8' }, body };
}

function jsonResponse(statusCode, obj) {
  return { statusCode, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}

function redirectResponse(location) {
  return { statusCode: 302, headers: { Location: location }, body: '' };
}

function loginPageHtml({ clientId, redirectUri, state, session, error, meterCount }) {
  const heading = meterCount > 0
    ? `הוסף מד מים נוסף (${meterCount} כבר חוברו)`
    : 'חיבור מד המים שלך';
  return `
<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>חיבור מד מים - Read Your Meter Pro</title>
  <style>
    body { font-family: -apple-system, Arial, sans-serif; background: #f5f5f5; display: flex;
           align-items: center; justify-content: center; height: 100vh; margin: 0; }
    .card { background: #fff; padding: 32px; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            width: 100%; max-width: 360px; }
    h1 { font-size: 20px; margin-bottom: 8px; }
    p.sub { color: #666; font-size: 14px; margin-bottom: 24px; }
    label { display: block; font-size: 14px; margin-bottom: 6px; color: #333; }
    input { width: 100%; padding: 10px; margin-bottom: 16px; border: 1px solid #ccc;
            border-radius: 6px; font-size: 15px; box-sizing: border-box; }
    button { width: 100%; padding: 12px; background: #0091ff; color: #fff; border: none;
             border-radius: 6px; font-size: 15px; cursor: pointer; }
    button:hover { background: #0077cc; }
    .error { color: #d32f2f; font-size: 14px; margin-bottom: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>${heading}</h1>
    <p class="sub">התחבר עם פרטי ההתחברות שלך ל-Read Your Meter Pro</p>
    ${error ? `<div class="error">${error}</div>` : ''}
    <form method="POST" action="/authorize">
      <input type="hidden" name="client_id" value="${clientId || ''}" />
      <input type="hidden" name="redirect_uri" value="${redirectUri || ''}" />
      <input type="hidden" name="state" value="${state || ''}" />
      <input type="hidden" name="session" value="${session || ''}" />
      <label for="email">אימייל</label>
      <input type="email" id="email" name="email" required />
      <label for="password">סיסמה</label>
      <input type="password" id="password" name="password" required />
      <button type="submit">התחבר</button>
    </form>
  </div>
</body>
</html>`;
}

function confirmPageHtml({ clientId, redirectUri, state, session, meterCount }) {
  return `
<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>חיבור מד מים - Read Your Meter Pro</title>
  <style>
    body { font-family: -apple-system, Arial, sans-serif; background: #f5f5f5; display: flex;
           align-items: center; justify-content: center; height: 100vh; margin: 0; }
    .card { background: #fff; padding: 32px; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            width: 100%; max-width: 360px; text-align: center; }
    h1 { font-size: 20px; margin-bottom: 8px; }
    p.sub { color: #666; font-size: 14px; margin-bottom: 24px; }
    a.button { display: block; width: 100%; padding: 12px; border-radius: 6px; font-size: 15px;
               text-decoration: none; box-sizing: border-box; margin-bottom: 12px; }
    a.primary { background: #0091ff; color: #fff; }
    .check { font-size: 40px; margin-bottom: 12px; }
    button.secondary { background: #eee; color: #333; width: 100%; padding: 12px; border-radius: 6px;
                        font-size: 15px; border: none; cursor: pointer; }
  </style>
</head>
<body>
  <div class="card">
    <div class="check">✅</div>
    <h1>המד חובר בהצלחה!</h1>
    <p class="sub">סה"כ מדי מים מחוברים: ${meterCount}</p>
    <form method="GET" action="/authorize" style="margin-bottom:12px;">
      <input type="hidden" name="client_id" value="${clientId || ''}" />
      <input type="hidden" name="redirect_uri" value="${redirectUri || ''}" />
      <input type="hidden" name="state" value="${state || ''}" />
      <input type="hidden" name="session" value="${session || ''}" />
      <button type="submit" class="secondary">➕ הוסף מד מים נוסף</button>
    </form>
    <a class="button primary" href="/finish?session=${encodeURIComponent(session)}">✔ סיים</a>
  </div>
</body>
</html>`;
}

async function verifyAradCredentials(email, password) {
  const resp = await axios.post(`${API_BASE}/consumer/login`, {
    email,
    pw: password,
    deviceId: 'smartthings-account-link',
  });
  if (!resp.data || !resp.data.token) {
    throw new Error('Login failed');
  }
  return resp.data.token;
}

function parseBody(event) {
  const contentType = (event.headers && (event.headers['content-type'] || event.headers['Content-Type'])) || '';
  const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : (event.body || '');
  if (contentType.includes('application/json')) {
    return JSON.parse(raw || '{}');
  }
  return Object.fromEntries(new URLSearchParams(raw));
}

async function getSession(sessionId) {
  if (!sessionId) return null;
  const record = await dynamodb.get({ TableName: AUTH_SESSIONS_TABLE, Key: { session: sessionId } }).promise();
  return record.Item || null;
}

// ---------- route handlers ----------

async function handleAuthorizeGet(qs) {
  const { client_id: clientId, redirect_uri: redirectUri, state, session } = qs || {};
  const existing = await getSession(session);
  return htmlResponse(200, loginPageHtml({
    clientId,
    redirectUri,
    state,
    session: session || '',
    meterCount: existing ? existing.accounts.length : 0,
  }));
}

async function handleAuthorizePost(event) {
  const body = parseBody(event);
  const { client_id: clientId, redirect_uri: redirectUri, state, email, password } = body;
  let sessionId = body.session;

  let aradToken;
  try {
    aradToken = await verifyAradCredentials(email, password);
  } catch (err) {
    const existing = await getSession(sessionId);
    return htmlResponse(200, loginPageHtml({
      clientId,
      redirectUri,
      state,
      session: sessionId || '',
      meterCount: existing ? existing.accounts.length : 0,
      error: 'שם משתמש או סיסמה שגויים. נסה שוב.',
    }));
  }

  const expiresAt = Math.floor(Date.now() / 1000) + 1800;
  let accounts;

  if (sessionId) {
    const existing = await getSession(sessionId);
    accounts = existing ? [...existing.accounts, { email, password, aradToken }] : [{ email, password, aradToken }];
  } else {
    sessionId = randomToken();
    accounts = [{ email, password, aradToken }];
  }

  await dynamodb
    .put({
      TableName: AUTH_SESSIONS_TABLE,
      Item: { session: sessionId, accounts, clientId, redirectUri, state, expiresAt },
    })
    .promise();

  return htmlResponse(200, confirmPageHtml({
    clientId,
    redirectUri,
    state,
    session: sessionId,
    meterCount: accounts.length,
  }));
}

async function handleFinish(qs) {
  const sessionId = qs && qs.session;
  const session = await getSession(sessionId);

  if (!session) {
    return htmlResponse(400, '<p>Session expired or not found. Please start over.</p>');
  }

  const code = randomToken();
  const expiresAt = Math.floor(Date.now() / 1000) + 300;

  await dynamodb
    .put({
      TableName: AUTH_CODES_TABLE,
      Item: { code, accounts: session.accounts, expiresAt },
    })
    .promise();

  await dynamodb.delete({ TableName: AUTH_SESSIONS_TABLE, Key: { session: sessionId } }).promise();

  const redirectUrl = new URL(session.redirectUri);
  redirectUrl.searchParams.set('code', code);
  redirectUrl.searchParams.set('state', session.state);

  return redirectResponse(redirectUrl.toString());
}

async function handleToken(event) {
  const body = parseBody(event);

  let clientId = body.client_id;
  let clientSecret = body.client_secret;
  const authHeader = event.headers && (event.headers.authorization || event.headers.Authorization);
  if (authHeader && authHeader.startsWith('Basic ')) {
    const decoded = Buffer.from(authHeader.slice(6), 'base64').toString('utf8');
    [clientId, clientSecret] = decoded.split(':');
  }

  if (clientId !== ST_CLIENT_ID || clientSecret !== ST_CLIENT_SECRET) {
    return jsonResponse(401, { error: 'invalid_client' });
  }

  if (body.grant_type === 'authorization_code') {
    const record = await dynamodb.get({ TableName: AUTH_CODES_TABLE, Key: { code: body.code } }).promise();
    const item = record.Item;

    if (!item || item.expiresAt < Math.floor(Date.now() / 1000)) {
      return jsonResponse(400, { error: 'invalid_grant' });
    }

    const accessToken = randomToken();
    const refreshToken = randomToken();

    await dynamodb
      .put({
        TableName: TOKENS_TABLE,
        Item: { accessToken, refreshToken, accounts: item.accounts },
      })
      .promise();

    await dynamodb.delete({ TableName: AUTH_CODES_TABLE, Key: { code: body.code } }).promise();

    return jsonResponse(200, {
      access_token: accessToken,
      refresh_token: refreshToken,
      token_type: 'Bearer',
      expires_in: 31536000,
    });
  }

  if (body.grant_type === 'refresh_token') {
    const scanResult = await dynamodb
      .scan({
        TableName: TOKENS_TABLE,
        FilterExpression: 'refreshToken = :rt',
        ExpressionAttributeValues: { ':rt': body.refresh_token },
      })
      .promise();

    const item = scanResult.Items && scanResult.Items[0];
    if (!item) {
      return jsonResponse(400, { error: 'invalid_grant' });
    }

    const newRefreshToken = randomToken();

    await dynamodb
      .update({
        TableName: TOKENS_TABLE,
        Key: { accessToken: item.accessToken },
        UpdateExpression: 'SET refreshToken = :rt',
        ExpressionAttributeValues: { ':rt': newRefreshToken },
      })
      .promise();

    return jsonResponse(200, {
      access_token: item.accessToken,
      refresh_token: newRefreshToken,
      token_type: 'Bearer',
      expires_in: 31536000,
    });
  }

  return jsonResponse(400, { error: 'unsupported_grant_type' });
}

// ---------- entry point ----------

exports.handler = async (event) => {
  const path = event.path || (event.requestContext && event.requestContext.http && event.requestContext.http.path);
  const method = event.httpMethod || (event.requestContext && event.requestContext.http && event.requestContext.http.method);

  try {
    if (path === '/authorize' && method === 'GET') {
      return await handleAuthorizeGet(event.queryStringParameters);
    }
    if (path === '/authorize' && method === 'POST') {
      return await handleAuthorizePost(event);
    }
    if (path === '/finish' && method === 'GET') {
      return await handleFinish(event.queryStringParameters);
    }
    if (path === '/token' && method === 'POST') {
      return await handleToken(event);
    }
    return jsonResponse(404, { error: 'not_found' });
  } catch (err) {
    console.error(err);
    return jsonResponse(500, { error: 'server_error', message: err.message });
  }
};
