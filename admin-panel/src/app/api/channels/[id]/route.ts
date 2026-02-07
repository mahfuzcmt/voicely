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
} from 'firebase/firestore';
import { getAdminFromToken } from '@/lib/auth';

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
    const channelRef = doc(db, 'channels', id);
    const channelDoc = await getDoc(channelRef);

    if (!channelDoc.exists()) {
      return NextResponse.json({ error: 'Channel not found' }, { status: 404 });
    }

    return NextResponse.json({
      channel: {
        id: channelDoc.id,
        ...channelDoc.data(),
        createdAt: channelDoc.data().createdAt?.toDate?.() || null,
        updatedAt: channelDoc.data().updatedAt?.toDate?.() || null,
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
    const { name, description, isPrivate } = body;

    const channelRef = doc(db, 'channels', id);
    const channelDoc = await getDoc(channelRef);

    if (!channelDoc.exists()) {
      return NextResponse.json({ error: 'Channel not found' }, { status: 404 });
    }

    const updateData: Record<string, unknown> = {
      updatedAt: serverTimestamp(),
    };

    if (name !== undefined) updateData.name = name.trim();
    if (description !== undefined) updateData.description = description?.trim() || null;
    if (isPrivate !== undefined) updateData.isPrivate = isPrivate;

    await updateDoc(channelRef, updateData);

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
    const channelRef = doc(db, 'channels', id);
    const channelDoc = await getDoc(channelRef);

    if (!channelDoc.exists()) {
      return NextResponse.json({ error: 'Channel not found' }, { status: 404 });
    }

    // Delete members subcollection first
    const membersRef = collection(channelRef, 'members');
    const membersSnapshot = await getDocs(membersRef);
    for (const memberDoc of membersSnapshot.docs) {
      await deleteDoc(memberDoc.ref);
    }

    // Delete the channel
    await deleteDoc(channelRef);

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Error deleting channel:', error);
    return NextResponse.json(
      { error: 'Failed to delete channel' },
      { status: 500 }
    );
  }
}
