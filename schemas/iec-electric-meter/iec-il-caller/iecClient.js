'use strict';

/**
 * Thin client for IEC's real APIs, ported 1:1 from the iec-api Python package
 * (iec_api/login.py + iec_api/data.py + iec_api/const.py) so behaviour matches
 * what the HA custom component and Postman collection already do successfully.
 */

const OKTA_BASE_URL = 'https://iec-ext.okta.com';
const IEC_OKTA_CLIENT_ID = '0oaqf6zr7yEcQZqqt2p7';
const IEC_APP_REDIRECT_URI = 'com.iecrn:/';
const IEC_API_BASE_URL = 'https://iecapi.iec.co.il/api/';

// IEC's API gateway checks these browser-ish headers - without them requests get rejected.
const IEC_HEADERS = {
  accept: 'application/json, text/plain, */*',
  origin: 'https://www.iec.co.il',
  referer: 'https://www.iec.co.il/',
  'x-iec-idt': '1',
  'x-iec-webview': '1',
  'user-agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
};

class IecApiError extends Error {}

/** Exchange a stored IEC refresh_token for a fresh id_token (Okta refresh grant). */
async function refreshIecToken(iecRefreshToken) {
  const res = await fetch(`${OKTA_BASE_URL}/oauth2/default/v1/token`, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: IEC_OKTA_CLIENT_ID,
      redirect_uri: IEC_APP_REDIRECT_URI,
      refresh_token: iecRefreshToken,
      grant_type: 'refresh_token',
      scope: 'openid email profile offline_access',
    }).toString(),
  });
  const data = await res.json();
  if (!res.ok) throw new IecApiError(data.error_description || `Okta refresh failed (${res.status})`);
  return data; // { access_token, refresh_token, id_token, expires_in, ... }
}

async function iecGet(path, idToken) {
  const res = await fetch(`${IEC_API_BASE_URL}${path}`, {
    headers: { ...IEC_HEADERS, Authorization: `Bearer ${idToken}` },
  });
  const rawText = await res.text();
  let data = null;
  try { data = JSON.parse(rawText); } catch (e) { /* not JSON - rawText itself is the useful diagnostic */ }

  if (!res.ok) {
    // Surface the actual body (often a WAF/CDN block page or a country-block message) instead
    // of a bare status code - this is the key diagnostic for figuring out *why* it's blocked.
    throw new IecApiError(`IEC API ${path} failed (${res.status}): ${rawText.slice(0, 500)}`);
  }
  // Most endpoints wrap the payload as { data: {...}, reponseDescriptor: { isSuccess, code, description } }
  if (data && Object.prototype.hasOwnProperty.call(data, 'reponseDescriptor')) {
    if (!data.reponseDescriptor.isSuccess && !data.data) {
      throw new IecApiError(data.reponseDescriptor.description || 'IEC API returned an error descriptor');
    }
    return data.data;
  }
  return data; // some endpoints (customer, devices) return the payload directly
}

/** GET /customer -> { bpNumber, firstName, lastName, accounts: [...] } */
async function getCustomer(idToken) {
  return iecGet('customer', idToken);
}

/** GET /customer/contract/{bpNumber} -> { contracts: [{ contractId, address, ... }], ... } */
async function getContracts(idToken, bpNumber) {
  const result = await iecGet(`customer/contract/${bpNumber}`, idToken);
  return (result && result.contracts) || [];
}

/**
 * GET /Device/LastMeterReading/{contractId}/{bpNumber}
 * -> { contractAccount, lastMeters: [{ serialNumber, meterReadings: [{ reading, readingDate, usage }] }] }
 * Returns the single most recent reading across all meters on the contract, or null.
 */
async function getLastMeterReading(idToken, bpNumber, contractId) {
  const result = await iecGet(`Device/LastMeterReading/${contractId}/${bpNumber}`, idToken);
  const meters = (result && result.lastMeters) || [];
  let best = null;
  for (const meter of meters) {
    for (const reading of meter.meterReadings || []) {
      if (reading.reading == null) continue;
      if (!best || new Date(reading.readingDate) > new Date(best.readingDate)) {
        best = reading;
      }
    }
  }
  return best; // { reading, readingDate, usage, readingCode, serialNumber } or null
}

/** GET /Device/{contractId} -> [{ deviceNumber, deviceCode, deviceType, isActive }, ...] */
async function getDevices(idToken, contractId) {
  const result = await iecGet(`Device/${contractId}`, idToken);
  return Array.isArray(result) ? result : [];
}

/**
 * POST /Consumption/RemoteReadingRange/{contractId} - the smart-meter "current" reading.
 * IEC rejects a stale lastInvoiceDate ("Last Invoice date older than 122" [days]), so this
 * must be a real recent reading date - pass the date from getLastMeterReading.
 * Takes an already-fetched `device` (from getDevices) to avoid a redundant call.
 * Returns { value, date } from futureConsumptionInfo (freshest available cumulative figure,
 * typically ~1 day old), or null if IEC didn't return usable data for this window.
 */
async function getSmartMeterCurrentReading(idToken, contractId, lastInvoiceDate, device) {
  if (!device) return null;

  const iso = lastInvoiceDate.toISOString().slice(0, 10);
  const res = await fetch(`${IEC_API_BASE_URL}Consumption/RemoteReadingRange/${contractId}`, {
    method: 'POST',
    headers: { ...IEC_HEADERS, Authorization: `Bearer ${idToken}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      contractNumber: contractId,
      lastInvoiceDate: iso,
      fromDate: iso,
      resolution: 1, // DAILY
      smartMetersList: [{ meterKind: 'Consumption', meterCode: String(device.deviceCode), meterSerial: String(device.deviceNumber) }],
    }),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok || !data || data.reportStatus !== 0) return null;

  const meter = (data.meterList || [])[0];
  const info = meter && meter.futureConsumptionInfo;
  if (!info || info.totalImport == null) return null;

  return { value: info.totalImport, date: info.currentDate || info.totalImportDate };
}

/**
 * GET /Device/{contractId}/{deviceId} -> { counterDevices: [{ connectionSize: { size, phase, representativeConnectionSize } }] }
 * Connection capacity (e.g. "3X40" = 3-phase, 40A) - static, rarely changes, but not present
 * for every contract (e.g. non-smart-meter contracts often return nothing usable here).
 * Takes an already-fetched `device` (from getDevices) to avoid a redundant call.
 */
async function getConnectionCapacity(idToken, contractId, device) {
  if (!device) return null;

  const detail = await iecGet(`Device/${contractId}/${device.deviceNumber}`, idToken);
  const counter = detail && detail.counterDevices && detail.counterDevices[0];
  const size = counter && counter.connectionSize;
  if (!size) return null;

  return { size: size.size, phase: size.phase, label: size.representativeConnectionSize };
}

/**
 * GET BillingCollection/invoices/{contractId}/{bpNumber} -> real, posted invoice history:
 * exact ₪ amounts, exact consumption, exact period dates. Ground truth, not an estimate -
 * but recent periods often show amountPaid: 0 (not yet posted by IEC), so this filters those
 * out and returns the most recent N periods that actually have a real posted amount.
 */
async function getRecentInvoices(idToken, contractId, bpNumber, count = 2) {
  const result = await iecGet(`BillingCollection/invoices/${contractId}/${bpNumber}`, idToken);
  const invoices = (result && result.invoices) || [];

  return invoices
    .filter((inv) => inv.amountPaid > 0) // skip unposted/zero periods
    .sort((a, b) => new Date(b.toDate) - new Date(a.toDate))
    .slice(0, count)
    .map((inv) => ({
      fromDate: inv.fromDate,
      toDate: inv.toDate,
      daysPeriod: inv.daysPeriod,
      consumptionKwh: inv.consumption,
      amountPaid: inv.amountPaid,
    }));
}

module.exports = {
  refreshIecToken,
  getCustomer,
  getContracts,
  getLastMeterReading,
  getDevices,
  getSmartMeterCurrentReading,
  getConnectionCapacity,
  getRecentInvoices,
  IecApiError,
};
