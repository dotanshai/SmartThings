'use strict';

/**
 * Runs in AWS's Israel (Tel Aviv) region - il-central-1 - specifically because iecapi.iec.co.il
 * blocks requests from AWS's us-east-1/eu-west-1 (confirmed via a generic WAF 403 page there).
 * This Lambda is invoked directly (AWS SDK Lambda invoke, not HTTP/API Gateway - no public
 * endpoint at all) by iec-schema-backend, which has to stay in eu-west-1 to match SmartThings'
 * own region routing for Israel-based accounts.
 *
 * Input event: { iecRefreshToken: string, includedContractIds?: string[], excludedContractIds?: string[] }
 * Output: { contracts: [{ contract, reading, capacity, recentInvoices }] } - same shape
 * iec-schema-backend expects from its own loadIecAccount, just computed here instead.
 */

const { refreshIecToken, getCustomer, getContracts, getDevices, getLastMeterReading, getSmartMeterCurrentReading, getConnectionCapacity, getRecentInvoices } = require('./iecClient');

// SmartThings calls discoveryRequest then immediately stateRefreshRequest, often landing in
// the same warm Lambda container seconds apart. Caching per-refreshToken here means the
// second call skips 3 serial round-trips (Okta refresh + customer + contracts) entirely -
// this only helps within a single warm container's lifetime, not across cold starts, but
// that's exactly the back-to-back pattern that risks tripping SmartThings' own client timeout.
const sessionCache = new Map(); // iecRefreshToken -> { idToken, expiresAt, customer, contracts }

async function getSession(iecRefreshToken) {
  const cached = sessionCache.get(iecRefreshToken);
  if (cached && cached.expiresAt > Date.now()) {
    return cached;
  }

  const fresh = await refreshIecToken(iecRefreshToken);
  const idToken = fresh.id_token;
  const customer = await getCustomer(idToken);
  const contracts = await getContracts(idToken, customer.bpNumber);

  const session = {
    idToken,
    // Refresh a bit before actual expiry to avoid edge-of-window failures.
    expiresAt: Date.now() + Math.max((fresh.expires_in || 3600) - 60, 30) * 1000,
    customer,
    contracts,
  };
  sessionCache.set(iecRefreshToken, session);
  return session;
}

exports.handler = async (event) => {
  const { iecRefreshToken, includedContractIds, excludedContractIds } = event;
  if (!iecRefreshToken) {
    throw new Error('iecRefreshToken is required');
  }

  const { idToken, customer, contracts: allContracts } = await getSession(iecRefreshToken);
  const bpNumber = customer.bpNumber;
  let contracts = allContracts;

  if (Array.isArray(includedContractIds) && includedContractIds.length) {
    contracts = contracts.filter((c) => includedContractIds.includes(c.contractId));
  }
  // Contract IDs are globally unique per physical IEC contract, so an exclude list is safe
  // across all users - it will only ever match the specific contract(s) it names, never
  // accidentally exclude someone else's real contract.
  if (Array.isArray(excludedContractIds) && excludedContractIds.length) {
    contracts = contracts.filter((c) => !excludedContractIds.includes(c.contractId));
  }

  const results = await Promise.all(
    contracts.map(async (contract) => {
      // Fetch once, share across both the smart-meter reading and capacity lookups below -
      // this used to be fetched 3x total per contract, which was most of the latency.
      const devicesPromise = getDevices(idToken, contract.contractId).catch(() => []);

      const billReading = await getLastMeterReading(idToken, bpNumber, contract.contractId).catch(() => null);
      const devices = await devicesPromise;
      const device = devices[0];

      let reading = billReading
        ? { reading: billReading.reading, readingDate: billReading.readingDate, source: 'bill' }
        : null;

      // These are all independent of each other - run in parallel instead of serially.
      const [smart, capacity, recentInvoices] = await Promise.all([
        contract.smartMeter && billReading && billReading.readingDate
          ? getSmartMeterCurrentReading(idToken, contract.contractId, new Date(billReading.readingDate), device).catch(() => null)
          : null,
        getConnectionCapacity(idToken, contract.contractId, device).catch(() => null),
        getRecentInvoices(idToken, contract.contractId, bpNumber, 2).catch(() => []),
      ]);

      if (smart) reading = { reading: smart.value, readingDate: smart.date, source: 'smart' };

      return { contract, reading, capacity, recentInvoices };
    })
  );

  return { contracts: results };
};
