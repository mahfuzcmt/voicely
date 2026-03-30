import { NextRequest, NextResponse } from 'next/server';
import { db, storage } from '@/lib/firebase';
import {
  collection,
  getDocs,
  addDoc,
  serverTimestamp,
  orderBy,
  query,
  where,
} from 'firebase/firestore';
import { ref, uploadString } from 'firebase/storage';
import { getAdminFromToken } from '@/lib/auth';
import { getOrgFilter, checkPackageLimit, getOrgLimits } from '@/lib/authorization';

// GET all channels
export async function GET(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { searchParams } = new URL(request.url);
    const orgIdParam = searchParams.get('organizationId');

    const orgFilter = getOrgFilter(admin);
    const effectiveOrgId = orgFilter || orgIdParam;

    const channelsRef = collection(db, 'channels');
    let q;
    if (effectiveOrgId) {
      q = query(channelsRef, where('organizationId', '==', effectiveOrgId), orderBy('createdAt', 'desc'));
    } else {
      q = query(channelsRef, orderBy('createdAt', 'desc'));
    }
    const snapshot = await getDocs(q);

    const channels = snapshot.docs.map((doc) => ({
      id: doc.id,
      ...doc.data(),
      createdAt: doc.data().createdAt?.toDate?.() || null,
      updatedAt: doc.data().updatedAt?.toDate?.() || null,
    }));

    // Include limits info for org admins
    let limits = null;
    const limitsOrgId = orgFilter || orgIdParam;
    if (limitsOrgId) {
      limits = await getOrgLimits(limitsOrgId);
    }

    return NextResponse.json({ channels, limits });
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
    const { name, description, isPrivate = false, organizationId: bodyOrgId } = body;

    // Determine organization
    const orgFilter = getOrgFilter(admin);
    const organizationId = orgFilter || bodyOrgId;

    if (!organizationId) {
      return NextResponse.json(
        { error: 'Organization is required' },
        { status: 400 }
      );
    }

    if (!name?.trim()) {
      return NextResponse.json(
        { error: 'Channel name is required' },
        { status: 400 }
      );
    }

    // Check package limit
    const limit = await checkPackageLimit(organizationId, 'channels');
    if (!limit.allowed) {
      return NextResponse.json(
        { error: `Channel limit reached (${limit.current}/${limit.max}). Upgrade the organization package to add more channels.` },
        { status: 400 }
      );
    }

    const channelsRef = collection(db, 'channels');
    const docRef = await addDoc(channelsRef, {
      name: name.trim(),
      description: description?.trim() || null,
      ownerId: admin.adminId,
      isPrivate,
      isActive: true, // Default to active for billing
      audioArchiveEnabled: true,
      memberCount: 0,
      memberIds: [],
      organizationId,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });

    // Create audio archive storage directory with a .keep placeholder
    try {
      const keepRef = ref(storage, `channels/${docRef.id}/audio/.keep`);
      await uploadString(keepRef, '');
    } catch (storageError) {
      console.warn('Failed to create audio storage directory:', storageError);
    }

    return NextResponse.json({
      success: true,
      channel: {
        id: docRef.id,
        name: name.trim(),
        description: description?.trim() || null,
        isPrivate,
        isActive: true,
        audioArchiveEnabled: true,
        memberCount: 0,
        memberIds: [],
        organizationId,
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
