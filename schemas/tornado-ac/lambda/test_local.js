// Local test of the Node AUX client (read-only). Run: node test_local.js you@email.com yourPassword
const { AuxClient } = require('./index.js')._internal;
(async () => {
  const [email, password] = process.argv.slice(2);
  const aux = new AuxClient('usa');
  await aux.login(email, password);
  console.log('login OK, userid', aux.userid);
  for (const d of await aux.listDevices()) {
    const p = await aux.getParams(d);
    p.envtemp = await aux.getAmbient(d);
    console.log(d.endpointId, d.friendlyName, JSON.stringify(p));
  }
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
