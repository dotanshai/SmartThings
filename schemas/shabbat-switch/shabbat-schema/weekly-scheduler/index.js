// Runs weekly. For every install in DynamoDB with a resolved location,
// pulls Hebcal's candle-lighting/Havdalah times and creates two one-time
// EventBridge schedules invoking the Trigger Lambda with
// { externalDeviceId, command }. externalDeviceId is used (not accessToken)
// because SmartThings periodically rotates the OAuth access token - a
// schedule created for next week would otherwise have a stale token baked
// into it by the time it actually fires.
//
// Env vars: INSTALLS_TABLE, TRIGGER_LAMBDA_ARN, SCHEDULER_ROLE_ARN
// Optional offsets: CANDLE_BASE_OFFSET_MIN (18), CANDLE_EXTRA_OFFSET_MIN (0),
//                    HAVDALAH_BASE_OFFSET_MIN (42), HAVDALAH_EXTRA_OFFSET_MIN (0)

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, ScanCommand } = require('@aws-sdk/lib-dynamodb');
const { SchedulerClient, CreateScheduleCommand, UpdateScheduleCommand } = require('@aws-sdk/client-scheduler');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const scheduler = new SchedulerClient({});

const TABLE = process.env.INSTALLS_TABLE;
const TRIGGER_LAMBDA_ARN = process.env.TRIGGER_LAMBDA_ARN;
const SCHEDULER_ROLE_ARN = process.env.SCHEDULER_ROLE_ARN;

const CANDLE_BASE_OFFSET_MIN = parseInt(process.env.CANDLE_BASE_OFFSET_MIN || '18', 10);
const CANDLE_EXTRA_OFFSET_MIN = parseInt(process.env.CANDLE_EXTRA_OFFSET_MIN || '0', 10);
const HAVDALAH_BASE_OFFSET_MIN = parseInt(process.env.HAVDALAH_BASE_OFFSET_MIN || '42', 10);
const HAVDALAH_EXTRA_OFFSET_MIN = parseInt(process.env.HAVDALAH_EXTRA_OFFSET_MIN || '0', 10);

exports.handler = async (event) => {
  // Optional: pass {"testDate": "2026-09-14"} in a manual invoke to simulate
  // "today" for testing (e.g. verifying a specific mid-week Yom Tov gets
  // detected) without waiting for the real date. Omit for normal operation.
  const testDate = event && event.testDate ? new Date(event.testDate) : null;

  const installs = await scanAllInstalls();
  const withLocation = installs.filter((i) => i.latitude && i.longitude);
  console.log(`Scheduling for ${withLocation.length}/${installs.length} installs (rest missing location)`);

  const results = await Promise.allSettled(withLocation.map((i) => scheduleForInstall(i, testDate)));
  const failures = results.filter((r) => r.status === 'rejected');
  if (failures.length) console.error(`${failures.length} failed:`, failures.map((f) => f.reason));
  return { total: withLocation.length, failed: failures.length };
};

async function scanAllInstalls() {
  const items = [];
  let ExclusiveStartKey;
  do {
    const res = await ddb.send(new ScanCommand({ TableName: TABLE, ExclusiveStartKey }));
    items.push(...(res.Items || []));
    ExclusiveStartKey = res.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return items;
}

async function scheduleForInstall(install, testDate) {
  const { accessToken, externalDeviceId, latitude, longitude, timeZoneId } = install;
  const tz = timeZoneId || 'Asia/Jerusalem';
  const candleExtra = install.candleOffsetMin != null ? install.candleOffsetMin : CANDLE_EXTRA_OFFSET_MIN;
  const havdalahExtra = install.havdalahOffsetMin != null ? install.havdalahOffsetMin : HAVDALAH_EXTRA_OFFSET_MIN;

  // Query a full 8-day window (not just "this week's Shabbat") using the
  // full Hebcal calendar API, which - unlike the "shabbat" convenience
  // endpoint - supports an explicit date range. This is required to catch
  // a standalone mid-week Yom Tov that doesn't touch that week's Shabbat
  // (e.g. Sukkot starting on a Monday), which the narrower endpoint misses.
  const start = testDate || new Date();
  const end = new Date(start);
  end.setDate(end.getDate() + 8);
  const fmt = (d) => d.toISOString().slice(0, 10);

  const url = `https://www.hebcal.com/hebcal?v=1&cfg=json&maj=on&min=off&mod=off&nx=off&mf=off&s=on` +
    `&c=on&geo=pos&latitude=${latitude}&longitude=${longitude}&tzid=${encodeURIComponent(tz)}` +
    `&b=${CANDLE_BASE_OFFSET_MIN}&m=${HAVDALAH_BASE_OFFSET_MIN}&start=${fmt(start)}&end=${fmt(end)}&leyning=off`;

  const res = await fetch(url);
  if (!res.ok) throw new Error(`Hebcal returned ${res.status} for ${externalDeviceId}`);
  const data = await res.json();

  const isChanukah = (item) => /chanukah|hanukkah|חנוכה/i.test(`${item.title || ''} ${item.memo || ''} ${item.hebrew || ''}`);
  const events = (data.items || [])
    .filter((i) => (i.category === 'candles' || i.category === 'havdalah') && !isChanukah(i))
    .map((i) => ({ type: i.category, date: new Date(i.date) }))
    .sort((a, b) => a.date - b.date);

  // Pair candle-lighting -> Havdalah into discrete on/off cycles. A
  // candle-lighting event seen while already "lit" is a contiguous
  // extension (e.g. Yom Tov running straight into Shabbat) and gets
  // merged into the same cycle; a gap between cycles (e.g. a standalone
  // mid-week Yom Tov, then ordinary weekdays, then Shabbat) produces
  // separate cycles instead of one incorrectly-long one.
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
  if (!cycles.length) throw new Error(`No candle/havdalah cycles found for ${externalDeviceId}`);

  const shortId = externalDeviceId.slice(0, 8);
  for (const cycle of cycles) {
    const candleTime = new Date(cycle.start);
    candleTime.setMinutes(candleTime.getMinutes() - candleExtra);
    const havdalahTime = new Date(cycle.end);
    havdalahTime.setMinutes(havdalahTime.getMinutes() + havdalahExtra);

    const tag = cycle.start.toISOString().slice(0, 10);
    await createOneTimeSchedule(`shb-on-${shortId}-${tag}`, candleTime, tz, externalDeviceId, 'on');
    await createOneTimeSchedule(`shb-off-${shortId}-${tag}`, havdalahTime, tz, externalDeviceId, 'off');
  }
}

async function createOneTimeSchedule(name, whenUtcDate, timeZoneId, externalDeviceId, command) {
  const at = toScheduleLocalString(whenUtcDate, timeZoneId);
  const params = {
    Name: name,
    ScheduleExpression: `at(${at})`,
    ScheduleExpressionTimezone: timeZoneId,
    FlexibleTimeWindow: { Mode: 'OFF' },
    ActionAfterCompletion: 'DELETE',
    Target: {
      Arn: TRIGGER_LAMBDA_ARN,
      RoleArn: SCHEDULER_ROLE_ARN,
      Input: JSON.stringify({ externalDeviceId, command }),
    },
  };
  try {
    await scheduler.send(new CreateScheduleCommand(params));
  } catch (err) {
    // A schedule with this name can already exist if offsets were edited
    // live via the app after this week's schedules were first created -
    // in that case, overwrite the existing one with the corrected time
    // instead of failing.
    if (err.name === 'ConflictException') {
      await scheduler.send(new UpdateScheduleCommand(params));
    } else {
      throw err;
    }
  }
}

function toScheduleLocalString(date, timeZone) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).formatToParts(date).reduce((acc, p) => ({ ...acc, [p.type]: p.value }), {});
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}`;
}
