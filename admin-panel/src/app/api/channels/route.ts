import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore, getAdminStorage } from '@/lib/firebase-admin';
import { FieldValue } from 'firebase-admin/firestore';
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

    const db = getAdminFirestore();
    let queryRef;

    if (effectiveOrgId) {
      // Use simple query to avoid composite index requirement
      queryRef = db.collection('channels').where('organizationId', '==', effectiveOrgId);
    } else {
      queryRef = db.collection('channels').orderBy('createdAt', 'desc');
    }

    const snapshot = await queryRef.get();

    let channels = snapshot.docs.map((doc) => ({
      id: doc.id,
      ...doc.data(),
      createdAt: doc.data().createdAt?.toDate?.() || null,
      updatedAt: doc.data().updatedAt?.toDate?.() || null,
    }));

    // Sort by createdAt if we filtered by org (since we couldn't use orderBy with where)
    if (effectiveOrgId) {
      channels.sort((a: any, b: any) => {
        const aTime = a.createdAt?.getTime?.() || 0;
        const bTime = b.createdAt?.getTime?.() || 0;
        return bTime - aTime;
      });
    }

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

    const db = getAdminFirestore();
    const docRef = await db.collection('channels').add({
      name: name.trim(),
      description: description?.trim() || null,
      ownerId: admin.adminId,
      isPrivate,
      isActive: true, // Default to active for billing
      audioArchiveEnabled: true,
      memberCount: 0,
      memberIds: [],
      organizationId,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Create audio archive storage directory with a .keep placeholder
    try {
      const storage = getAdminStorage();
      const bucket = storage.bucket();
      const file = bucket.file(`channels/${docRef.id}/audio/.keep`);
      await file.save('');
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
