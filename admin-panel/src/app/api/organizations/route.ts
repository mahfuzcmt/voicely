import { NextRequest, NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import {
  collection,
  getDocs,
  addDoc,
  serverTimestamp,
  orderBy,
  query,
  where,
  doc,
  updateDoc,
} from 'firebase/firestore';
import { getAdminFromToken, hashPassword } from '@/lib/auth';
import { requireSuperAdmin } from '@/lib/authorization';

// GET all organizations (super admin only)
export async function GET() {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const denied = requireSuperAdmin(admin);
    if (denied) return denied;

    const orgsRef = collection(db, 'organizations');
    const q = query(orgsRef, orderBy('createdAt', 'desc'));
    const snapshot = await getDocs(q);

    const organizations = [];

    for (const orgDoc of snapshot.docs) {
      const orgData = orgDoc.data();

      // Get current user and channel counts
      const usersQuery = query(collection(db, 'users'), where('organizationId', '==', orgDoc.id));
      const channelsQuery = query(collection(db, 'channels'), where('organizationId', '==', orgDoc.id));

      const [usersSnap, channelsSnap] = await Promise.all([
        getDocs(usersQuery),
        getDocs(channelsQuery),
      ]);

      // Get org admin info
      let orgAdminEmail = '';
      if (orgData.orgAdminId) {
        const adminsQuery = query(collection(db, 'admins'), where('__name__', '==', orgData.orgAdminId));
        const adminSnap = await getDocs(adminsQuery);
        if (!adminSnap.empty) {
          orgAdminEmail = adminSnap.docs[0].data().email;
        }
      }

      organizations.push({
        id: orgDoc.id,
        name: orgData.name,
        packageMaxUsers: orgData.packageMaxUsers,
        packageMaxChannels: orgData.packageMaxChannels,
        orgAdminId: orgData.orgAdminId,
        orgAdminEmail,
        currentUsers: usersSnap.size,
        currentChannels: channelsSnap.size,
        createdAt: orgData.createdAt?.toDate?.() || null,
        updatedAt: orgData.updatedAt?.toDate?.() || null,
      });
    }

    return NextResponse.json({ organizations });
  } catch (error) {
    console.error('Error fetching organizations:', error);
    return NextResponse.json(
      { error: 'Failed to fetch organizations' },
      { status: 500 }
    );
  }
}

// POST create organization (super admin only)
export async function POST(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const denied = requireSuperAdmin(admin);
    if (denied) return denied;

    const body = await request.json();
    const {
      name,
      packageMaxUsers,
      packageMaxChannels,
      orgAdminEmail,
      orgAdminPassword,
      orgAdminDisplayName,
    } = body;

    if (!name?.trim()) {
      return NextResponse.json({ error: 'Organization name is required' }, { status: 400 });
    }
    if (!packageMaxUsers || packageMaxUsers < 1) {
      return NextResponse.json({ error: 'Max users must be at least 1' }, { status: 400 });
    }
    if (!packageMaxChannels || packageMaxChannels < 1) {
      return NextResponse.json({ error: 'Max channels must be at least 1' }, { status: 400 });
    }
    if (!orgAdminEmail?.trim() || !orgAdminPassword?.trim() || !orgAdminDisplayName?.trim()) {
      return NextResponse.json(
        { error: 'Org admin email, password, and display name are required' },
        { status: 400 }
      );
    }

    // Check if org admin email already exists
    const existingAdmin = query(collection(db, 'admins'), where('email', '==', orgAdminEmail.toLowerCase()));
    const existingSnap = await getDocs(existingAdmin);
    if (!existingSnap.empty) {
      return NextResponse.json({ error: 'An admin with this email already exists' }, { status: 400 });
    }

    // Create organization
    const orgsRef = collection(db, 'organizations');
    const orgDocRef = await addDoc(orgsRef, {
      name: name.trim(),
      packageMaxUsers: Number(packageMaxUsers),
      packageMaxChannels: Number(packageMaxChannels),
      orgAdminId: '', // will update after creating admin
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });

    // Create org admin
    const passwordHash = await hashPassword(orgAdminPassword);
    const adminsRef = collection(db, 'admins');
    const adminDocRef = await addDoc(adminsRef, {
      email: orgAdminEmail.toLowerCase().trim(),
      displayName: orgAdminDisplayName.trim(),
      passwordHash,
      role: 'org_admin',
      organizationId: orgDocRef.id,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });

    // Update org with admin ID
    await updateDoc(doc(db, 'organizations', orgDocRef.id), {
      orgAdminId: adminDocRef.id,
    });

    return NextResponse.json({
      success: true,
      organization: {
        id: orgDocRef.id,
        name: name.trim(),
        packageMaxUsers: Number(packageMaxUsers),
        packageMaxChannels: Number(packageMaxChannels),
        orgAdminEmail: orgAdminEmail.toLowerCase().trim(),
      },
    });
  } catch (error) {
    console.error('Error creating organization:', error);
    return NextResponse.json(
      { error: 'Failed to create organization' },
      { status: 500 }
    );
  }
}
