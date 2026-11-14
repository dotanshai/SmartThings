# PalGate SmartThings Schema Connector - by Shai D. (uses pylgate, GPLv3)
import os, json, time, uuid, secrets, base64, logging
import urllib.request, urllib.parse, urllib.error
import boto3
import qrcode, qrcode.image.svg
import pylgate
from pylgate.types import TokenType

log = logging.getLogger()
log.setLevel(logging.INFO)

TABLE = boto3.resource('dynamodb', region_name=os.environ.get('TABLE_REGION', 'us-east-1')).Table(os.environ.get('TABLE', 'PalGateSchema'))
CLIENT_ID = os.environ.get('CLIENT_ID', '')
CLIENT_SECRET = os.environ.get('CLIENT_SECRET', '')
PG = 'https://api1.pal-es.com/v1/bt/'
UA = 'okhttp/4.9.3'
SESSION_TTL = 1800
TOKEN_LIFE = 10 * 365 * 86400
PROFILE_ID = os.environ.get('PROFILE_ID', '')
CAP_RESULT = os.environ.get('CAP_RESULT', '')
try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo('Asia/Jerusalem')
except Exception:
    TZ = None


# ---------- helpers ----------
def now():
    return int(time.time())

def db_get(pk):
    return TABLE.get_item(Key={'pk': pk}).get('Item')

def db_put(item):
    TABLE.put_item(Item=item)

def db_del(pk):
    TABLE.delete_item(Key={'pk': pk})

def pg_get(path, creds=None, timeout=15):
    h = {'User-Agent': UA}
    if creds:
        h['X-Bt-Token'] = pylgate.generate_token(bytes.fromhex(creds['token']), int(creds['phone']), TokenType(int(creds['type'])))
    req = urllib.request.Request(PG + path, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        body = e.read()
    except Exception as e:
        return {'status': 'failed', 'err': str(e)}
    try:
        return json.loads(body)
    except Exception:
        return {'status': 'failed', 'err': body[:200].decode('utf-8', 'replace')}

def resp(code, body, ctype='application/json', extra=None):
    h = {'Content-Type': ctype, 'Cache-Control': 'no-store, no-cache', 'Pragma': 'no-cache'}
    if extra:
        h.update(extra)
    if not isinstance(body, str):
        body = json.dumps(body, ensure_ascii=False)
    return {'statusCode': code, 'headers': h, 'body': body}

def html(code, body):
    return resp(code, body, 'text/html; charset=utf-8')

def new_short():
    return ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(6))

def valid_redirect(u):
    p = urllib.parse.urlparse(u or '')
    return p.scheme == 'https' and (p.hostname or '').endswith('.smartthings.com')


# ---------- HTML ----------
PAGE = '''<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PalGate - SmartThings</title>
<style>body{font-family:Arial,sans-serif;background:#f4f6f8;margin:0;padding:20px;color:#222}
.c{max-width:480px;margin:auto;background:#fff;border-radius:14px;padding:22px;box-shadow:0 2px 10px #0002;text-align:center}
.he{direction:rtl}.en{direction:ltr;color:#555;font-size:14px}
.link{font-size:20px;font-weight:bold;word-break:break-all;background:#eef5ff;padding:12px;border-radius:8px;margin:12px 0}
button{background:#1a73e8;color:#fff;border:0;border-radius:8px;padding:12px 18px;font-size:16px;margin:6px}
.ok{color:#188038;font-size:20px;font-weight:bold}.err{color:#c5221f;font-weight:bold}
svg{width:280px;height:280px}</style></head><body><div class="c">%BODY%</div></body></html>'''

PHONE_BODY = '''<h2>PalGate &#8596; SmartThings</h2>
<div class="he"><p><b>1.</b> \u05e4\u05ea\u05d7\u05d5 \u05d0\u05ea \u05d4\u05e7\u05d9\u05e9\u05d5\u05e8 \u05d4\u05d1\u05d0 <b>\u05d1\u05de\u05db\u05e9\u05d9\u05e8 \u05e0\u05d5\u05e1\u05e3</b> (\u05de\u05d7\u05e9\u05d1, \u05d8\u05d0\u05d1\u05dc\u05d8 \u05d0\u05d5 \u05d8\u05dc\u05e4\u05d5\u05df \u05d0\u05d7\u05e8):</p></div>
<div class="en"><p><b>1.</b> Open this link on <b>another device</b> (computer, tablet or another phone):</p></div>
<div class="link" id="lnk">%LINK%</div>
<button onclick="cp()">\u05d4\u05e2\u05ea\u05e7 / Copy</button><button onclick="sh()">\u05e9\u05ea\u05e3 / Share</button>
<div class="he"><p><b>2.</b> \u05e1\u05e8\u05e7\u05d5 \u05d0\u05ea \u05e7\u05d5\u05d3 \u05d4-QR \u05e9\u05d1\u05de\u05db\u05e9\u05d9\u05e8 \u05d4\u05e9\u05e0\u05d9 \u05e2\u05dd \u05d0\u05e4\u05dc\u05d9\u05e7\u05e6\u05d9\u05d9\u05ea PalGate \u05d1\u05d8\u05dc\u05e4\u05d5\u05df:<br>&#8942; &larr; Linked Devices &larr; Link a Device</p>
<p><b>3.</b> \u05d7\u05d6\u05e8\u05d5 \u05dc\u05db\u05d0\u05df \u05d5\u05dc\u05d7\u05e6\u05d5 <b>\u05d4\u05de\u05e9\u05da</b>. \u05d0\u05dc \u05ea\u05e1\u05d2\u05e8\u05d5 \u05d0\u05ea \u05d4\u05de\u05e1\u05da \u05d4\u05d6\u05d4!</p></div>
<div class="en"><p><b>2.</b> Scan the QR on the other device with the PalGate app: &#8942; &rarr; Linked Devices &rarr; Link a Device<br>
<b>3.</b> Come back here and tap <b>Continue</b>. Don't close this screen!</p></div>
<button id="go" onclick="tick(true)" style="font-size:20px;padding:16px 40px;background:#188038">\u05d4\u05de\u05e9\u05da / Continue</button>
<p id="st" class="en">\u05de\u05de\u05ea\u05d9\u05df \u05dc\u05e1\u05e8\u05d9\u05e7\u05d4... / Waiting for scan...</p>
<script>
var L="%LINK%",busy=false;
function msg(h){document.getElementById('st').innerHTML=h;}
function cp(){try{navigator.clipboard.writeText(L);msg('\u05d4\u05e7\u05d9\u05e9\u05d5\u05e8 \u05d4\u05d5\u05e2\u05ea\u05e7 / Link copied');}catch(e){}}
function sh(){if(navigator.share){navigator.share({url:L}).catch(function(){});}else{cp();}}
function tick(manual){if(busy)return;busy=true;fetch('/status?s=%CODE%',{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){busy=false;
 if(j.done){msg('<span class=ok>&#10004; \u05de\u05e7\u05d5\u05e9\u05e8! / Linked!</span>');location.href=j.redirect;return;}
 if(j.expired){msg('<span class=err>\u05e4\u05d2 \u05ea\u05d5\u05e7\u05e3 - \u05e1\u05d2\u05e8\u05d5 \u05d5\u05e0\u05e1\u05d5 \u05e9\u05d5\u05d1 / Expired - close and try again</span>');return;}
 if(manual){msg('<span class=err>\u05e2\u05d3\u05d9\u05d9\u05df \u05dc\u05d0 \u05e0\u05e1\u05e8\u05e7 - \u05e1\u05e8\u05e7\u05d5 \u05d0\u05ea \u05d4-QR \u05d1\u05de\u05db\u05e9\u05d9\u05e8 \u05d4\u05e9\u05e0\u05d9 / Not scanned yet - scan the QR on the other device</span>');}
 }).catch(function(){busy=false;});}
setInterval(function(){tick(false);},3000);
document.addEventListener('visibilitychange',function(){if(!document.hidden)tick(false);});
window.addEventListener('focus',function(){tick(false);});
tick(false);
</script>'''

PC_BODY = '''<h2>PalGate &#8596; SmartThings</h2>
<div class="he"><p>\u05d1\u05d0\u05e4\u05dc\u05d9\u05e7\u05e6\u05d9\u05d9\u05ea PalGate \u05d1\u05d8\u05dc\u05e4\u05d5\u05df: &#8942; &larr; Linked Devices &larr; Link a Device, \u05d5\u05e1\u05e8\u05e7\u05d5 \u05d0\u05ea \u05d4\u05e7\u05d5\u05d3. \u05ea\u05e0\u05d5 \u05dc\u05de\u05db\u05e9\u05d9\u05e8 \u05e9\u05dd (\u05dc\u05de\u05e9\u05dc SmartThings) \u05d5\u05d0\u05e9\u05e8\u05d5.</p></div>
<div class="en"><p>In the PalGate app on your phone: &#8942; &rarr; Linked Devices &rarr; Link a Device, scan this code, name it (e.g. SmartThings) and confirm.</p></div>
%QR%
<p id="st" class="en">\u05de\u05de\u05ea\u05d9\u05df \u05dc\u05e1\u05e8\u05d9\u05e7\u05d4... / Waiting for scan...</p>
<script>
function poll(){fetch('/poll?s=%CODE%',{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){
 if(j.done){document.getElementById('st').innerHTML='<span class=ok>&#10004; \u05de\u05e7\u05d5\u05e9\u05e8! \u05d7\u05d6\u05e8\u05d5 \u05dc\u05d0\u05e4\u05dc\u05d9\u05e7\u05e6\u05d9\u05d9\u05ea SmartThings \u05d1\u05d8\u05dc\u05e4\u05d5\u05df \u05d5\u05dc\u05d7\u05e6\u05d5 \u05d4\u05de\u05e9\u05da / Linked! Go back to SmartThings on your phone and tap Continue</span>';return;}
 if(j.expired){document.getElementById('st').innerHTML='<span class=err>\u05e4\u05d2 \u05ea\u05d5\u05e7\u05e3 - \u05d4\u05ea\u05d7\u05d9\u05dc\u05d5 \u05de\u05d7\u05d3\u05e9 \u05de\u05d4\u05d8\u05dc\u05e4\u05d5\u05df / Expired - start again from the phone</span>';return;}
 setTimeout(poll,500);}).catch(function(){setTimeout(poll,2000);});}
poll();
</script>'''

def page(body):
    return PAGE.replace('%BODY%', body)


# ---------- OAuth / linking ----------
def authorize(q, host):
    if CLIENT_ID and q.get('client_id') != CLIENT_ID:
        return html(400, page('<p class="err">Invalid client</p>'))
    ru = q.get('redirect_uri')
    if not valid_redirect(ru):
        return html(400, page('<p class="err">Invalid redirect_uri</p>'))
    short = new_short()
    db_put({'pk': 'sess#' + short, 'qrId': str(uuid.uuid4()), 'redirect': ru, 'state': q.get('state', ''),
            'status': 'pending', 'ttl': now() + SESSION_TTL})
    link = 'https://%s/l/%s' % (host, short)
    return html(200, page(PHONE_BODY.replace('%LINK%', link).replace('%CODE%', short)))

def pc_page(short):
    s = db_get('sess#' + short)
    if not s or int(s['ttl']) < now():
        return html(404, page('<p class="err">\u05e4\u05d2 \u05ea\u05d5\u05e7\u05e3 / Link expired</p>'))
    img = qrcode.make('{"id": "%s"}' % s['qrId'], image_factory=qrcode.image.svg.SvgPathImage, box_size=10)
    svg = img.to_string(encoding='unicode')
    return html(200, page(PC_BODY.replace('%QR%', svg).replace('%CODE%', short)))

def poll(short):
    s = db_get('sess#' + short)
    if not s or int(s['ttl']) < now():
        return resp(200, {'expired': True})
    if s['status'] == 'done':
        return resp(200, {'done': True})
    d = pg_get('un/secondary/init/' + s['qrId'], timeout=25)
    if d.get('status') == 'ok' and d.get('user'):
        creds = {'phone': str(d['user']['id']), 'token': d['user']['token'], 'type': int(d['secondary'])}
        chk = pg_get('secondary/status', creds)
        log.info('linked phone=...%s type=%s status=%s', creds['phone'][-4:], creds['type'], chk.get('status'))
        code = secrets.token_urlsafe(24)
        db_put({'pk': 'code#' + code, 'creds': creds, 'ttl': now() + 600})
        s.update({'status': 'done', 'authCode': code})
        db_put(s)
        return resp(200, {'done': True})
    return resp(200, {'done': False})

def status(short):
    s = db_get('sess#' + short)
    if not s or int(s['ttl']) < now():
        return resp(200, {'expired': True})
    if s['status'] != 'done':
        return resp(200, {'done': False})
    ru = s['redirect']
    url = ru + ('&' if '?' in ru else '?') + urllib.parse.urlencode({'code': s['authCode'], 'state': s['state']})
    return resp(200, {'done': True, 'redirect': url})

def issue(creds):
    acc, ref = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    db_put({'pk': 'acc#' + acc, 'creds': creds, 'ref': ref})
    db_put({'pk': 'ref#' + ref, 'creds': creds})
    return {'access_token': acc, 'refresh_token': ref, 'token_type': 'bearer', 'expires_in': TOKEN_LIFE}

def token(event, body):
    f = dict(urllib.parse.parse_qsl(body))
    cid, csec = f.get('client_id'), f.get('client_secret')
    auth = (event.get('headers') or {}).get('authorization', '')
    if auth.lower().startswith('basic '):
        try:
            cid, csec = base64.b64decode(auth[6:]).decode().split(':', 1)
        except Exception:
            pass
    if CLIENT_ID and (cid != CLIENT_ID or csec != CLIENT_SECRET):
        return resp(401, {'error': 'invalid_client'})
    gt = f.get('grant_type')
    if gt == 'authorization_code':
        c = db_get('code#' + f.get('code', ''))
        if not c or int(c['ttl']) < now():
            return resp(400, {'error': 'invalid_grant'})
        db_del('code#' + f['code'])
        return resp(200, issue(c['creds']))
    if gt == 'refresh_token':
        r = db_get('ref#' + f.get('refresh_token', ''))
        if not r:
            return resp(400, {'error': 'invalid_grant'})
        acc = secrets.token_urlsafe(32)
        db_put({'pk': 'acc#' + acc, 'creds': r['creds'], 'ref': f['refresh_token']})
        return resp(200, {'access_token': acc, 'refresh_token': f['refresh_token'], 'token_type': 'bearer', 'expires_in': TOKEN_LIFE})
    return resp(400, {'error': 'unsupported_grant_type'})


# ---------- ST Schema ----------
def hdr(req, itype):
    return {'schema': 'st-schema', 'version': '1.0', 'interactionType': itype, 'requestId': req['headers'].get('requestId')}

def hhmm():
    import datetime
    t = datetime.datetime.now(TZ) if TZ else datetime.datetime.utcnow() + datetime.timedelta(hours=2)
    return t.strftime('%d/%m %H:%M')

def res_key(creds, ext):
    return 'res#%s#%s' % (creds['phone'], ext)

def off_state(ext, creds=None, result=None):
    states = [{'component': 'main', 'capability': 'st.switch', 'attribute': 'switch', 'value': 'off'},
              {'component': 'main', 'capability': 'st.healthCheck', 'attribute': 'healthStatus', 'value': 'online'}]
    if CAP_RESULT and creds is not None:
        if result is None:
            r = db_get(res_key(creds, ext))
            result = r['text'] if r else '-'
        states.append({'component': 'main', 'capability': CAP_RESULT, 'attribute': 'lastResult', 'value': result[:100]})
    return {'externalDeviceId': ext, 'states': states}

def discovery(req, creds):
    d = pg_get('devices/', creds)
    out = []
    for x in d.get('devices', []):
        did = x.get('id') or x.get('_id')
        name = x.get('name1') or x.get('name') or did
        if x.get('localOnly'):
            log.info('skip BT-only %s', did)
            continue
        model = x.get('model') or 'PalGate'
        if not x.get('output1Disabled'):
            out.append({'externalDeviceId': did, 'deviceUniqueId': did, 'friendlyName': name,
                        'manufacturerInfo': {'manufacturerName': 'PalGate', 'modelName': model},
                        'deviceHandlerType': PROFILE_ID or 'c2c-switch'})
        if int(x.get('outputs') or 1) >= 2 and not x.get('output2Disabled'):
            out.append({'externalDeviceId': did + ':2', 'deviceUniqueId': did + ':2', 'friendlyName': name + ' (2)',
                        'manufacturerInfo': {'manufacturerName': 'PalGate', 'modelName': model},
                        'deviceHandlerType': PROFILE_ID or 'c2c-switch'})
    log.info('discovery status=%s devices=%d', d.get('status'), len(out))
    return {'headers': hdr(req, 'discoveryResponse'), 'requestGrantCallbackAccess': False, 'devices': out}

def open_gate(ext, creds):
    did, _, outn = ext.partition(':')
    d = pg_get('device/%s/open-gate?outputNum=%s' % (did, outn or '1'), creds)
    log.info('open %s -> %s', ext, json.dumps(d)[:300])
    if d.get('status') == 'ok' and d.get('confirmed'):
        return None
    if 'timed out' in str(d.get('err', '')):
        return 'No response / \u05dc\u05d0 \u05d4\u05d2\u05d9\u05d1'
    if d.get('status') == 'ok':
        return 'Not confirmed / \u05dc\u05d0 \u05d0\u05d5\u05e9\u05e8'
    return 'Error / \u05e9\u05d2\u05d9\u05d0\u05d4: ' + str(d.get('msg') or d.get('err') or 'unknown')[:40]

def command(req, creds):
    states = []
    for dev in req.get('devices', []):
        ext = dev['externalDeviceId']
        result = None
        for c in dev.get('commands', []):
            if c.get('capability') == 'st.switch' and c.get('command') == 'on':
                err = open_gate(ext, creds)
                if err:
                    log.warning('open failed %s: %s', ext, err)
                    result = '\u2716 %s %s' % (hhmm(), err)
                else:
                    result = '\u2714 %s Opened / \u05e0\u05e4\u05ea\u05d7' % hhmm()
                db_put({'pk': res_key(creds, ext), 'text': result})
        states.append(off_state(ext, creds, result))
    return {'headers': hdr(req, 'commandResponse'), 'deviceState': states}

def schema(body):
    req = json.loads(body)
    itype = req['headers']['interactionType']
    tok = (req.get('authentication') or {}).get('token', '')
    a = db_get('acc#' + tok) if tok else None
    log.info('ST %s token=..%s known=%s devices=%s', itype, tok[-4:], bool(a), [d.get('externalDeviceId') for d in req.get('devices', [])])
    if itype == 'integrationDeleted':
        if a:
            db_del('acc#' + tok)
            if a.get('ref'):
                db_del('ref#' + a['ref'])
        return resp(200, {'headers': hdr(req, 'integrationDeleted')})
    if not a:
        rt = {'discoveryRequest': 'discoveryResponse', 'stateRefreshRequest': 'stateRefreshResponse',
              'commandRequest': 'commandResponse'}.get(itype, 'interactionResult')
        return resp(200, {'headers': hdr(req, rt), 'globalError': {'errorEnum': 'TOKEN-EXPIRED', 'detail': 'Unknown token - please relink'}})
    creds = a['creds']
    if itype == 'discoveryRequest':
        return resp(200, discovery(req, creds))
    if itype == 'stateRefreshRequest':
        return resp(200, {'headers': hdr(req, 'stateRefreshResponse'),
                          'deviceState': [off_state(d['externalDeviceId'], creds) for d in req.get('devices', [])]})
    if itype == 'commandRequest':
        return resp(200, command(req, creds))
    return resp(200, {'headers': hdr(req, 'interactionResult')})


# ---------- router ----------
def handler(event, context):
    ctx = event.get('requestContext', {})
    m = ctx.get('http', {}).get('method', 'GET')
    p = event.get('rawPath', '/').rstrip('/') or '/'
    q = event.get('queryStringParameters') or {}
    body = event.get('body') or ''
    if event.get('isBase64Encoded'):
        body = base64.b64decode(body).decode('utf-8')
    try:
        if m == 'GET' and p == '/authorize':
            return authorize(q, ctx.get('domainName'))
        if m == 'GET' and p.startswith('/l/'):
            return pc_page(p[3:].upper())
        if m == 'GET' and p == '/poll':
            return poll(q.get('s', '').upper())
        if m == 'GET' and p == '/status':
            return status(q.get('s', '').upper())
        if m == 'POST' and p == '/token':
            return token(event, body)
        if m == 'GET' and p == '/icon.png':
            with open(os.path.join(os.path.dirname(__file__), 'icon.png'), 'rb') as f:
                return {'statusCode': 200, 'headers': {'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=86400'}, 'body': base64.b64encode(f.read()).decode(), 'isBase64Encoded': True}

        if m == 'POST' and p == '/schema':
            return schema(body)
        return resp(404, {'error': 'not found'})
    except Exception:
        log.exception('error on %s %s', m, p)
        return resp(500, {'error': 'internal'})
