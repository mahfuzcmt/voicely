const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.applicationDefault() });
const db = admin.firestore();

(async () => {
  console.log('--- Top-level collections ---');
  const cols = await db.listCollections();
  cols.forEach(c => console.log(' -', c.id));

  console.log('\n--- Sample users (first 5) ---');
  const us = await db.collection('users').limit(5).get();
  us.forEach(d => {
    const data = d.data();
    console.log(' id=', d.id, 'fields=', Object.keys(data).join(','));
  });

  console.log('\n--- Users collection totals ---');
  const all = await db.collection('users').get();
  console.log(' Total user docs:', all.size);
  let withToken = 0;
  all.forEach(d => { if (d.data()?.fcmToken) withToken++; });
  console.log(' With fcmToken:', withToken);

  console.log('\n--- Firebase Auth lookup for one "missing" user ---');
  try {
    const u = await admin.auth().getUser('iWwbCwxOSVf0RV641NBJyH7Z0RV2');
    console.log(' Auth uid:', u.uid);
    console.log(' phone:', u.phoneNumber, 'displayName:', u.displayName);
    console.log(' lastSignIn:', u.metadata.lastSignInTime);
    console.log(' created:', u.metadata.creationTime);
  } catch (e) { console.log(' Auth lookup error:', e.code, e.message); }

  console.log('\n--- Channel info ---');
  const chan = await db.collection('channels').doc('5KjfQchHMfLpOFwsZ6Fv').get();
  console.log(' Name:', chan.data()?.name);
  console.log(' memberIds length:', (chan.data()?.memberIds || []).length);

  process.exit(0);
})();
