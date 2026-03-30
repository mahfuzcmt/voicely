import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore, getAdminAuth } from '@/lib/firebase-admin';
import { FieldValue } from 'firebase-admin/firestore';
import { getAdminFromToken } from '@/lib/auth';
import { getOrgFilter, checkPackageLimit, getOrgLimits } from '@/lib/authorization';

// Convert phone number to email format (same as mobile app)
function phoneToEmail(phoneNumber: string): string {
  const cleanPhone = phoneNumber.replace(/[^\d+]/g, '');
  return `${cleanPhone}@voicely.app`;
}

// GET all users (optionally filter by channel)
export async function GET(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { searchParams } = new URL(request.url);
    const channelId = searchParams.get('channelId');
    const orgIdParam = searchParams.get('organizationId');

    // Determine org scope
    const orgFilter = getOrgFilter(admin);
    const effectiveOrgId = orgFilter || orgIdParam; // org_admin uses their org, super_admin can filter

    const db = getAdminFirestore();
    let users: any[] = [];

    if (channelId) {
      // Get channel to find member IDs
      const channelDoc = await db.collection('channels').doc(channelId).get();
      if (channelDoc.exists) {
        const channelData = channelDoc.data()!;

        // Org admin: verify channel belongs to their org
        if (orgFilter && channelData.organizationId !== orgFilter) {
          return NextResponse.json({ error: 'Access denied' }, { status: 403 });
        }

        const memberIds = channelData.memberIds || [];

        if (memberIds.length > 0) {
          // Firestore 'in' query supports max 30 items, so batch if needed
          const batchSize = 30;
          for (let i = 0; i < memberIds.length; i += batchSize) {
            const batch = memberIds.slice(i, i + batchSize);
            const snapshot = await db.collection('users').where('__name__', 'in', batch).get();

            snapshot.docs.forEach((doc) => {
              const data = doc.data();
              // Extra safety: only include users from the effective org
              if (!effectiveOrgId || data.organizationId === effectiveOrgId) {
                users.push({
                  id: doc.id,
                  ...data,
                  lastSeen: data.lastSeen?.toDate?.() || null,
                  createdAt: data.createdAt?.toDate?.() || null,
                  updatedAt: data.updatedAt?.toDate?.() || null,
                });
              }
            });
          }
        }
      }
    } else {
      // Build query with org filter
      let queryRef;
      if (effectiveOrgId) {
        // Use separate queries to avoid composite index requirement
        queryRef = db.collection('users').where('organizationId', '==', effectiveOrgId);
      } else {
        queryRef = db.collection('users').orderBy('createdAt', 'desc');
      }
      const snapshot = await queryRef.get();

      users = snapshot.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
        lastSeen: doc.data().lastSeen?.toDate?.() || null,
        createdAt: doc.data().createdAt?.toDate?.() || null,
        updatedAt: doc.data().updatedAt?.toDate?.() || null,
      }));

      // Sort by createdAt if we filtered by org (since we couldn't use orderBy with where)
      if (effectiveOrgId) {
        users.sort((a, b) => {
          const aTime = a.createdAt?.getTime?.() || 0;
          const bTime = b.createdAt?.getTime?.() || 0;
          return bTime - aTime;
        });
      }
    }

    // Include limits info for org admins
    let limits = null;
    const limitsOrgId = orgFilter || orgIdParam;
    if (limitsOrgId) {
      limits = await getOrgLimits(limitsOrgId);
    }

    return NextResponse.json({ users, limits });
  } catch (error) {
    console.error('Error fetching users:', error);
    return NextResponse.json(
      { error: 'Failed to fetch users' },
      { status: 500 }
    );
  }
}

// POST create user
export async function POST(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const body = await request.json();
    const { displayName, phoneNumber, password, status = 'offline', organizationId: bodyOrgId } = body;

    // Determine organization
    const orgFilter = getOrgFilter(admin);
    const organizationId = orgFilter || bodyOrgId;

    if (!organizationId) {
      return NextResponse.json(
        { error: 'Organization is required' },
        { status: 400 }
      );
    }

    if (!displayName?.trim() || !phoneNumber?.trim()) {
      return NextResponse.json(
        { error: 'Display name and phone number are required' },
        { status: 400 }
      );
    }

    if (!password?.trim()) {
      return NextResponse.json(
        { error: 'Password is required' },
        { status: 400 }
      );
    }

    // Check package limit
    const limit = await checkPackageLimit(organizationId, 'users');
    if (!limit.allowed) {
      return NextResponse.json(
        { error: `User limit reached (${limit.current}/${limit.max}). Upgrade the organization package to add more users.` },
        { status: 400 }
      );
    }

    // Convert phone to email format (same as mobile app)
    const authEmail = phoneToEmail(phoneNumber.trim());

    // Create user in Firebase Authentication
    const adminAuth = getAdminAuth();
    const userRecord = await adminAuth.createUser({
      email: authEmail,
      password: password,
      displayName: displayName.trim(),
    });

    // Create user document in Firestore with the same UID
    const db = getAdminFirestore();
    await db.collection('users').doc(userRecord.uid).set({
      displayName: displayName.trim(),
      phoneNumber: phoneNumber.trim(),
      email: authEmail,
      status,
      organizationId,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    return NextResponse.json({
      success: true,
      user: {
        id: userRecord.uid,
        displayName: displayName.trim(),
        phoneNumber: phoneNumber.trim(),
        email: authEmail,
        status,
        organizationId,
      },
    });
  } catch (error: any) {
    console.error('Error creating user:', error);

    if (error.code === 'auth/email-already-exists') {
      return NextResponse.json(
        { error: 'A user with this phone number already exists' },
        { status: 400 }
      );
    }
    if (error.code === 'auth/invalid-password' || error.code === 'auth/weak-password') {
      return NextResponse.json(
        { error: 'Password must be at least 6 characters' },
        { status: 400 }
      );
    }
    if (error.code === 'auth/invalid-email') {
      return NextResponse.json(
        { error: 'Invalid phone number format' },
        { status: 400 }
      );
    }
    if (error.code === 'app/no-app' || error.code === 'app/invalid-credential') {
      return NextResponse.json(
        { error: 'Firebase Admin SDK is not configured. Check FIREBASE_SERVICE_ACCOUNT environment variable.' },
        { status: 500 }
      );
    }

    return NextResponse.json(
      { error: error.message || 'Failed to create user' },
      { status: 500 }
    );
  }
}
