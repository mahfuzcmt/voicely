import { NextRequest, NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import {
  doc,
  getDoc,
  getDocs,
  setDoc,
  deleteDoc,
  updateDoc,
  collection,
  query,
  where,
  serverTimestamp,
  arrayUnion,
  arrayRemove,
  increment,
} from 'firebase/firestore';
import { getAdminFromToken } from '@/lib/auth';
import { getOrgFilter, requireOrgAccess } from '@/lib/authorization';

// GET user's assigned channels
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { id: userId } = await params;
    const orgFilter = getOrgFilter(admin);

    // Verify user belongs to admin's org
    if (orgFilter) {
      const userDoc = await getDoc(doc(db, 'users', userId));
      if (userDoc.exists() && userDoc.data().organizationId !== orgFilter) {
        return NextResponse.json({ error: 'Access denied' }, { status: 403 });
      }
    }

    // Find all channels where user is a member
    const channelsRef = collection(db, 'channels');
    let q;
    if (orgFilter) {
      q = query(
        channelsRef,
        where('memberIds', 'array-contains', userId),
        where('organizationId', '==', orgFilter)
      );
    } else {
      q = query(channelsRef, where('memberIds', 'array-contains', userId));
    }
    const snapshot = await getDocs(q);

    const channelIds = snapshot.docs.map((doc) => doc.id);

    return NextResponse.json({ channelIds });
  } catch (error) {
    console.error('Error fetching user channels:', error);
    return NextResponse.json(
      { error: 'Failed to fetch user channels' },
      { status: 500 }
    );
  }
}

// PUT update user's channel assignments
export async function PUT(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { id: userId } = await params;
    const body = await request.json();
    const { channelIds = [] } = body;

    const orgFilter = getOrgFilter(admin);

    // Get user info
    const userRef = doc(db, 'users', userId);
    const userDoc = await getDoc(userRef);

    if (!userDoc.exists()) {
      return NextResponse.json({ error: 'User not found' }, { status: 404 });
    }

    // Check org access for the user
    const userData = userDoc.data();
    if (userData.organizationId) {
      const denied = requireOrgAccess(admin, userData.organizationId);
      if (denied) return denied;
    }

    // Verify all requested channels belong to the org (for org_admin)
    if (orgFilter) {
      for (const channelId of channelIds) {
        const channelDoc = await getDoc(doc(db, 'channels', channelId));
        if (channelDoc.exists() && channelDoc.data().organizationId !== orgFilter) {
          return NextResponse.json(
            { error: `Channel ${channelId} does not belong to your organization` },
            { status: 403 }
          );
        }
      }
    }

    // Get current channel memberships (scoped to org if needed)
    const channelsRef = collection(db, 'channels');
    let currentMembershipsQuery;
    if (orgFilter) {
      currentMembershipsQuery = query(
        channelsRef,
        where('memberIds', 'array-contains', userId),
        where('organizationId', '==', orgFilter)
      );
    } else {
      currentMembershipsQuery = query(
        channelsRef,
        where('memberIds', 'array-contains', userId)
      );
    }
    const currentMemberships = await getDocs(currentMembershipsQuery);
    const currentChannelIds = currentMemberships.docs.map((doc) => doc.id);

    // Channels to add
    const channelsToAdd = channelIds.filter(
      (id: string) => !currentChannelIds.includes(id)
    );

    // Channels to remove
    const channelsToRemove = currentChannelIds.filter(
      (id) => !channelIds.includes(id)
    );

    // Add user to new channels
    for (const channelId of channelsToAdd) {
      const channelRef = doc(db, 'channels', channelId);
      const channelDoc = await getDoc(channelRef);

      if (channelDoc.exists()) {
        await updateDoc(channelRef, {
          memberIds: arrayUnion(userId),
          memberCount: increment(1),
          updatedAt: serverTimestamp(),
        });

        const memberRef = doc(channelRef, 'members', userId);
        await setDoc(memberRef, {
          userId,
          channelId,
          role: 'member',
          isMuted: false,
          joinedAt: serverTimestamp(),
        });
      }
    }

    // Remove user from old channels
    for (const channelId of channelsToRemove) {
      const channelRef = doc(db, 'channels', channelId);
      const channelDoc = await getDoc(channelRef);

      if (channelDoc.exists()) {
        await updateDoc(channelRef, {
          memberIds: arrayRemove(userId),
          memberCount: increment(-1),
          updatedAt: serverTimestamp(),
        });

        const memberRef = doc(channelRef, 'members', userId);
        await deleteDoc(memberRef);
      }
    }

    return NextResponse.json({
      success: true,
      added: channelsToAdd.length,
      removed: channelsToRemove.length,
    });
  } catch (error) {
    console.error('Error updating user channels:', error);
    return NextResponse.json(
      { error: 'Failed to update user channels' },
      { status: 500 }
    );
  }
}
