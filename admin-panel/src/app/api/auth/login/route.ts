import { NextRequest, NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { verifyPassword, generateToken, setAuthCookie } from '@/lib/auth';
import { Admin } from '@/types';

export async function POST(request: NextRequest) {
  try {
    const { email, password } = await request.json();

    if (!email || !password) {
      return NextResponse.json(
        { error: 'Email and password are required' },
        { status: 400 }
      );
    }

    // Find admin by email
    const db = getAdminFirestore();
    const querySnapshot = await db.collection('admins').where('email', '==', email.toLowerCase()).get();

    if (querySnapshot.empty) {
      return NextResponse.json(
        { error: 'Invalid credentials' },
        { status: 401 }
      );
    }

    const adminDoc = querySnapshot.docs[0];
    const adminData = adminDoc.data();

    // Verify password
    const isValidPassword = await verifyPassword(password, adminData.passwordHash);
    if (!isValidPassword) {
      return NextResponse.json(
        { error: 'Invalid credentials' },
        { status: 401 }
      );
    }

    // Get organization name if org_admin
    let organizationName: string | null = null;
    if (adminData.organizationId) {
      const orgDoc = await db.collection('organizations').doc(adminData.organizationId).get();
      if (orgDoc.exists) {
        organizationName = orgDoc.data()?.name || null;
      }
    }

    // Generate token
    const admin: Admin = {
      id: adminDoc.id,
      email: adminData.email,
      displayName: adminData.displayName,
      role: adminData.role,
      organizationId: adminData.organizationId || null,
      organizationName,
      createdAt: adminData.createdAt?.toDate(),
      updatedAt: adminData.updatedAt?.toDate(),
    };

    const token = generateToken(admin);

    // Set cookie
    await setAuthCookie(token);

    return NextResponse.json({
      success: true,
      admin: {
        id: admin.id,
        email: admin.email,
        displayName: admin.displayName,
        role: admin.role,
        organizationId: admin.organizationId,
        organizationName,
      },
    });
  } catch (error) {
    console.error('Login error:', error);
    return NextResponse.json(
      { error: 'Internal server error' },
      { status: 500 }
    );
  }
}
