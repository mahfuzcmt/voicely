import { NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { FieldValue } from 'firebase-admin/firestore';
import { hashPassword } from '@/lib/auth';

// Super admin credentials
const SUPER_ADMIN_EMAIL = 'mahfuzcmt@gmail.com';
const SUPER_ADMIN_PASSWORD = '!Mahfuz20';
const SUPER_ADMIN_NAME = 'Super Admin';

// Default org for migration
const DEFAULT_ORG_NAME = 'Chatan';
const DEFAULT_ORG_ADMIN_EMAIL = 'chatan@voicelyent.xyz';
const DEFAULT_ORG_ADMIN_PASSWORD = '12345678';
const DEFAULT_ORG_ADMIN_NAME = 'Chatan Admin';
const DEFAULT_PACKAGE_MAX_USERS = 100;
const DEFAULT_PACKAGE_MAX_CHANNELS = 50;

export async function GET() {
  try {
    const db = getAdminFirestore();
    const results: string[] = [];

    // Step 1: Create or update super admin
    const superAdminSnap = await db.collection('admins').where('email', '==', SUPER_ADMIN_EMAIL).get();

    if (superAdminSnap.empty) {
      const passwordHash = await hashPassword(SUPER_ADMIN_PASSWORD);
      await db.collection('admins').add({
        email: SUPER_ADMIN_EMAIL,
        displayName: SUPER_ADMIN_NAME,
        passwordHash,
        role: 'super_admin',
        organizationId: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      results.push('Super admin created');
    } else {
      // Ensure super admin has organizationId: null and correct role
      const superAdminDoc = superAdminSnap.docs[0];
      const data = superAdminDoc.data();
      if (!data.organizationId && data.organizationId !== null) {
        await db.collection('admins').doc(superAdminDoc.id).update({
          organizationId: null,
          role: 'super_admin',
          updatedAt: FieldValue.serverTimestamp(),
        });
        results.push('Super admin updated with organizationId: null');
      } else {
        results.push('Super admin already exists');
      }
    }

    // Step 2: Create Chatan organization if not exists
    const orgSnap = await db.collection('organizations').where('name', '==', DEFAULT_ORG_NAME).get();

    let orgId: string;

    if (orgSnap.empty) {
      const orgDocRef = await db.collection('organizations').add({
        name: DEFAULT_ORG_NAME,
        packageMaxUsers: DEFAULT_PACKAGE_MAX_USERS,
        packageMaxChannels: DEFAULT_PACKAGE_MAX_CHANNELS,
        orgAdminId: '',
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      orgId = orgDocRef.id;
      results.push(`Organization "${DEFAULT_ORG_NAME}" created`);
    } else {
      orgId = orgSnap.docs[0].id;
      results.push(`Organization "${DEFAULT_ORG_NAME}" already exists`);
    }

    // Step 3: Create org admin for Chatan if not exists
    const orgAdminSnap = await db.collection('admins').where('email', '==', DEFAULT_ORG_ADMIN_EMAIL).get();

    if (orgAdminSnap.empty) {
      const passwordHash = await hashPassword(DEFAULT_ORG_ADMIN_PASSWORD);
      const orgAdminDocRef = await db.collection('admins').add({
        email: DEFAULT_ORG_ADMIN_EMAIL,
        displayName: DEFAULT_ORG_ADMIN_NAME,
        passwordHash,
        role: 'org_admin',
        organizationId: orgId,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Update org with admin ID
      await db.collection('organizations').doc(orgId).update({
        orgAdminId: orgAdminDocRef.id,
      });

      results.push(`Org admin "${DEFAULT_ORG_ADMIN_EMAIL}" created for ${DEFAULT_ORG_NAME}`);
    } else {
      results.push(`Org admin "${DEFAULT_ORG_ADMIN_EMAIL}" already exists`);

      // Ensure org has the admin linked
      const existingOrgAdmin = orgAdminSnap.docs[0];
      const orgDocSnap = orgSnap.empty ? null : orgSnap.docs[0];
      if (orgDocSnap && !orgDocSnap.data().orgAdminId) {
        await db.collection('organizations').doc(orgId).update({
          orgAdminId: existingOrgAdmin.id,
        });
        results.push('Linked existing org admin to organization');
      }
    }

    // Step 4: Migrate existing users without organizationId to Chatan
    const allUsersSnap = await db.collection('users').get();
    let migratedUsers = 0;

    const batch = db.batch();

    for (const userDoc of allUsersSnap.docs) {
      const data = userDoc.data();
      if (!data.organizationId) {
        batch.update(userDoc.ref, { organizationId: orgId });
        migratedUsers++;
      }
    }

    // Step 5: Migrate existing channels without organizationId to Chatan
    const allChannelsSnap = await db.collection('channels').get();
    let migratedChannels = 0;

    for (const channelDoc of allChannelsSnap.docs) {
      const data = channelDoc.data();
      if (!data.organizationId) {
        batch.update(channelDoc.ref, { organizationId: orgId });
        migratedChannels++;
      }
    }

    // Step 6: Migrate any admin docs with old role 'admin' to 'org_admin'
    const oldAdminsSnap = await db.collection('admins').where('role', '==', 'admin').get();
    let migratedAdmins = 0;

    for (const adminDoc of oldAdminsSnap.docs) {
      const data = adminDoc.data();
      batch.update(adminDoc.ref, {
        role: 'org_admin',
        organizationId: data.organizationId || orgId,
        updatedAt: FieldValue.serverTimestamp(),
      });
      migratedAdmins++;
    }

    // Commit batch
    await batch.commit();

    if (migratedUsers > 0) results.push(`Migrated ${migratedUsers} users to ${DEFAULT_ORG_NAME}`);
    if (migratedChannels > 0) results.push(`Migrated ${migratedChannels} channels to ${DEFAULT_ORG_NAME}`);
    if (migratedAdmins > 0) results.push(`Migrated ${migratedAdmins} admin(s) from 'admin' to 'org_admin'`);

    return NextResponse.json({
      message: 'Initialization complete',
      results,
    });
  } catch (error) {
    console.error('Init error:', error);
    return NextResponse.json(
      { error: 'Failed to initialize' },
      { status: 500 }
    );
  }
}
