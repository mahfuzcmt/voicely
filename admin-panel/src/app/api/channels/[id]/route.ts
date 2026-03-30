import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { FieldValue } from 'firebase-admin/firestore';
import { getAdminFromToken } from '@/lib/auth';
import { requireOrgAccess } from '@/lib/authorization';

// GET single channel
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { id } = await params;
    const db = getAdminFirestore();
    const channelDoc = await db.collection('channels').doc(id).get();

    if (!channelDoc.exists) {
      return NextResponse.json({ error: 'Channel not found' }, { status: 404 });
    }

    // Check org access
    const channelData = channelDoc.data()!;
    if (channelData.organizationId) {
      const denied = requireOrgAccess(admin, channelData.organizationId);
      if (denied) return denied;
    }

    return NextResponse.json({
      channel: {
        id: channelDoc.id,
        ...channelData,
        createdAt: channelData.createdAt?.toDate?.() || null,
        updatedAt: channelData.updatedAt?.toDate?.() || null,
      },
    });
  } catch (error) {
    console.error('Error fetching channel:', error);
    return NextResponse.json(
      { error: 'Failed to fetch channel' },
      { status: 500 }
    );
  }
}

// PUT update channel
export async function PUT(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { id } = await params;
    const body = await request.json();
    const { name, description, isPrivate, isActive } = body;

    const db = getAdminFirestore();
    const channelDoc = await db.collection('channels').doc(id).get();

    if (!channelDoc.exists) {
      return NextResponse.json({ error: 'Channel not found' }, { status: 404 });
    }

    // Check org access
    const channelData = channelDoc.data()!;
    if (channelData.organizationId) {
      const denied = requireOrgAccess(admin, channelData.organizationId);
      if (denied) return denied;
    }

    const updateData: Record<string, unknown> = {
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (name !== undefined) updateData.name = name.trim();
    if (description !== undefined) updateData.description = description?.trim() || null;
    if (isPrivate !== undefined) updateData.isPrivate = isPrivate;
    if (isActive !== undefined) updateData.isActive = isActive;

    await db.collection('channels').doc(id).update(updateData);

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Error updating channel:', error);
    return NextResponse.json(
      { error: 'Failed to update channel' },
      { status: 500 }
    );
  }
}

// DELETE channel
export async function DELETE(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { id } = await params;
    const db = getAdminFirestore();
    const channelDoc = await db.collection('channels').doc(id).get();

    if (!channelDoc.exists) {
      return NextResponse.json({ error: 'Channel not found' }, { status: 404 });
    }

    // Check org access
    const channelData = channelDoc.data()!;
    if (channelData.organizationId) {
      const denied = requireOrgAccess(admin, channelData.organizationId);
      if (denied) return denied;
    }

    // Delete members subcollection first
    const membersSnapshot = await db.collection('channels').doc(id).collection('members').get();
    for (const memberDoc of membersSnapshot.docs) {
      await memberDoc.ref.delete();
    }

    // Delete the channel
    await db.collection('channels').doc(id).delete();

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Error deleting channel:', error);
    return NextResponse.json(
      { error: 'Failed to delete channel' },
      { status: 500 }
    );
  }
}
