// One-time cleanup:
//   1. For memberIds that have no users/{uid} doc but DO exist in Firebase
//      Auth: backfill a users/{uid} doc from the Auth record (does NOT
//      remove them from the channel — they are real users).
//   2. For memberIds that exist in neither: remove from the channel's
//      memberIds (true orphans).
//
// Pass --apply to actually write; default is dry-run.
//
// Usage:
//   GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa.json node cleanup_memberids.js [--apply]

const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.applicationDefault() });
const db = admin.firestore();
const auth = admin.auth();

const APPLY = process.argv.includes('--apply');

async function lookupAuthUser(uid) {
  try {
    return await auth.getUser(uid);
  } catch (e) {
    if (e.code === 'auth/user-not-found') return null;
    console.warn(`  ! Auth lookup error for ${uid}: ${e.code}`);
    return null;
  }
}

// Look up many uids in Firebase Auth via the bulk API (up to 100 at a time).
// Much faster than calling getUser() sequentially.
async function lookupAuthUsers(uids) {
  const result = new Map();
  for (let i = 0; i < uids.length; i += 100) {
    const slice = uids.slice(i, i + 100);
    try {
      const res = await auth.getUsers(slice.map((u) => ({ uid: u })));
      for (const u of res.users) result.set(u.uid, u);
    } catch (e) {
      console.warn(`  ! Bulk auth lookup error:`, e.code || e.message);
    }
  }
  return result;
}

(async () => {
  console.log(APPLY ? '=== APPLY MODE ===' : '=== DRY RUN (pass --apply to write) ===');

  const channelsSnap = await db.collection('channels').get();
  console.log(`Scanning ${channelsSnap.size} channels...`);

  let totalBackfill = 0;
  let totalOrphan = 0;
  let channelsTouched = 0;

  for (const channelDoc of channelsSnap.docs) {
    const channelId = channelDoc.id;
    const data = channelDoc.data() || {};
    const name = data.name || '(unnamed)';
    const memberIds = Array.isArray(data.memberIds) ? data.memberIds : [];
    if (memberIds.length === 0) continue;

    const noDocIds = [];
    const batchSize = 10;
    for (let i = 0; i < memberIds.length; i += batchSize) {
      const batch = memberIds.slice(i, i + batchSize);
      const docs = await Promise.all(
        batch.map((id) => db.collection('users').doc(id).get())
      );
      docs.forEach((d, idx) => {
        if (!d.exists) noDocIds.push(batch[idx]);
      });
    }

    if (noDocIds.length === 0) continue;

    const authMap = await lookupAuthUsers(noDocIds);
    const backfill = [];
    const orphan = [];
    for (const uid of noDocIds) {
      const authUser = authMap.get(uid);
      if (authUser) backfill.push({ uid, authUser });
      else orphan.push(uid);
    }

    if (backfill.length === 0 && orphan.length === 0) continue;

    channelsTouched++;
    totalBackfill += backfill.length;
    totalOrphan += orphan.length;

    console.log(`\nChannel "${name}" (${channelId}) — ${memberIds.length} memberIds`);

    if (backfill.length > 0) {
      console.log(`  Backfill users/{uid} docs for ${backfill.length} real Auth users (kept as members):`);
      for (const { uid, authUser } of backfill) {
        const display = authUser.displayName || authUser.phoneNumber || authUser.email || uid.slice(0, 8);
        console.log(`    + ${uid} → displayName="${display}"`);
        if (APPLY) {
          await db.collection('users').doc(uid).set({
            displayName: display,
            phoneNumber: authUser.phoneNumber || null,
            email: authUser.email || null,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            autoCreatedBy: 'cleanup-script',
          }, { merge: true });
        }
      }
    }

    if (orphan.length > 0) {
      console.log(`  Remove ${orphan.length} memberIds that exist in neither Firestore nor Auth:`);
      orphan.forEach((id) => console.log(`    - ${id}`));
      if (APPLY) {
        const goodIds = memberIds.filter((id) => !orphan.includes(id));
        await channelDoc.ref.update({ memberIds: goodIds });
      }
    }
  }

  console.log(`\nSummary:`);
  console.log(`  Backfilled (kept): ${totalBackfill}`);
  console.log(`  Removed orphans:   ${totalOrphan}`);
  console.log(`  Channels touched:  ${channelsTouched}`);
  if (!APPLY) console.log('\nRe-run with --apply to commit.');
  process.exit(0);
})();
