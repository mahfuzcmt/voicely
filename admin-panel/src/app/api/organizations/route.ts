import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { FieldValue } from 'firebase-admin/firestore';
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

    const db = getAdminFirestore();
    const snapshot = await db.collection('organizations').orderBy('createdAt', 'desc').get();

    const organizations = [];

    for (const orgDoc of snapshot.docs) {
      const orgData = orgDoc.data();

      // Get current user and channel counts
      const [usersSnap, channelsSnap] = await Promise.all([
        db.collection('users').where('organizationId', '==', orgDoc.id).get(),
        db.collection('channels').where('organizationId', '==', orgDoc.id).get(),
      ]);

      // Get org admin info
      let orgAdminEmail = '';
      if (orgData.orgAdminId) {
        const adminDoc = await db.collection('admins').doc(orgData.orgAdminId).get();
        if (adminDoc.exists) {
          orgAdminEmail = adminDoc.data()?.email || '';
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

    const db = getAdminFirestore();

    // Check if org admin email already exists
    const existingSnap = await db.collection('admins').where('email', '==', orgAdminEmail.toLowerCase()).get();
    if (!existingSnap.empty) {
      return NextResponse.json({ error: 'An admin with this email already exists' }, { status: 400 });
    }

    // Create organization
    const orgDocRef = await db.collection('organizations').add({
      name: name.trim(),
      packageMaxUsers: Number(packageMaxUsers),
      packageMaxChannels: Number(packageMaxChannels),
      orgAdminId: '', // will update after creating admin
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Create org admin
    const passwordHash = await hashPassword(orgAdminPassword);
    const adminDocRef = await db.collection('admins').add({
      email: orgAdminEmail.toLowerCase().trim(),
      displayName: orgAdminDisplayName.trim(),
      passwordHash,
      role: 'org_admin',
      organizationId: orgDocRef.id,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Update org with admin ID
    await db.collection('organizations').doc(orgDocRef.id).update({
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
