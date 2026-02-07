import { NextRequest, NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import {
  collection,
  getDocs,
  addDoc,
  serverTimestamp,
  orderBy,
  query,
} from 'firebase/firestore';
import { getAdminFromToken } from '@/lib/auth';

// GET all channels
export async function GET() {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const channelsRef = collection(db, 'channels');
    const q = query(channelsRef, orderBy('createdAt', 'desc'));
    const snapshot = await getDocs(q);

    const channels = snapshot.docs.map((doc) => ({
      id: doc.id,
      ...doc.data(),
      createdAt: doc.data().createdAt?.toDate?.() || null,
      updatedAt: doc.data().updatedAt?.toDate?.() || null,
    }));

    return NextResponse.json({ channels });
  } catch (error) {
    console.error('Error fetching channels:', error);
    return NextResponse.json(
      { error: 'Failed to fetch channels' },
      { status: 500 }
    );
  }
}

// POST create channel
export async function POST(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const body = await request.json();
    const { name, description, isPrivate = false } = body;

    if (!name?.trim()) {
      return NextResponse.json(
        { error: 'Channel name is required' },
        { status: 400 }
      );
    }

    const channelsRef = collection(db, 'channels');
    const docRef = await addDoc(channelsRef, {
      name: name.trim(),
      description: description?.trim() || null,
      ownerId: admin.adminId,
      isPrivate,
      memberCount: 0,
      memberIds: [],
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });

    return NextResponse.json({
      success: true,
      channel: {
        id: docRef.id,
        name: name.trim(),
        description: description?.trim() || null,
        isPrivate,
        memberCount: 0,
        memberIds: [],
      },
    });
  } catch (error) {
    console.error('Error creating channel:', error);
    return NextResponse.json(
      { error: 'Failed to create channel' },
      { status: 500 }
    );
  }
}
