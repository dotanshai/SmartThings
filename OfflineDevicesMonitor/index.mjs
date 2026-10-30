import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand, ScanCommand } from '@aws-sdk/lib-dynamodb';
import crypto from 'node:crypto';

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}), { marshallOptions: { removeUndefinedValues: true } });
const E = process.env;
const BASE = (E.BASE_URL || '').replace(/\/$/, '');
const API = 'https://api.smartthings.com/v1';
const TOKEN_URL = 'https://api.smartthings.com/oauth/token';
const AUTH_URL = 'https://api.smartthings.com/oauth/authorize';
const SCOPES = 'r:devices:* r:locations:*';
const SOUNDS = ['pushover','bike','bugle','cashregister','classical','cosmic','falling','gamelan','incoming','intermission','magic','mechanical','pianobar','siren','spacealarm','tugboat','alien','climb','persistent','echo','updown','vibrate','none'];
const ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="100%" height="100%"><rect width="64" height="64" rx="14" fill="#1565c0"/><path d="M14 32L32 16l18 16v18H14z" fill="#fff"/><rect x="27" y="38" width="10" height="12" rx="1" fill="#1565c0"/><circle cx="48" cy="18" r="10" fill="#e53935" stroke="#fff" stroke-width="3"/><path d="M48 12v7" stroke="#fff" stroke-width="3" stroke-linecap="round"/><circle cx="48" cy="23.5" r="1.8" fill="#fff"/></svg>';

const T = {
  he: { title: 'ניטור מכשירים לא מחוברים', intro: 'קבלו הודעה יומית ב-Telegram או ב-Pushover עם רשימת מכשירי SmartThings שאינם מחוברים.',
    privacy: 'פרטיות: נשמרים רק אסימון גישה לקריאה בלבד וההגדרות שלכם. ניתן לבטל בכל עת וכל הנתונים נמחקים.',
    again: 'כבר מחוברים? התחברו שוב כדי לחזור לדף ההגדרות.', connect: 'התחברות ל-SmartThings', lang: 'שפה', channel: 'ערוץ התראות',
    tgConnected: 'Telegram מחובר ✓', tgConnect: 'לחצו כאן לחיבור Telegram (ואז Start בבוט)', poKey: 'Pushover User Key',
    hour: 'שעת בדיקה יומית', tzNote: 'לפי אזור הזמן של המיקום', exclude: 'החרגה – סמנו מכשירים שלא לדווח עליהם', save: 'שמירה',
    test: 'שמירה ושליחת בדיקה', unsub: 'ביטול והסרת כל הנתונים', unsubQ: 'למחוק את כל הנתונים ולהפסיק את ההתראות?', unsubBtn: 'כן, מחק',
    unsubDone: 'הנתונים נמחקו וההרשאה בוטלה. אפשר לסגור את הדף.', saved: 'נשמר ✓', sent: 'נשלחה הודעת בדיקה ✓',
    offlineTitle: 'מכשירים לא מחוברים', allOnline: 'כל המכשירים מחוברים ✓', reauth: 'החיבור ל-SmartThings פג. יש להתחבר מחדש:',
    bookmark: 'שמרו את כתובת הדף הזה – זו הדרך לחזור להגדרות.', offline: 'לא מחובר', error: 'שגיאה', badLink: 'קישור לא תקין',
    notConfigured: 'יש לחבר Telegram או להזין Pushover User Key, ולבחור את הערוץ.', tgLinked: 'Telegram חובר! ההתראות יגיעו לכאן.' },
  en: { title: 'Offline Devices Monitor', intro: 'Get a daily Telegram or Pushover message listing your SmartThings devices that are offline.',
    privacy: 'Privacy: only a read-only access token and your settings are stored. Unsubscribe anytime and all data is deleted.',
    again: 'Already connected? Connect again to get back to your settings.', connect: 'Connect SmartThings', lang: 'Language', channel: 'Notification channel',
    tgConnected: 'Telegram connected ✓', tgConnect: 'Tap here to connect Telegram (then press Start in the bot)', poKey: 'Pushover User Key',
    hour: 'Daily check hour', tzNote: 'location time zone', exclude: 'Exclude – tick devices that should not be reported', save: 'Save',
    test: 'Save & send test', unsub: 'Unsubscribe and delete my data', unsubQ: 'Delete all data and stop notifications?', unsubBtn: 'Yes, delete',
    unsubDone: 'Your data was deleted and access revoked. You can close this page.', saved: 'Saved ✓', sent: 'Test message sent ✓',
    offlineTitle: 'Offline devices', allOnline: 'All devices are online ✓', reauth: 'SmartThings connection expired. Please reconnect:',
    bookmark: 'Bookmark this page – it is how you get back to your settings.', offline: 'offline', error: 'Error', badLink: 'Invalid link',
    notConfigured: 'Connect Telegram or enter a Pushover User Key, and select that channel.', tgLinked: 'Telegram connected! Alerts will arrive here.' }
};

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const html = (body, code = 200) => ({ statusCode: code, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }, body });
const redirect = loc => ({ statusCode: 302, headers: { location: loc, 'cache-control': 'no-store' }, body: '' });
const page = (lang, inner, code = 200) => html(`<!doctype html><html lang="${lang}" dir="${lang === 'he' ? 'rtl' : 'ltr'}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${T[lang].title}</title><link rel="icon" href="data:image/svg+xml,${encodeURIComponent(ICON)}"><style>:root{--bg:#f4f6f8;--card:#fff;--fg:#1f2328;--muted:#667085;--line:#e6e8eb;--pri:#1565c0;--sec:#546e7a;--bad:#c62828;--ok:#2e7d32}@media (prefers-color-scheme:dark){:root{--bg:#121417;--card:#1c1f24;--fg:#e8eaed;--muted:#9aa0a6;--line:#2c3036;--pri:#4f8fe8;--sec:#607d8b;--bad:#ef5350;--ok:#66bb6a}}*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;max-width:780px;margin:0 auto;padding:12px 16px 24px;background:var(--bg);color:var(--fg);line-height:1.45;font-size:16px}h2{font-size:22px;margin:8px 0}.card{background:var(--card);border-radius:12px;padding:14px 16px;margin:12px 0;box-shadow:0 1px 3px #0002;overflow-wrap:break-word}a{color:var(--pri)}a.btn,button{display:inline-flex;align-items:center;justify-content:center;min-height:44px;background:var(--pri);color:#fff;border:0;border-radius:10px;padding:10px 18px;font-size:16px;font-weight:600;text-decoration:none;cursor:pointer}button.sec{background:var(--sec)}.danger{background:var(--bad)!important}label{display:flex;align-items:center;flex-wrap:wrap;gap:4px;margin:8px 0}input[type=text],select{width:100%;padding:10px;font-size:16px;margin-top:4px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg)}input[type=checkbox],input[type=radio]{width:20px;height:20px;flex:none;accent-color:var(--pri);margin:0 6px}.devs{display:grid;grid-template-columns:1fr;gap:0 20px;margin-top:8px}.dev{display:flex;flex-wrap:nowrap;gap:8px;align-items:center;padding:8px 0;border-bottom:1px solid var(--line);margin:0;min-height:44px}.dev span:first-of-type{flex:1;min-width:0}.off{color:var(--bad);font-weight:700;font-size:13px;white-space:nowrap}.ok{color:var(--ok)}small{color:var(--muted)}.actions{position:sticky;bottom:0;display:flex;flex-wrap:wrap;gap:10px;padding:12px 0;background:linear-gradient(transparent,var(--bg) 30%)}.actions button{flex:1 1 140px}@media (min-width:700px){.devs{grid-template-columns:1fr 1fr}body{padding-top:24px}h2{font-size:26px}}.room{grid-column:1/-1;font-weight:700;margin-top:14px;padding:6px 0;border-bottom:2px solid var(--pri);color:var(--pri)}@media (max-width:480px){body{padding:8px 10px 16px}.card{padding:12px}h2{font-size:19px}.dev{min-height:40px;padding:6px 0;font-size:15px}}</style></head><body><h2 style="display:flex;align-items:center;gap:10px"><span style="width:40px;height:40px;flex:none">${ICON}</span>${T[lang].title}</h2>${inner}</body></html>`, code);

function pickLang(event, q) {
  if (q.lang === 'he' || q.lang === 'en') return q.lang;
  const al = (event.headers?.['accept-language'] || '').toLowerCase();
  return al.startsWith('he') || al.startsWith('iw') ? 'he' : 'en';
}

const put = rec => db.send(new PutCommand({ TableName: E.TABLE, Item: rec }));
async function getRec(id) { if (!id) return null; const r = await db.send(new GetCommand({ TableName: E.TABLE, Key: { id } })); return r.Item || null; }
async function auth(id, k) {
  const rec = await getRec(id); if (!rec || !k) return null;
  const a = Buffer.from(rec.key), b = Buffer.from(String(k));
  return a.length === b.length && crypto.timingSafeEqual(a, b) ? rec : null;
}

async function tokenReq(params) {
  const r = await fetch(TOKEN_URL, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', authorization: 'Basic ' + Buffer.from(`${E.CLIENT_ID}:${E.CLIENT_SECRET}`).toString('base64') }, body: new URLSearchParams({ client_id: E.CLIENT_ID, ...params }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) { const e = new Error(`token ${r.status} ${JSON.stringify(j)}`); e.status = r.status; throw e; }
  return j;
}
async function stGet(token, url) {
  const r = await fetch(url.startsWith('http') ? url : API + url, { headers: { authorization: `Bearer ${token}` } });
  if (!r.ok) { const e = new Error(`GET ${url} ${r.status} ${await r.text()}`); e.status = r.status; throw e; }
  return r.json();
}
async function getAccess(rec) {
  if (rec.accessToken && rec.accessExp > Date.now() + 300000) return rec.accessToken;
  const j = await tokenReq({ grant_type: 'refresh_token', refresh_token: rec.refreshToken });
  rec.accessToken = j.access_token; rec.refreshToken = j.refresh_token || rec.refreshToken;
  rec.accessExp = Date.now() + (j.expires_in || 86400) * 1000; rec.authFailed = false;
  await put(rec);
  return rec.accessToken;
}
async function pool(arr, n, fn) { let i = 0; await Promise.all(Array.from({ length: Math.min(n, arr.length) }, async () => { while (i < arr.length) await fn(arr[i++]); })); }

async function getDevices(token) {
  const items = [];
  let url = `${API}/devices?includeHealth=true`;
  while (url) { const j = await stGet(token, url); items.push(...(j.items || [])); url = j._links?.next?.href || null; }
  const need = items.filter(d => !d.healthState?.state);
  await pool(need, 8, async d => { try { d.healthState = await stGet(token, `/devices/${d.deviceId}/health`); } catch { d.healthState = { state: 'UNKNOWN' }; } });
  const rooms = {};
  for (const l of [...new Set(items.map(d => d.locationId))]) {
    try { const j = await stGet(token, `/locations/${l}/rooms`); for (const r of j.items || []) rooms[r.roomId] = r.name; } catch {}
  }
  return items.map(d => ({ id: d.deviceId, name: d.label || d.name, room: rooms[d.roomId] || '', state: d.healthState?.state || 'UNKNOWN' }))
    .sort((a, b) => (a.room + a.name).localeCompare(b.room + b.name));
}

async function tgSend(chat, text) {
  const r = await fetch(`https://api.telegram.org/bot${E.TG_TOKEN}/sendMessage`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ chat_id: chat, text: text.slice(0, 4000) }) });
  if (!r.ok) throw new Error('telegram ' + r.status + ' ' + await r.text());
}
const chans = rec => rec.channels || [rec.channel || 'telegram'];
async function notify(rec, title, text) {
  let sent = false; const errs = [];
  if (chans(rec).includes('pushover') && rec.poKey) {
    try {
      const r = await fetch('https://api.pushover.net/1/messages.json', { method: 'POST', body: new URLSearchParams({ token: rec.poToken || E.PO_TOKEN, user: rec.poKey, title, message: text.slice(0, 1000), ...(rec.poSound ? { sound: rec.poSound } : {}) }) });
      if (!r.ok) throw new Error('pushover ' + r.status + ' ' + await r.text());
      sent = true;
    } catch (e) { errs.push(e.message); }
  }
  if (chans(rec).includes('telegram') && rec.tgChat) {
    try { await tgSend(rec.tgChat, `${title}\n\n${text}`); sent = true; } catch (e) { errs.push(e.message); }
  }
  if (!sent && errs.length) throw new Error(errs.join('; '));
  return sent;
}
const configured = rec => chans(rec).some(ch => ch === 'pushover' ? !!rec.poKey : !!rec.tgChat);

async function runCheck(rec, force) {
  const t = T[rec.lang] || T.he;
  const devs = await getDevices(await getAccess(rec));
  const ex = new Set(rec.excluded || []);
  const off = devs.filter(d => d.state === 'OFFLINE' && !ex.has(d.id));
  if (!off.length) { if (force) await notify(rec, t.title, t.allOnline); return 0; }
  await notify(rec, `${t.offlineTitle} (${off.length})`, off.map(d => `• ${d.room ? d.room + ' – ' : ''}${d.name}`).join('\n'));
  return off.length;
}

function localParts(tz) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: tz || 'Asia/Jerusalem', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23' }).formatToParts(new Date()).map(x => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) };
}
async function scheduled() {
  const recs = []; let start;
  do { const r = await db.send(new ScanCommand({ TableName: E.TABLE, ExclusiveStartKey: start })); recs.push(...(r.Items || [])); start = r.LastEvaluatedKey; } while (start);
  for (const rec of recs) {
    const { date, hour } = localParts(rec.tz);
    if (hour !== Number(rec.hour ?? 5) || rec.lastRun === date) continue;
    rec.lastRun = date;
    try { console.log(rec.id, 'offline:', await runCheck(rec, false)); }
    catch (e) {
      console.error(rec.id, e.message);
      if (e.status >= 400 && e.status < 500 && !rec.authFailed) {
        rec.authFailed = true; const L = rec.lang || 'he';
        try { await notify(rec, T[L].title, `${T[L].reauth}\n${BASE}/?lang=${L}`); } catch {}
      }
    }
    await put(rec);
  }
}

function landing(lang) {
  const t = T[lang], other = lang === 'he' ? 'en' : 'he';
  return page(lang, `<div class="card"><p>${t.intro}</p><p><small>${t.privacy}</small></p><a class="btn" href="${BASE}/connect?lang=${lang}">${t.connect}</a><p><small>${t.again}</small></p></div><p><a href="${BASE}/?lang=${other}">${other === 'he' ? 'עברית' : 'English'}</a></p>`);
}

async function callback(q) {
  const lang = q.state === 'en' ? 'en' : 'he';
  if (!q.code) return page(lang, `<div class="card">${T[lang].error}: ${esc(q.error || 'no code')}</div>`, 400);
  const j = await tokenReq({ grant_type: 'authorization_code', code: q.code, redirect_uri: BASE + '/callback' });
  let id = null, tz = 'Asia/Jerusalem';
  try {
    const locs = (await stGet(j.access_token, '/locations')).items || [];
    locs.sort((a, b) => a.locationId.localeCompare(b.locationId));
    if (locs[0]) { id = locs[0].locationId; const d = await stGet(j.access_token, `/locations/${id}`); tz = d.timeZoneId || tz; }
  } catch (e) { console.error('locations', e.message); }
  id = id || j.installed_app_id || crypto.randomUUID();
  const old = await getRec(id);
  const rec = { ...(old || { id, key: crypto.randomBytes(16).toString('hex'), channel: 'telegram', hour: 5, lang, excluded: [], created: new Date().toISOString() }),
    tz, installedAppId: j.installed_app_id, accessToken: j.access_token, refreshToken: j.refresh_token, accessExp: Date.now() + (j.expires_in || 86400) * 1000, authFailed: false };
  await put(rec);
  return redirect(`${BASE}/settings?id=${encodeURIComponent(id)}&k=${rec.key}&new=1`);
}

async function settings(rec, q) {
  const L = rec.lang || 'he', t = T[L];
  let devs = [], err = '', sounds = SOUNDS.map(s => [s, s]);
  try { const sr = await fetch(`https://api.pushover.net/1/sounds.json?token=${rec.poToken || E.PO_TOKEN}`); const sj = await sr.json(); if (sj.sounds) sounds = Object.entries(sj.sounds); } catch (e) { console.error('sounds', e.message); }
  try { devs = await getDevices(await getAccess(rec)); } catch (e) { err = e.message; }
  const ex = new Set(rec.excluded || []);
  const tgLink = `https://t.me/${E.TG_BOT}?start=${encodeURIComponent(rec.id + '_' + rec.key.slice(0, 16))}`;
  const msg = q.saved ? t.saved : q.sent ? t.sent : q.nc ? t.notConfigured : '';
  const hours = Array.from({ length: 24 }, (_, h) => `<option value="${h}"${Number(rec.hour) === h ? ' selected' : ''}>${String(h).padStart(2, '0')}:00</option>`).join('');
  const groups = {}; for (const d of devs) (groups[d.room] ||= []).push(d);
  const rows = Object.entries(groups).map(([room, ds]) => `<div class="room">${esc(room || (L === 'he' ? 'ללא חדר' : 'No room'))}</div>` + ds.map(d => `<label class="dev"><input type="checkbox" name="ex" value="${esc(d.id)}"${ex.has(d.id) ? ' checked' : ''}><span>${esc(d.name)}</span>${d.state === 'OFFLINE' ? `<span class="off">${t.offline}</span>` : ''}</label>`).join('')).join('');
  return page(L, `${msg ? `<div class="card ${q.nc ? 'off' : 'ok'}">${msg}</div>` : ''}${q.new ? `<div class="card">${t.bookmark}</div>` : ''}${err ? `<div class="card off">${esc(err)}</div>` : ''}
<form method="post" action="${BASE}/settings" autocomplete="off"><input type="hidden" name="id" value="${esc(rec.id)}"><input type="hidden" name="k" value="${rec.key}">
<div class="card">${t.lang}: ${L === 'he' ? '<b>עברית</b>' : `<a href="${BASE}/settings?id=${encodeURIComponent(rec.id)}&k=${rec.key}&setlang=he">עברית</a>`} | ${L === 'en' ? '<b>English</b>' : `<a href="${BASE}/settings?id=${encodeURIComponent(rec.id)}&k=${rec.key}&setlang=en">English</a>`}</div>
<div class="card"><b>${t.channel}</b>
<label><input type="checkbox" name="channel" value="telegram"${chans(rec).includes('telegram') ? ' checked' : ''}> Telegram</label>
<div>${rec.tgChat ? `<span class="ok">${t.tgConnected}</span>` : `<a href="${tgLink}" target="_blank">${t.tgConnect}</a>`}</div>
<label><input type="checkbox" name="channel" value="pushover"${chans(rec).includes('pushover') ? ' checked' : ''}> Pushover</label>
<label>${t.poKey}<input type="text" name="poKey" value="${esc(rec.poKey || '')}" autocomplete="off"></label><label>${L === 'he' ? 'צליל התראה (Pushover)' : 'Notification sound (Pushover)'}<select name="poSound"><option value="">${L === 'he' ? 'ברירת המחדל של האפליקציה' : 'App default'}</option>${sounds.map(([v, n]) => `<option value="${esc(v)}"${rec.poSound === v ? ' selected' : ''}>${esc(n)}</option>`).join('')}</select></label></div>
<div class="card"><label>${t.hour} <small>(${t.tzNote}: ${esc(rec.tz)})</small><select name="hour">${hours}</select></label></div>
<div class="card"><b>${t.exclude}</b><div class="devs">${rows}</div></div>
<div class="actions"><button type="submit">${t.save}</button><button type="submit" class="sec" formaction="${BASE}/test">${t.test}</button></div></form>
<div class="card"><a class="btn danger" href="${BASE}/unsubscribe?id=${encodeURIComponent(rec.id)}&k=${rec.key}">${t.unsub}</a></div>`);
}

function applyForm(rec, f) {
  if (f.get('lang') === 'he' || f.get('lang') === 'en') rec.lang = f.get('lang');
  rec.channels = f.getAll('channel').filter(x => x === 'telegram' || x === 'pushover'); rec.channel = rec.channels[0] || 'telegram';
  rec.poKey = (f.get('poKey') || '').trim();
  const pt = (f.get('poToken') || '').trim(); rec.poToken = /^[A-Za-z0-9]{30}$/.test(pt) ? pt : '';
  const snd = (f.get('poSoundCustom') || '').trim() || (f.get('poSound') || '').trim(); rec.poSound = /^[A-Za-z0-9_-]{1,64}$/.test(snd) ? snd : '';
  const h = Number(f.get('hour')); rec.hour = h >= 0 && h < 24 ? h : 5;
  rec.excluded = f.getAll('ex');
}

async function telegram(event, body) {
  if (event.headers?.['x-telegram-bot-api-secret-token'] !== E.TG_SECRET) return { statusCode: 403, body: '' };
  try {
    const m = JSON.parse(body).message, chat = m?.chat?.id, text = m?.text || '';
    if (chat && text.startsWith('/start')) {
      const p = text.split(' ')[1] || '', i = p.lastIndexOf('_');
      const rec = i > 0 ? await getRec(p.slice(0, i)) : null, kp = p.slice(i + 1);
      if (rec && kp.length === 16 && rec.key.startsWith(kp)) { rec.tgChat = chat; rec.channels = [...new Set([...chans(rec), 'telegram'])]; await put(rec); await tgSend(chat, T[rec.lang || 'he'].tgLinked); }
      else await tgSend(chat, 'Open your settings page and tap the Telegram link.\nפתחו את דף ההגדרות ולחצו על קישור ה-Telegram.');
    }
  } catch (e) { console.error('tg', e); }
  return { statusCode: 200, body: 'ok' };
}

export const handler = async (event) => {
  if (event.source === 'aws.events' || event['detail-type'] === 'Scheduled Event') return scheduled();
  const method = event.requestContext?.http?.method || 'GET', path = event.rawPath || '/', q = event.queryStringParameters || {};
  let body = event.body || ''; if (event.isBase64Encoded) body = Buffer.from(body, 'base64').toString('utf8');
  try {
    if (path === '/telegram' && method === 'POST') return await telegram(event, body);
    const lang = pickLang(event, q);
    if (path === '/') return landing(lang);
    if (path === '/connect') return redirect(`${AUTH_URL}?` + new URLSearchParams({ client_id: E.CLIENT_ID, response_type: 'code', redirect_uri: BASE + '/callback', scope: SCOPES, state: lang }));
    if (path === '/callback') return await callback(q);
    if (!['/settings', '/test', '/unsubscribe'].includes(path)) return html('Not found', 404);
    const f = method === 'POST' ? new URLSearchParams(body) : null;
    const rec = await auth(f?.get('id') || q.id, f?.get('k') || q.k);
    if (!rec) return page(lang, `<div class="card off">${T[lang].badLink}</div>`, 403);
    const L = rec.lang || lang, t = T[L], self = `${BASE}/settings?id=${encodeURIComponent(rec.id)}&k=${rec.key}`;
    if (path === '/settings' && method === 'GET' && (q.setlang === 'he' || q.setlang === 'en')) { rec.lang = q.setlang; await put(rec); return redirect(self); }
    if (path === '/settings' && method === 'GET') return await settings(rec, q);
    if (path === '/settings' && method === 'POST') { applyForm(rec, f); await put(rec); return redirect(self + '&saved=1'); }
    if (path === '/test' && method === 'POST') {
      applyForm(rec, f); await put(rec);
      if (!configured(rec)) return redirect(self + '&nc=1');
      try { await runCheck(rec, true); } catch (e) { return page(rec.lang, `<div class="card off">${t.error}: ${esc(e.message)}</div><a class="btn" href="${self}">←</a>`, 500); }
      return redirect(self + '&sent=1');
    }
    if (path === '/unsubscribe' && method === 'GET') return page(L, `<div class="card"><p>${t.unsubQ}</p><form method="post" action="${BASE}/unsubscribe"><input type="hidden" name="id" value="${esc(rec.id)}"><input type="hidden" name="k" value="${rec.key}"><button class="danger" type="submit">${t.unsubBtn}</button></form></div>`);
    if (path === '/unsubscribe' && method === 'POST') {
      try { if (rec.installedAppId) { const tok = await getAccess(rec); const r = await fetch(`${API}/installedapps/${rec.installedAppId}`, { method: 'DELETE', headers: { authorization: `Bearer ${tok}` } }); console.log('revoke', r.status); } } catch (e) { console.error('revoke', e.message); }
      await db.send(new DeleteCommand({ TableName: E.TABLE, Key: { id: rec.id } }));
      return page(L, `<div class="card ok">${t.unsubDone}</div>`);
    }
    return html('Not found', 404);
  } catch (e) { console.error(e); return html(`<pre>${esc(e.message)}</pre>`, 500); }
};