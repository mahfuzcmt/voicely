import { NextResponse } from 'next/server';
import { db } from '@/lib/firebase';
import { collection, query, where, getDocs, addDoc, serverTimestamp } from 'firebase/firestore';
import { hashPassword } from '@/lib/auth';

// Super admin credentials
const SUPER_ADMIN_EMAIL = 'mahfuzcmt@gmail.com';
const SUPER_ADMIN_PASSWORD = '!Mahfuz20';
const SUPER_ADMIN_NAME = 'Super Admin';

export async function GET() {
  try {
    // Check if super admin already exists
    const adminsRef = collection(db, 'admins');
    const q = query(adminsRef, where('email', '==', SUPER_ADMIN_EMAIL));
    const querySnapshot = await getDocs(q);

    if (!querySnapshot.empty) {
      return NextResponse.json({
        message: 'Super admin already exists',
        exists: true,
      });
    }

    // Create super admin
    const passwordHash = await hashPassword(SUPER_ADMIN_PASSWORD);

    await addDoc(adminsRef, {
      email: SUPER_ADMIN_EMAIL,
      displayName: SUPER_ADMIN_NAME,
      passwordHash,
      role: 'super_admin',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });

    return NextResponse.json({
      message: 'Super admin created successfully',
      email: SUPER_ADMIN_EMAIL,
    });
  } catch (error) {
    console.error('Init error:', error);
    return NextResponse.json(
      { error: 'Failed to initialize super admin' },
      { status: 500 }
    );
  }
}
