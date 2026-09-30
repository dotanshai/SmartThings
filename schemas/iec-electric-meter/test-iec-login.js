'use strict';

/**
 * Standalone test for the real IEC login + data pipeline - no AWS, no SmartThings,
 * just your terminal. Run with:
 *
 *   node test-iec-login.js <idNumber>
 *
 * Requires Node.js 18+ (uses global fetch). It will:
 *   1. Validate the ID number checksum
 *   2. Start the Okta login, trigger an OTP
 *   3. Prompt you for the OTP code
 *   4. Complete the PKCE authorize + token exchange (real IEC refresh_token/id_token)
 *   5. Test the refresh_token grant (this is what the Lambda relies on every call)
 *   6. Pull your actual customer/contract/meter-reading data as a final sanity check
 *
 * If anything here fails or behaves differently than expected, better to find out
 * now than after it's wired into API Gateway + DynamoDB + SmartThings.
 */

const crypto = require('crypto');
const readline = require('readline/promises');
const { stdin, stdout } = require('process');

const OKTA_BASE_URL = 'https://iec-ext.okta.com';
const IEC_OKTA_CLIENT_ID = '0oaqf6zr7yEcQZqqt2p7';
const IEC_APP_REDIRECT_URI = 'com.iecrn:/';
const IEC_API_BASE_URL = 'https://iecapi.iec.co.il/api/';

const IEC_HEADERS = {
  accept: 'application/json, text/plain, */*',
  origin: 'https://www.iec.co.il',
  referer: 'https://www.iec.co.il/',
  'x-iec-idt': '1',
  'x-iec-webview': '1',
  'user-agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
};

function log(label, obj) {
  console.log(`\n--- ${label} ---`);
  console.log(typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2));
}

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

function base64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function generatePkce() {
  const verifier = base64url(crypto.randomBytes(32));
  const challenge = base64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
}

async function oktaPost(path, { json, form } = {}) {
  const headers = { accept: 'application/json' };
  let body;
  if (json) {
    headers['content-type'] = 'application/json';
    body = JSON.stringify(json);
  } else {
    headers['content-type'] = 'application/x-www-form-urlencoded';
    body = new URLSearchParams(form).toString();
  }
  const res = await fetch(`${OKTA_BASE_URL}${path}`, { method: 'POST', headers, body });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(`Okta ${path} -> ${res.status}: ${data.errorSummary || data.error_description || JSON.stringify(data)}`);
  }
  return data;
}

function factorType(factor) {
  const ft = factor.factorType || '';
  const email = (factor.profile && factor.profile.email) || '';
  if (ft === 'email' && email.includes('@sns.iec.co.il')) return 'sms';
  return ft;
}

async function getAuthFactors(idNumber) {
  const data = await oktaPost('/api/v1/authn', { json: { username: `${idNumber}@iec.co.il` } });
  return { stateToken: data.stateToken, factors: (data._embedded && data._embedded.factors) || [] };
}

async function verifyFactor(factorId, stateToken, passCode) {
  const body = { stateToken };
  if (passCode) body.passCode = passCode;
  const data = await oktaPost(`/api/v1/authn/factors/${factorId}/verify`, { json: body });
  log('factor verify raw response', data); // full visibility while testing
  return data.sessionToken;
}

async function authorizeSession(sessionToken) {
  const { verifier, challenge } = generatePkce();
  const state = base64url(crypto.randomBytes(6));
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
  if (!match) {
    log('authorize response (no code found - dumping for inspection)', text.slice(0, 2000));
    throw new Error('Could not extract authorization code from Okta response');
  }
  return { code: match[1], verifier };
}

async function getIecTokens(code, verifier) {
  return oktaPost('/oauth2/default/v1/token', {
    form: {
      client_id: IEC_OKTA_CLIENT_ID,
      code_verifier: verifier,
      grant_type: 'authorization_code',
      redirect_uri: IEC_APP_REDIRECT_URI,
      code,
    },
  });
}

async function refreshIecToken(refreshToken) {
  return oktaPost('/oauth2/default/v1/token', {
    form: {
      client_id: IEC_OKTA_CLIENT_ID,
      redirect_uri: IEC_APP_REDIRECT_URI,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
      scope: 'openid email profile offline_access',
    },
  });
}

async function iecGet(path, idToken) {
  const res = await fetch(`${IEC_API_BASE_URL}${path}`, {
    headers: { ...IEC_HEADERS, Authorization: `Bearer ${idToken}` },
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`IEC API ${path} -> ${res.status}: ${JSON.stringify(data)}`);
  if (data && Object.prototype.hasOwnProperty.call(data, 'reponseDescriptor')) {
    if (!data.reponseDescriptor.isSuccess && !data.data) {
      throw new Error(data.reponseDescriptor.description || 'IEC API returned an error descriptor');
    }
    return data.data;
  }
  return data;
}

async function iecPost(path, idToken, body) {
  const res = await fetch(`${IEC_API_BASE_URL}${path}`, {
    method: 'POST',
    headers: { ...IEC_HEADERS, Authorization: `Bearer ${idToken}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`IEC API ${path} -> ${res.status}: ${JSON.stringify(data)}`);
  return data;
}

function isoDate(d) {
  return d.toISOString().slice(0, 10);
}

// Granular smart-meter reading - much fresher than the bi-monthly LastMeterReading value.
// IEC rejects a stale/arbitrary lastInvoiceDate ("Last Invoice date older than 122" [days]),
// so this must be a real recent reading date - use the latest one from LastMeterReading.
async function getSmartMeterReading(idToken, contractId, lastInvoiceDate) {
  const devices = await iecGet(`Device/${contractId}`, idToken);
  if (!Array.isArray(devices) || !devices.length) {
    throw new Error('No devices returned for this contract');
  }
  const device = devices[0]; // { deviceNumber, deviceCode, deviceType, isActive }
  log('device for smart-meter probe', device);

  const body = {
    contractNumber: contractId,
    lastInvoiceDate: isoDate(lastInvoiceDate),
    fromDate: isoDate(lastInvoiceDate), // daily breakdown from the last invoice date to now
    resolution: 1, // DAILY
    smartMetersList: [
      { meterKind: 'Consumption', meterCode: String(device.deviceCode), meterSerial: String(device.deviceNumber) },
    ],
  };

  return iecPost(`Consumption/RemoteReadingRange/${contractId}`, idToken, body);
}

async function main() {
  const idNumber = process.argv[2];
  if (!idNumber) {
    console.error('Usage: node test-iec-login.js <idNumber>');
    process.exit(1);
  }
  if (!isValidIsraeliId(idNumber)) {
    console.error(`"${idNumber}" fails the Israeli ID checksum - double check it.`);
    process.exit(1);
  }

  const rl = readline.createInterface({ input: stdin, output: stdout });

  try {
    console.log(`Starting login for ID ${idNumber}...`);
    const { stateToken, factors } = await getAuthFactors(idNumber);
    log('factors available', factors.map((f) => ({ id: f.id, type: factorType(f) })));

    if (!factors.length) throw new Error('No MFA factors returned - cannot continue');
    const factor = factors.find((f) => factorType(f) === 'sms') || factors[0];
    console.log(`Using factor: ${factor.id} (${factorType(factor)})`);

    await verifyFactor(factor.id, stateToken); // triggers the OTP send
    console.log(`OTP sent via ${factorType(factor)}. Check your phone/email.`);

    const otpCode = await rl.question('Enter the OTP code: ');
    const sessionToken = await verifyFactor(factor.id, stateToken, otpCode.trim());
    if (!sessionToken) throw new Error('No sessionToken returned - OTP was likely rejected');
    console.log('OTP verified, got sessionToken.');

    const { code, verifier } = await authorizeSession(sessionToken);
    console.log('Got PKCE authorization code from Okta.');

    const tokens = await getIecTokens(code, verifier);
    log('IEC tokens (this is what gets stored, ttl is short by design)', {
      access_token: tokens.access_token?.slice(0, 20) + '...',
      refresh_token: tokens.refresh_token?.slice(0, 20) + '...',
      id_token: tokens.id_token?.slice(0, 20) + '...',
      expires_in: tokens.expires_in,
    });

    console.log('\nTesting refresh_token grant (this is what the Lambda calls on every discovery/state-refresh)...');
    const refreshed = await refreshIecToken(tokens.refresh_token);
    console.log(`Refresh OK, new id_token expires_in=${refreshed.expires_in}s`);

    console.log('\nPulling real account data as a final sanity check...');
    const customer = await iecGet('customer', refreshed.id_token);
    log('customer', { bpNumber: customer.bpNumber, name: `${customer.firstName} ${customer.lastName}` });

    const contractsResult = await iecGet(`customer/contract/${customer.bpNumber}`, refreshed.id_token);
    const contracts = (contractsResult && contractsResult.contracts) || [];
    log('contracts', contracts.map((c) => ({ contractId: c.contractId, address: c.address, smartMeter: c.smartMeter })));

    for (const contract of contracts) {
      const reading = await iecGet(`Device/LastMeterReading/${contract.contractId}/${customer.bpNumber}`, refreshed.id_token);
      log(`last meter reading - contract ${contract.contractId}`, reading);

      if (contract.smartMeter) {
        try {
          // Find the most recent official reading date to use as the required lastInvoiceDate.
          const allReadings = (reading.lastMeters || []).flatMap((m) => m.meterReadings || []);
          const latest = allReadings.reduce(
            (best, r) => (!best || new Date(r.readingDate) > new Date(best.readingDate) ? r : best),
            null
          );
          if (!latest) throw new Error('No official reading date found to use as lastInvoiceDate');

          const remote = await getSmartMeterReading(refreshed.id_token, contract.contractId, new Date(latest.readingDate));
          log(`smart-meter remote reading - contract ${contract.contractId}`, remote);
        } catch (e) {
          console.error(`Smart-meter remote reading failed for ${contract.contractId}: ${e.message}`);
        }
      }

      try {
        const devices = await iecGet(`Device/${contract.contractId}`, refreshed.id_token);
        const device = devices && devices[0];
        if (device && device.deviceNumber) {
          const detail = await iecGet(`Device/${contract.contractId}/${device.deviceNumber}`, refreshed.id_token);
          log(`connection capacity - contract ${contract.contractId}`, detail);
        } else {
          console.log(`No device found for contract ${contract.contractId} to look up connection capacity`);
        }
      } catch (e) {
        console.error(`Connection-capacity lookup failed for ${contract.contractId}: ${e.message}`);
      }

      try {
        const electricBill = await iecGet(`ElectricBillsDrawers/ElectricBills/${contract.contractId}/${customer.bpNumber}`, refreshed.id_token);
        log(`electric bill - contract ${contract.contractId}`, electricBill);
      } catch (e) {
        console.error(`Electric bill lookup failed for ${contract.contractId}: ${e.message}`);
      }

      try {
        const invoices = await iecGet(`BillingCollection/invoices/${contract.contractId}/${customer.bpNumber}`, refreshed.id_token);
        log(`billing invoices - contract ${contract.contractId}`, invoices);
      } catch (e) {
        console.error(`Billing invoices lookup failed for ${contract.contractId}: ${e.message}`);
      }
    }

    console.log('\nPulling official kWh tariff (public content page, less certain about auth requirements)...');
    try {
      const tariffPage = await iecGet('content/he-IL/content/tariffs/contentpages/homeelectricitytariff', refreshed.id_token);
      log('kWh tariff content page (raw)', tariffPage);
    } catch (e) {
      console.error(`Tariff content page failed: ${e.message}`);
    }

    console.log('\n✅ Full pipeline works end to end.');
  } catch (err) {
    console.error('\n❌ Failed:', err.message);
    process.exitCode = 1;
  } finally {
    rl.close();
  }
}

main();
