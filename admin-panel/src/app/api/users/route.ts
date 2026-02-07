import { NextRequest, NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import {
  collection,
  getDocs,
  getDoc,
  doc,
  addDoc,
  serverTimestamp,
  orderBy,
  query,
  where,
} from 'firebase/firestore';
import { getAdminFromToken, hashPassword } from '@/lib/auth';

// GET all users (optionally filter by channel)
export async function GET(request: NextRequest) {
  try {
    const admin = await getAdminFromToken();
    if (!admin) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const { searchParams } = new URL(request.url);
    const channelId = searchParams.get('channelId');

    const usersRef = collection(db, 'users');
    let users: any[] = [];

    if (channelId) {
      // Get channel to find member IDs
      const channelDoc = await getDoc(doc(db, 'channels', channelId));
      if (channelDoc.exists()) {
        const memberIds = channelDoc.data().memberIds || [];

        if (memberIds.length > 0) {
          // Firestore 'in' query supports max 30 items, so batch if needed
          const batchSize = 30;
          for (let i = 0; i < memberIds.length; i += batchSize) {
            const batch = memberIds.slice(i, i + batchSize);
            const q = query(usersRef, where('__name__', 'in', batch));
            const snapshot = await getDocs(q);

            snapshot.docs.forEach((doc) => {
              users.push({
                id: doc.id,
                ...doc.data(),
                lastSeen: doc.data().lastSeen?.toDate?.() || null,
                createdAt: doc.data().createdAt?.toDate?.() || null,
                updatedAt: doc.data().updatedAt?.toDate?.() || null,
              });
            });
          }
        }
      }
    } else {
      // Get all users
      const q = query(usersRef, orderBy('createdAt', 'desc'));
      const snapshot = await getDocs(q);

      users = snapshot.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
        lastSeen: doc.data().lastSeen?.toDate?.() || null,
        createdAt: doc.data().createdAt?.toDate?.() || null,
        updatedAt: doc.data().updatedAt?.toDate?.() || null,
      }));
    }

    return NextResponse.json({ users });
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
    const { displayName, phoneNumber, email, password, status = 'offline' } = body;

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

    // Hash the password
    const passwordHash = await hashPassword(password);

    const usersRef = collection(db, 'users');
    const docRef = await addDoc(usersRef, {
      displayName: displayName.trim(),
      phoneNumber: phoneNumber.trim(),
      email: email?.trim() || null,
      passwordHash,
      status,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });

    return NextResponse.json({
      success: true,
      user: {
        id: docRef.id,
        displayName: displayName.trim(),
        phoneNumber: phoneNumber.trim(),
        email: email?.trim() || null,
        status,
      },
    });
  } catch (error) {
    console.error('Error creating user:', error);
    return NextResponse.json(
      { error: 'Failed to create user' },
      { status: 500 }
    );
  }
}
