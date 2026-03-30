import { NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import {
  collection,
  query,
  where,
  getDocs,
  addDoc,
  updateDoc,
  doc,
  serverTimestamp,
  writeBatch,
} from 'firebase/firestore';
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
    const results: string[] = [];

    // Step 1: Create or update super admin
    const adminsRef = collection(db, 'admins');
    const superAdminQuery = query(adminsRef, where('email', '==', SUPER_ADMIN_EMAIL));
    const superAdminSnap = await getDocs(superAdminQuery);

    if (superAdminSnap.empty) {
      const passwordHash = await hashPassword(SUPER_ADMIN_PASSWORD);
      await addDoc(adminsRef, {
        email: SUPER_ADMIN_EMAIL,
        displayName: SUPER_ADMIN_NAME,
        passwordHash,
        role: 'super_admin',
        organizationId: null,
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      });
      results.push('Super admin created');
    } else {
      // Ensure super admin has organizationId: null and correct role
      const superAdminDoc = superAdminSnap.docs[0];
      const data = superAdminDoc.data();
      if (!data.organizationId && data.organizationId !== null) {
        await updateDoc(doc(db, 'admins', superAdminDoc.id), {
          organizationId: null,
          role: 'super_admin',
          updatedAt: serverTimestamp(),
        });
        results.push('Super admin updated with organizationId: null');
      } else {
        results.push('Super admin already exists');
      }
    }

    // Step 2: Create Chatan organization if not exists
    const orgsRef = collection(db, 'organizations');
    const orgQuery = query(orgsRef, where('name', '==', DEFAULT_ORG_NAME));
    const orgSnap = await getDocs(orgQuery);

    let orgId: string;

    if (orgSnap.empty) {
      const orgDocRef = await addDoc(orgsRef, {
        name: DEFAULT_ORG_NAME,
        packageMaxUsers: DEFAULT_PACKAGE_MAX_USERS,
        packageMaxChannels: DEFAULT_PACKAGE_MAX_CHANNELS,
        orgAdminId: '',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      });
      orgId = orgDocRef.id;
      results.push(`Organization "${DEFAULT_ORG_NAME}" created`);
    } else {
      orgId = orgSnap.docs[0].id;
      results.push(`Organization "${DEFAULT_ORG_NAME}" already exists`);
    }

    // Step 3: Create org admin for Chatan if not exists
    const orgAdminQuery = query(adminsRef, where('email', '==', DEFAULT_ORG_ADMIN_EMAIL));
    const orgAdminSnap = await getDocs(orgAdminQuery);

    if (orgAdminSnap.empty) {
      const passwordHash = await hashPassword(DEFAULT_ORG_ADMIN_PASSWORD);
      const orgAdminDocRef = await addDoc(adminsRef, {
        email: DEFAULT_ORG_ADMIN_EMAIL,
        displayName: DEFAULT_ORG_ADMIN_NAME,
        passwordHash,
        role: 'org_admin',
        organizationId: orgId,
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      });

      // Update org with admin ID
      await updateDoc(doc(db, 'organizations', orgId), {
        orgAdminId: orgAdminDocRef.id,
      });

      results.push(`Org admin "${DEFAULT_ORG_ADMIN_EMAIL}" created for ${DEFAULT_ORG_NAME}`);
    } else {
      results.push(`Org admin "${DEFAULT_ORG_ADMIN_EMAIL}" already exists`);

      // Ensure org has the admin linked
      const existingOrgAdmin = orgAdminSnap.docs[0];
      const orgDocSnap = orgSnap.empty ? null : orgSnap.docs[0];
      if (orgDocSnap && !orgDocSnap.data().orgAdminId) {
        await updateDoc(doc(db, 'organizations', orgId), {
          orgAdminId: existingOrgAdmin.id,
        });
        results.push('Linked existing org admin to organization');
      }
    }

    // Step 4: Migrate existing users without organizationId to Chatan
    const usersRef = collection(db, 'users');
    const allUsersSnap = await getDocs(usersRef);
    let migratedUsers = 0;

    const batchSize = 500;
    let batch = writeBatch(db);
    let batchCount = 0;

    for (const userDoc of allUsersSnap.docs) {
      const data = userDoc.data();
      if (!data.organizationId) {
        batch.update(userDoc.ref, { organizationId: orgId });
        batchCount++;
        migratedUsers++;

        if (batchCount >= batchSize) {
          await batch.commit();
          batch = writeBatch(db);
          batchCount = 0;
        }
      }
    }

    // Step 5: Migrate existing channels without organizationId to Chatan
    const channelsRef = collection(db, 'channels');
    const allChannelsSnap = await getDocs(channelsRef);
    let migratedChannels = 0;

    for (const channelDoc of allChannelsSnap.docs) {
      const data = channelDoc.data();
      if (!data.organizationId) {
        batch.update(channelDoc.ref, { organizationId: orgId });
        batchCount++;
        migratedChannels++;

        if (batchCount >= batchSize) {
          await batch.commit();
          batch = writeBatch(db);
          batchCount = 0;
        }
      }
    }

    // Step 6: Migrate any admin docs with old role 'admin' to 'org_admin'
    const oldAdminsQuery = query(adminsRef, where('role', '==', 'admin'));
    const oldAdminsSnap = await getDocs(oldAdminsQuery);
    let migratedAdmins = 0;

    for (const adminDoc of oldAdminsSnap.docs) {
      const data = adminDoc.data();
      batch.update(adminDoc.ref, {
        role: 'org_admin',
        organizationId: data.organizationId || orgId,
        updatedAt: serverTimestamp(),
      });
      batchCount++;
      migratedAdmins++;

      if (batchCount >= batchSize) {
        await batch.commit();
        batch = writeBatch(db);
        batchCount = 0;
      }
    }

    // Commit remaining batch
    if (batchCount > 0) {
      await batch.commit();
    }

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
