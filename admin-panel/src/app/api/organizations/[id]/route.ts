import { NextRequest, NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import {
  doc,
  getDoc,
  updateDoc,
  deleteDoc,
  serverTimestamp,
  collection,
  getDocs,
  query,
  where,
} from 'firebase/firestore';
import { getAdminFromToken } from '@/lib/auth';
import { requireSuperAdmin } from '@/lib/authorization';
import { getAdminAuth } from '@/lib/firebase-admin';

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
    const orgRef = doc(db, 'organizations', id);
    const orgDoc = await getDoc(orgRef);

    if (!orgDoc.exists()) {
      return NextResponse.json({ error: 'Organization not found' }, { status: 404 });
    }

    const orgData = orgDoc.data();

    // Get counts
    const usersQuery = query(collection(db, 'users'), where('organizationId', '==', id));
    const channelsQuery = query(collection(db, 'channels'), where('organizationId', '==', id));
    const [usersSnap, channelsSnap] = await Promise.all([
      getDocs(usersQuery),
      getDocs(channelsQuery),
    ]);

    // Get org admin info
    let orgAdmin = null;
    if (orgData.orgAdminId) {
      const adminDoc = await getDoc(doc(db, 'admins', orgData.orgAdminId));
      if (adminDoc.exists()) {
        const adminData = adminDoc.data();
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

    const orgRef = doc(db, 'organizations', id);
    const orgDoc = await getDoc(orgRef);

    if (!orgDoc.exists()) {
      return NextResponse.json({ error: 'Organization not found' }, { status: 404 });
    }

    const updateData: Record<string, unknown> = {
      updatedAt: serverTimestamp(),
    };

    if (name !== undefined) updateData.name = name.trim();
    if (packageMaxUsers !== undefined) updateData.packageMaxUsers = Number(packageMaxUsers);
    if (packageMaxChannels !== undefined) updateData.packageMaxChannels = Number(packageMaxChannels);

    await updateDoc(orgRef, updateData);

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
    const orgRef = doc(db, 'organizations', id);
    const orgDoc = await getDoc(orgRef);

    if (!orgDoc.exists()) {
      return NextResponse.json({ error: 'Organization not found' }, { status: 404 });
    }

    const orgData = orgDoc.data();
    const adminAuth = getAdminAuth();

    // Delete all users in this org (Firestore + Firebase Auth)
    const usersQuery = query(collection(db, 'users'), where('organizationId', '==', id));
    const usersSnap = await getDocs(usersQuery);
    for (const userDoc of usersSnap.docs) {
      try {
        await adminAuth.deleteUser(userDoc.id);
      } catch (authError: any) {
        if (authError.code !== 'auth/user-not-found') {
          console.warn(`Failed to delete auth user ${userDoc.id}:`, authError);
        }
      }
      await deleteDoc(userDoc.ref);
    }

    // Delete all channels in this org (including members subcollection)
    const channelsQuery = query(collection(db, 'channels'), where('organizationId', '==', id));
    const channelsSnap = await getDocs(channelsQuery);
    for (const channelDoc of channelsSnap.docs) {
      const membersRef = collection(channelDoc.ref, 'members');
      const membersSnap = await getDocs(membersRef);
      for (const memberDoc of membersSnap.docs) {
        await deleteDoc(memberDoc.ref);
      }
      await deleteDoc(channelDoc.ref);
    }

    // Delete org admin
    if (orgData.orgAdminId) {
      const adminRef = doc(db, 'admins', orgData.orgAdminId);
      await deleteDoc(adminRef);
    }

    // Delete organization
    await deleteDoc(orgRef);

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Error deleting organization:', error);
    return NextResponse.json(
      { error: 'Failed to delete organization' },
      { status: 500 }
    );
  }
}
