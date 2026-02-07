import { NextRequest, NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import {
  doc,
  getDoc,
  updateDoc,
  deleteDoc,
  serverTimestamp,
} from 'firebase/firestore';
import { getAdminFromToken } from '@/lib/auth';
import { getAdminAuth } from '@/lib/firebase-admin';

// GET single user
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
    const userRef = doc(db, 'users', id);
    const userDoc = await getDoc(userRef);

    if (!userDoc.exists()) {
      return NextResponse.json({ error: 'User not found' }, { status: 404 });
    }

    return NextResponse.json({
      user: {
        id: userDoc.id,
        ...userDoc.data(),
        lastSeen: userDoc.data().lastSeen?.toDate?.() || null,
        createdAt: userDoc.data().createdAt?.toDate?.() || null,
        updatedAt: userDoc.data().updatedAt?.toDate?.() || null,
      },
    });
  } catch (error) {
    console.error('Error fetching user:', error);
    return NextResponse.json(
      { error: 'Failed to fetch user' },
      { status: 500 }
    );
  }
}

// Convert phone number to email format (same as mobile app)
function phoneToEmail(phoneNumber: string): string {
  const cleanPhone = phoneNumber.replace(/[^\d+]/g, '');
  return `${cleanPhone}@voicely.app`;
}

// PUT update user
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
    const { displayName, phoneNumber, password, status } = body;

    const userRef = doc(db, 'users', id);
    const userDoc = await getDoc(userRef);

    if (!userDoc.exists()) {
      return NextResponse.json({ error: 'User not found' }, { status: 404 });
    }

    const userData = userDoc.data();
    const adminAuth = getAdminAuth();

    // Check if user exists in Firebase Auth
    let userExistsInAuth = false;
    try {
      await adminAuth.getUser(id);
      userExistsInAuth = true;
    } catch (authError: any) {
      if (authError.code === 'auth/user-not-found') {
        userExistsInAuth = false;
      } else {
        throw authError;
      }
    }

    // If user doesn't exist in Firebase Auth, create them
    if (!userExistsInAuth) {
      if (!password?.trim()) {
        return NextResponse.json(
          { error: 'Password is required to enable login for this user' },
          { status: 400 }
        );
      }

      const phone = phoneNumber?.trim() || userData.phoneNumber;
      const authEmail = phoneToEmail(phone);
      const name = displayName?.trim() || userData.displayName;

      // Create user in Firebase Auth with the same UID
      await adminAuth.createUser({
        uid: id,
        email: authEmail,
        password: password,
        displayName: name,
      });

      console.log(`Created Firebase Auth user for existing Firestore user: ${id}`);
    } else {
      // User exists in Auth, update if needed
      const authUpdateData: { password?: string; displayName?: string } = {};

      if (password?.trim()) {
        authUpdateData.password = password;
      }
      if (displayName !== undefined) {
        authUpdateData.displayName = displayName.trim();
      }

      if (Object.keys(authUpdateData).length > 0) {
        await adminAuth.updateUser(id, authUpdateData);
      }
    }

    // Update Firestore
    const updateData: Record<string, unknown> = {
      updatedAt: serverTimestamp(),
    };

    if (displayName !== undefined) updateData.displayName = displayName.trim();
    if (phoneNumber !== undefined) {
      updateData.phoneNumber = phoneNumber.trim();
      updateData.email = phoneToEmail(phoneNumber.trim());
    }
    if (status !== undefined) updateData.status = status;

    await updateDoc(userRef, updateData);

    return NextResponse.json({ success: true, authCreated: !userExistsInAuth });
  } catch (error: any) {
    console.error('Error updating user:', error);

    if (error.code === 'auth/email-already-exists') {
      return NextResponse.json(
        { error: 'A user with this phone number already exists in authentication' },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { error: 'Failed to update user' },
      { status: 500 }
    );
  }
}

// DELETE user
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
    const userRef = doc(db, 'users', id);
    const userDoc = await getDoc(userRef);

    if (!userDoc.exists()) {
      return NextResponse.json({ error: 'User not found' }, { status: 404 });
    }

    // Delete from Firebase Auth
    const adminAuth = getAdminAuth();
    try {
      await adminAuth.deleteUser(id);
    } catch (authError: any) {
      // User might not exist in Auth (created before this fix)
      if (authError.code !== 'auth/user-not-found') {
        throw authError;
      }
    }

    // Delete from Firestore
    await deleteDoc(userRef);

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Error deleting user:', error);
    return NextResponse.json(
      { error: 'Failed to delete user' },
      { status: 500 }
    );
  }
}
