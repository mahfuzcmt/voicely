import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore, getAdminAuth } from '@/lib/firebase-admin';
import { FieldValue } from 'firebase-admin/firestore';
import { getAdminFromToken } from '@/lib/auth';
import { requireSuperAdmin } from '@/lib/authorization';

// GET single organization
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const denied = requireSuperAdmin(admin);
    if (denied) return denied;

    const { id } = await params;
    const db = getAdminFirestore();
    const orgDoc = await db.collection('organizations').doc(id).get();

    if (!orgDoc.exists) {
      return NextResponse.json({ error: 'Organization not found' }, { status: 404 });
    }

    const orgData = orgDoc.data()!;

    // Get counts
    const [usersSnap, channelsSnap] = await Promise.all([
      db.collection('users').where('organizationId', '==', id).get(),
      db.collection('channels').where('organizationId', '==', id).get(),
    ]);

    // Get org admin info
    let orgAdmin = null;
    if (orgData.orgAdminId) {
      const adminDoc = await db.collection('admins').doc(orgData.orgAdminId).get();
      if (adminDoc.exists) {
        const adminData = adminDoc.data()!;
        orgAdmin = {
          id: adminDoc.id,
          email: adminData.email,
          displayName: adminData.displayName,
        };
      }
    }

    return NextResponse.json({
      organization: {
        id: orgDoc.id,
        ...orgData,
        currentUsers: usersSnap.size,
        currentChannels: channelsSnap.size,
        orgAdmin,
        createdAt: orgData.createdAt?.toDate?.() || null,
        updatedAt: orgData.updatedAt?.toDate?.() || null,
      },
    });
  } catch (error) {
    console.error('Error fetching organization:', error);
    return NextResponse.json(
      { error: 'Failed to fetch organization' },
      { status: 500 }
    );
  }
}

// PUT update organization
export async function PUT(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const denied = requireSuperAdmin(admin);
    if (denied) return denied;

    const { id } = await params;
    const body = await request.json();
    const { name, packageMaxUsers, packageMaxChannels } = body;

    const db = getAdminFirestore();
    const orgDoc = await db.collection('organizations').doc(id).get();

    if (!orgDoc.exists) {
      return NextResponse.json({ error: 'Organization not found' }, { status: 404 });
    }

    const updateData: Record<string, unknown> = {
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (name !== undefined) updateData.name = name.trim();
    if (packageMaxUsers !== undefined) updateData.packageMaxUsers = Number(packageMaxUsers);
    if (packageMaxChannels !== undefined) updateData.packageMaxChannels = Number(packageMaxChannels);

    await db.collection('organizations').doc(id).update(updateData);

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Error updating organization:', error);
    return NextResponse.json(
      { error: 'Failed to update organization' },
      { status: 500 }
    );
  }
}

// DELETE organization (cascading delete)
export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const denied = requireSuperAdmin(admin);
    if (denied) return denied;

    const { id } = await params;
    const db = getAdminFirestore();
    const orgDoc = await db.collection('organizations').doc(id).get();

    if (!orgDoc.exists) {
      return NextResponse.json({ error: 'Organization not found' }, { status: 404 });
    }

    const orgData = orgDoc.data()!;
    const adminAuth = getAdminAuth();

    // Delete all users in this org (Firestore + Firebase Auth)
    const usersSnap = await db.collection('users').where('organizationId', '==', id).get();
    for (const userDoc of usersSnap.docs) {
      try {
        await adminAuth.deleteUser(userDoc.id);
      } catch (authError: any) {
        if (authError.code !== 'auth/user-not-found') {
          console.warn(`Failed to delete auth user ${userDoc.id}:`, authError);
        }
      }
      await userDoc.ref.delete();
    }

    // Delete all channels in this org (including members subcollection)
    const channelsSnap = await db.collection('channels').where('organizationId', '==', id).get();
    for (const channelDoc of channelsSnap.docs) {
      const membersSnap = await channelDoc.ref.collection('members').get();
      for (const memberDoc of membersSnap.docs) {
        await memberDoc.ref.delete();
      }
      await channelDoc.ref.delete();
    }

    // Delete org admin
    if (orgData.orgAdminId) {
      await db.collection('admins').doc(orgData.orgAdminId).delete();
    }

    // Delete organization
    await db.collection('organizations').doc(id).delete();

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Error deleting organization:', error);
    return NextResponse.json(
      { error: 'Failed to delete organization' },
      { status: 500 }
    );
  }
}
