import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { FieldValue } from 'firebase-admin/firestore';
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
    const db = getAdminFirestore();

    // Verify user belongs to admin's org
    if (orgFilter) {
      const userDoc = await db.collection('users').doc(userId).get();
      if (userDoc.exists && userDoc.data()?.organizationId !== orgFilter) {
        return NextResponse.json({ error: 'Access denied' }, { status: 403 });
      }
    }

    // Find all channels where user is a member
    let queryRef = db.collection('channels').where('memberIds', 'array-contains', userId);

    if (orgFilter) {
      queryRef = queryRef.where('organizationId', '==', orgFilter);
    }

    const snapshot = await queryRef.get();
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
    const db = getAdminFirestore();

    // Get user info
    const userDoc = await db.collection('users').doc(userId).get();

    if (!userDoc.exists) {
      return NextResponse.json({ error: 'User not found' }, { status: 404 });
    }

    // Check org access for the user
    const userData = userDoc.data()!;
    if (userData.organizationId) {
      const denied = requireOrgAccess(admin, userData.organizationId);
      if (denied) return denied;
    }

    // Verify all requested channels belong to the org (for org_admin)
    if (orgFilter) {
      for (const channelId of channelIds) {
        const channelDoc = await db.collection('channels').doc(channelId).get();
        if (channelDoc.exists && channelDoc.data()?.organizationId !== orgFilter) {
          return NextResponse.json(
            { error: `Channel ${channelId} does not belong to your organization` },
            { status: 403 }
          );
        }
      }
    }

    // Get current channel memberships (scoped to org if needed)
    let currentMembershipsQuery = db.collection('channels').where('memberIds', 'array-contains', userId);
    if (orgFilter) {
      currentMembershipsQuery = currentMembershipsQuery.where('organizationId', '==', orgFilter);
    }
    const currentMemberships = await currentMembershipsQuery.get();
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
      const channelDoc = await db.collection('channels').doc(channelId).get();

      if (channelDoc.exists) {
        await db.collection('channels').doc(channelId).update({
          memberIds: FieldValue.arrayUnion(userId),
          memberCount: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        });

        await db.collection('channels').doc(channelId).collection('members').doc(userId).set({
          userId,
          channelId,
          role: 'member',
          isMuted: false,
          joinedAt: FieldValue.serverTimestamp(),
        });
      }
    }

    // Remove user from old channels
    for (const channelId of channelsToRemove) {
      const channelDoc = await db.collection('channels').doc(channelId).get();

      if (channelDoc.exists) {
        await db.collection('channels').doc(channelId).update({
          memberIds: FieldValue.arrayRemove(userId),
          memberCount: FieldValue.increment(-1),
          updatedAt: FieldValue.serverTimestamp(),
        });

        await db.collection('channels').doc(channelId).collection('members').doc(userId).delete();
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
