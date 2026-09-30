/**
 * Arad Water Meter - SmartThings Schema Connector backend Lambda (multi-account)
 *
 * Env vars required:
 *   ST_CLIENT_ID, ST_CLIENT_SECRET  - from your Schema App registration
 *   TOKENS_TABLE                    - partition key: accessToken. Item: { accessToken, refreshToken, accounts: [{email,password,aradToken}, ...] }
 *   RATES_TABLE                     - partition key: externalDeviceId
 *   DEVICE_ACCOUNTS_TABLE           - partition key: externalDeviceId. Item: { externalDeviceId, accessToken, accountIndex }
 *   DEVICE_PROFILE_ID               - the ST device profile ID for "Arad Water Meter"
 *
 * A single SmartThings installation can now be linked to MULTIPLE Arad
 * (rym-pro.com) accounts, e.g. two different logins for two separate
 * meters. Each meter still becomes its own SmartThings device
 * (arad-water-meter-<meterCount>), and DEVICE_ACCOUNTS_TABLE remembers
 * which Arad account (by index into the accounts array) owns each device,
 * so command handling (rate edits, alert toggles) can find the right
 * credentials without re-scanning every account.
 *
 * NOTE: Arad's login response does not document a token TTL. We re-login on any 401
 * from a data call rather than trying to guess expiry.
 */

const { SchemaConnector } = require('st-schema');
const axios = require('axios');
const AWS = require('aws-sdk');

const dynamodb = new AWS.DynamoDB.DocumentClient({ region: process.env.DYNAMODB_REGION || 'us-east-1' });

const TABLE_NAME = process.env.TOKENS_TABLE || 'AradWaterMeterTokens';
const RATES_TABLE = process.env.RATES_TABLE || 'AradWaterMeterRates';
const DEVICE_ACCOUNTS_TABLE = process.env.DEVICE_ACCOUNTS_TABLE || 'AradWaterMeterDeviceAccounts';
const DEVICE_PROFILE_ID = process.env.DEVICE_PROFILE_ID;
const API_BASE = 'https://eu-customerportal-api.harmonyencoremdm.com';

// Mirrors HA integration defaults (common/consts.py)
const DEFAULT_RATES = {
  lowRateConsumptionThreshold: 3.5, // m^3/month
  lowRateCost: 7.955, // ILS/m^3
  highRateCost: 14.6, // ILS/m^3
  sewageCost: 0, // ILS/m^3
};

// From enums.py - required for /consumer/myalerts/settings/{alertType} calls
const ALERT_TYPE = {
  DAILY_THRESHOLD: 12,
  LEAK: 23,
  CONSUMPTION_WHILE_AWAY: 1001,
};
const ALERT_CHANNEL = { EMAIL: 1, SMS: 3 };

async function getRates(externalDeviceId) {
  const record = await dynamodb
    .get({ TableName: RATES_TABLE, Key: { externalDeviceId } })
    .promise();
  return { ...DEFAULT_RATES, ...(record.Item || {}) };
}

async function setRate(externalDeviceId, field, value) {
  await dynamodb
    .update({
      TableName: RATES_TABLE,
      Key: { externalDeviceId },
      UpdateExpression: `SET ${field} = :v`,
      ExpressionAttributeValues: { ':v': value },
    })
    .promise();
}

/** Rounds to 1 decimal place for clean display in the app. */
function round1(n) {
  if (n === null || n === undefined) return n;
  return Math.round(n * 10) / 10;
}

/** Splits monthly consumption into low/high tariff bands and computes cost, same as HA. */
function computeCostBreakdown(monthlyConsumption, rates) {
  const lowRateConsumption = Math.min(monthlyConsumption, rates.lowRateConsumptionThreshold);
  const highRateConsumption = Math.max(monthlyConsumption - rates.lowRateConsumptionThreshold, 0);

  const lowRateTotalCost = lowRateConsumption * rates.lowRateCost;
  const highRateTotalCost = highRateConsumption * rates.highRateCost;
  const sewageTotalCost = monthlyConsumption * rates.sewageCost;
  const monthlyTotalCost = lowRateTotalCost + highRateTotalCost + sewageTotalCost;

  return {
    lowRateConsumption,
    highRateConsumption,
    lowRateTotalCost,
    highRateTotalCost,
    sewageTotalCost,
    monthlyTotalCost,
  };
}

// ---------- Multi-account helpers ----------

async function getAccounts(stAccessToken) {
  const record = await dynamodb
    .get({ TableName: TABLE_NAME, Key: { accessToken: stAccessToken } })
    .promise();
  if (!record.Item) {
    throw new Error('No stored Arad credentials for this SmartThings account');
  }
  return record.Item.accounts || [];
}

async function setDeviceAccount(externalDeviceId, stAccessToken, accountIndex) {
  await dynamodb
    .put({
      TableName: DEVICE_ACCOUNTS_TABLE,
      Item: { externalDeviceId, accessToken: stAccessToken, accountIndex },
    })
    .promise();
}

/** Looks up which account (by index) owns a given device. Defaults to 0 if not found. */
async function getDeviceAccountIndex(externalDeviceId) {
  const record = await dynamodb
    .get({ TableName: DEVICE_ACCOUNTS_TABLE, Key: { externalDeviceId } })
    .promise();
  return record.Item ? record.Item.accountIndex : 0;
}

// ---------- Arad API helpers ----------

async function aradLogin(email, password) {
  const resp = await axios.post(`${API_BASE}/consumer/login`, {
    email,
    pw: password,
    deviceId: 'smartthings-schema-connector',
  });
  if (!resp.data || !resp.data.token) {
    throw new Error(`Arad login failed: ${JSON.stringify(resp.data)}`);
  }
  return resp.data.token;
}

async function aradGet(path, aradToken) {
  return axios.get(`${API_BASE}${path}`, {
    headers: { 'x-access-token': aradToken },
  });
}

/** Returns a valid Arad token for this ST user's account at accountIndex, re-logging in if needed. */
async function getAradTokenForAccount(stAccessToken, accountIndex) {
  const accounts = await getAccounts(stAccessToken);
  const account = accounts[accountIndex];
  if (!account) {
    throw new Error(`No Arad account at index ${accountIndex} for this SmartThings installation`);
  }

  if (account.aradToken) {
    return account;
  }

  const aradToken = await aradLogin(account.email, account.password);
  await dynamodb
    .update({
      TableName: TABLE_NAME,
      Key: { accessToken: stAccessToken },
      UpdateExpression: `SET accounts[${accountIndex}].aradToken = :t`,
      ExpressionAttributeValues: { ':t': aradToken },
    })
    .promise();

  return { ...account, aradToken };
}

async function refreshAradTokenForAccount(stAccessToken, accountIndex, email, password) {
  const aradToken = await aradLogin(email, password);
  await dynamodb
    .update({
      TableName: TABLE_NAME,
      Key: { accessToken: stAccessToken },
      UpdateExpression: `SET accounts[${accountIndex}].aradToken = :t`,
      ExpressionAttributeValues: { ':t': aradToken },
    })
    .promise();
  return aradToken;
}

/** Calls an Arad GET endpoint for a specific linked account, transparently re-logging in once on 401. */
async function aradGetWithRetry(path, stAccessToken, accountIndex) {
  let account = await getAradTokenForAccount(stAccessToken, accountIndex);
  try {
    return (await aradGet(path, account.aradToken)).data;
  } catch (err) {
    if (err.response && err.response.status === 401) {
      const newToken = await refreshAradTokenForAccount(stAccessToken, accountIndex, account.email, account.password);
      return (await aradGet(path, newToken)).data;
    }
    throw err;
  }
}

async function getMeters(stAccessToken, accountIndex) {
  const data = await aradGetWithRetry('/consumer/meters', stAccessToken, accountIndex);
  return Array.isArray(data) ? data : [data];
}

async function getLastRead(stAccessToken, accountIndex) {
  const data = await aradGetWithRetry('/consumption/last-read', stAccessToken, accountIndex);
  console.error('RAW last-read response:', JSON.stringify(data));
  // API returns an array (even for a single meter) - unwrap it, same as getMeters
  const entry = Array.isArray(data) ? data[0] : data;
  return entry;
}

function formatDate(d) {
  return d.toISOString().slice(0, 10); // YYYY-MM-DD
}

async function getDailyConsumption(stAccessToken, meterCount, accountIndex) {
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);

  const todayStr = formatDate(today);
  const yesterdayStr = formatDate(yesterday);

  const data = await aradGetWithRetry(
    `/consumption/daily/${meterCount}/${yesterdayStr}/${todayStr}`,
    stAccessToken,
    accountIndex
  );

  const todayEntry = data.find((e) => e.consDate.startsWith(todayStr));
  const yesterdayEntry = data.find((e) => e.consDate.startsWith(yesterdayStr));

  return {
    today: todayEntry ? todayEntry.cons : null,
    yesterday: yesterdayEntry ? yesterdayEntry.cons : null,
  };
}

async function getMonthlyConsumption(stAccessToken, meterCount, accountIndex) {
  const now = new Date();
  const currentMonthStr = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  const lastDayOfMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0);
  const lastDayStr = formatDate(lastDayOfMonth);

  const data = await aradGetWithRetry(
    `/v1.1/consumption/monthly/${meterCount}/${currentMonthStr}/${lastDayStr}`,
    stAccessToken,
    accountIndex
  );

  const total = (data.consumptionData || []).reduce((sum, e) => sum + (e.cons || 0), 0);
  return total;
}

async function getForecast(stAccessToken, meterCount, accountIndex) {
  const data = await aradGetWithRetry(`/consumption/forecast/${meterCount}`, stAccessToken, accountIndex);
  return data.estimatedConsumption;
}

/** Enables/disables an alert channel. Mirrors rest_api.py: PUT to enable, DELETE to disable. */
async function setAlertSetting(stAccessToken, accountIndex, alertType, channel, enabled) {
  const account = await getAradTokenForAccount(stAccessToken, accountIndex);
  const url = `${API_BASE}/consumer/myalerts/settings/${alertType}`;
  const headers = { 'x-access-token': account.aradToken };
  const body = [channel];

  if (enabled) {
    await axios.put(url, body, { headers });
  } else {
    await axios.delete(url, { headers, data: body });
  }
}

async function getAlertSettings(stAccessToken, accountIndex) {
  try {
    const data = await aradGetWithRetry('/consumer/myalerts/settings', stAccessToken, accountIndex);
    return data;
  } catch (err) {
    console.error('Failed to fetch alert settings:', err.message);
    return null;
  }
}

/** Response is an array of only the ENABLED {alertTypeId, mediaTypeId} pairs. Absence = disabled. */
function isAlertEnabled(alertSettings, alertType, channel) {
  if (!Array.isArray(alertSettings)) return false;
  return alertSettings.some((a) => a.alertTypeId === alertType && a.mediaTypeId === channel);
}

// ---------- SmartThings Schema Connector ----------

const connector = new SchemaConnector()
  .clientId(process.env.ST_CLIENT_ID)
  .clientSecret(process.env.ST_CLIENT_SECRET)
  .discoveryHandler(async (accessToken, response) => {
    const accounts = await getAccounts(accessToken);

    for (let accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      const meters = await getMeters(accessToken, accountIndex);

      for (const meter of meters) {
        const externalDeviceId = `arad-water-meter-${meter.meterCount}`;
        const label = meter.fullAddress ? `Water Meter - ${meter.fullAddress}` : `Water Meter ${meter.meterCount}`;

        await setDeviceAccount(externalDeviceId, accessToken, accountIndex);

        response
          .addDevice(externalDeviceId, label, DEVICE_PROFILE_ID)
          .manufacturerName('Arad')
          .modelName('Read Your Meter Pro');
      }
    }
  })
  .stateRefreshHandler(async (accessToken, response) => {
    const accounts = await getAccounts(accessToken);

    for (let accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      const meters = await getMeters(accessToken, accountIndex);
      const lastRead = await getLastRead(accessToken, accountIndex);
      const alertSettings = await getAlertSettings(accessToken, accountIndex);

      for (const meter of meters) {
        const externalDeviceId = `arad-water-meter-${meter.meterCount}`;
        await setDeviceAccount(externalDeviceId, accessToken, accountIndex);

        // Sequential, not Promise.all - Arad's API appears to misbehave (returns null)
        // under concurrent requests on the same session token.
        const daily = await getDailyConsumption(accessToken, meter.meterCount, accountIndex);
        const monthly = await getMonthlyConsumption(accessToken, meter.meterCount, accountIndex);
        const forecast = await getForecast(accessToken, meter.meterCount, accountIndex);
        const rates = await getRates(externalDeviceId);

        const cost = computeCostBreakdown(monthly, rates);

        const states = [
          // --- vehiclepatch55148.meterMeasurements ---
          { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'lastRead',
            value: round1(lastRead.read), unit: 'm^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'dailyConsumption',
            value: round1(daily.today), unit: 'm^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'yesterdayConsumption',
            value: round1(daily.yesterday), unit: 'm^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'monthlyConsumption',
            value: round1(monthly), unit: 'm^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'monthlyForecast',
            value: round1(forecast), unit: 'm^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'highRateConsumption',
            value: round1(cost.highRateConsumption), unit: 'm^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'lowRateConsumption',
            value: round1(cost.lowRateConsumption), unit: 'm^3' },

          // --- vehiclepatch55148.meterExpenses ---
          { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'lowRateTotalCost',
            value: round1(cost.lowRateTotalCost), unit: 'ILS' },
          { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'highRateTotalCost',
            value: round1(cost.highRateTotalCost), unit: 'ILS' },
          { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'sewageTotalCost',
            value: round1(cost.sewageTotalCost), unit: 'ILS' },
          { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'monthlyTotalCost',
            value: round1(cost.monthlyTotalCost), unit: 'ILS' },

          // --- vehiclepatch55148.meterRateSettings (echo back current config) ---
          { component: 'main', capability: 'vehiclepatch55148.meterRateSettings', attribute: 'lowRateConsumptionThreshold',
            value: round1(rates.lowRateConsumptionThreshold), unit: 'm^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterRateSettings', attribute: 'lowRateCost',
            value: round1(rates.lowRateCost), unit: 'ILS/m^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterRateSettings', attribute: 'highRateCost',
            value: round1(rates.highRateCost), unit: 'ILS/m^3' },
          { component: 'main', capability: 'vehiclepatch55148.meterRateSettings', attribute: 'sewageCost',
            value: round1(rates.sewageCost), unit: 'ILS/m^3' },

          // --- vehiclepatch55148.meterWarnings ---
          { component: 'main', capability: 'vehiclepatch55148.meterWarnings', attribute: 'leakSms',
            value: isAlertEnabled(alertSettings, ALERT_TYPE.LEAK, ALERT_CHANNEL.SMS) ? 'on' : 'off' },
          { component: 'main', capability: 'vehiclepatch55148.meterWarnings', attribute: 'leakEmail',
            value: isAlertEnabled(alertSettings, ALERT_TYPE.LEAK, ALERT_CHANNEL.EMAIL) ? 'on' : 'off' },
          { component: 'main', capability: 'vehiclepatch55148.meterWarnings', attribute: 'thresholdSms',
            value: isAlertEnabled(alertSettings, ALERT_TYPE.DAILY_THRESHOLD, ALERT_CHANNEL.SMS) ? 'on' : 'off' },
          { component: 'main', capability: 'vehiclepatch55148.meterWarnings', attribute: 'thresholdEmail',
            value: isAlertEnabled(alertSettings, ALERT_TYPE.DAILY_THRESHOLD, ALERT_CHANNEL.EMAIL) ? 'on' : 'off' },
          { component: 'main', capability: 'vehiclepatch55148.meterWarnings', attribute: 'awaySms',
            value: isAlertEnabled(alertSettings, ALERT_TYPE.CONSUMPTION_WHILE_AWAY, ALERT_CHANNEL.SMS) ? 'on' : 'off' },
          { component: 'main', capability: 'vehiclepatch55148.meterWarnings', attribute: 'awayEmail',
            value: isAlertEnabled(alertSettings, ALERT_TYPE.CONSUMPTION_WHILE_AWAY, ALERT_CHANNEL.EMAIL) ? 'on' : 'off' },
        ];

        const validStates = states.filter((s) => s.value !== null && s.value !== undefined);
        const dropped = states.length - validStates.length;
        if (dropped > 0) {
          console.error(`Dropping ${dropped} null/undefined state value(s) for ${externalDeviceId}`);
        }

        response.addDevice(externalDeviceId, validStates);
      }
    }
  })
  .commandHandler(async (accessToken, response, devices) => {
    console.error('RAW commandHandler devices:', JSON.stringify(devices));
    for (const device of devices) {
      const { externalDeviceId, commands } = device;
      const resultStates = [];
      const accountIndex = await getDeviceAccountIndex(externalDeviceId);

      for (const cmd of commands) {
        const { capability, command, arguments: cmdArgs } = cmd;
        const value = cmdArgs && cmdArgs[0];

        try {
          if (capability === 'vehiclepatch55148.meterRateSettings') {
            const fieldMap = {
              setLowRateConsumptionThreshold: 'lowRateConsumptionThreshold',
              setLowRateCost: 'lowRateCost',
              setHighRateCost: 'highRateCost',
              setSewageCost: 'sewageCost',
            };
            const field = fieldMap[command];
            if (field) {
              await setRate(externalDeviceId, field, value);
              resultStates.push({ component: 'main', capability, attribute: field, value, unit: field.includes('Threshold') ? 'm^3' : 'ILS/m^3' });

              // Immediately recompute and push Cost too, so the app doesn't
              // need a full state refresh to see the effect of a rate change.
              const meterCount = externalDeviceId.replace('arad-water-meter-', '');
              const monthly = await getMonthlyConsumption(accessToken, meterCount, accountIndex);
              const rates = await getRates(externalDeviceId);
              const cost = computeCostBreakdown(monthly, rates);

              resultStates.push(
                { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'lowRateTotalCost', value: round1(cost.lowRateTotalCost), unit: 'ILS' },
                { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'highRateTotalCost', value: round1(cost.highRateTotalCost), unit: 'ILS' },
                { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'sewageTotalCost', value: round1(cost.sewageTotalCost), unit: 'ILS' },
                { component: 'main', capability: 'vehiclepatch55148.meterExpenses', attribute: 'monthlyTotalCost', value: round1(cost.monthlyTotalCost), unit: 'ILS' },
                { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'highRateConsumption', value: round1(cost.highRateConsumption), unit: 'm^3' },
                { component: 'main', capability: 'vehiclepatch55148.meterMeasurements', attribute: 'lowRateConsumption', value: round1(cost.lowRateConsumption), unit: 'm^3' },
              );
            }
          }

          if (capability === 'vehiclepatch55148.meterWarnings') {
            const alertMap = {
              setLeakSms: { type: ALERT_TYPE.LEAK, channel: ALERT_CHANNEL.SMS, attr: 'leakSms' },
              setLeakEmail: { type: ALERT_TYPE.LEAK, channel: ALERT_CHANNEL.EMAIL, attr: 'leakEmail' },
              setThresholdSms: { type: ALERT_TYPE.DAILY_THRESHOLD, channel: ALERT_CHANNEL.SMS, attr: 'thresholdSms' },
              setThresholdEmail: { type: ALERT_TYPE.DAILY_THRESHOLD, channel: ALERT_CHANNEL.EMAIL, attr: 'thresholdEmail' },
              setAwaySms: { type: ALERT_TYPE.CONSUMPTION_WHILE_AWAY, channel: ALERT_CHANNEL.SMS, attr: 'awaySms' },
              setAwayEmail: { type: ALERT_TYPE.CONSUMPTION_WHILE_AWAY, channel: ALERT_CHANNEL.EMAIL, attr: 'awayEmail' },
            };
            const mapping = alertMap[command];
            if (mapping) {
              const enabled = value === 'on';
              await setAlertSetting(accessToken, accountIndex, mapping.type, mapping.channel, enabled);
              resultStates.push({ component: 'main', capability, attribute: mapping.attr, value });
            }
          }
        } catch (err) {
          console.error(`Command ${command} failed for ${externalDeviceId}:`, err.message);
        }
      }

      response.addDevice(externalDeviceId, resultStates);
    }
  })
  .integrationDeletedHandler(async (accessToken) => {
    await dynamodb
      .delete({ TableName: TABLE_NAME, Key: { accessToken } })
      .promise();
  });

exports.handler = async (event, context) => {
  return connector.handleLambdaCallback(event, context);
};
