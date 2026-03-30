import { NextResponse } from 'next/server';
import { getAdminFirestore } from '@/lib/firebase-admin';
import { JwtPayload } from '@/lib/auth';

export function isSuperAdmin(admin: JwtPayload): boolean {
  return admin.role === 'super_admin';
}

export function getOrgFilter(admin: JwtPayload): string | null {
  if (admin.role === 'super_admin') return null;
  return admin.organizationId || null;
}

export function requireSuperAdmin(admin: JwtPayload): NextResponse | null {
  if (admin.role !== 'super_admin') {
    return NextResponse.json(
      { error: 'Access denied. Super admin only.' },
      { status: 403 }
    );
  }
  return null;
}

export function requireOrgAccess(admin: JwtPayload, resourceOrgId: string): NextResponse | null {
  if (admin.role === 'super_admin') return null;
  if (admin.organizationId !== resourceOrgId) {
    return NextResponse.json(
      { error: 'Access denied. Resource belongs to another organization.' },
      { status: 403 }
    );
  }
  return null;
}

export async function checkPackageLimit(
  organizationId: string,
  type: 'users' | 'channels'
): Promise<{ allowed: boolean; current: number; max: number }> {
  const db = getAdminFirestore();
  const orgDoc = await db.collection('organizations').doc(organizationId).get();

  if (!orgDoc.exists) {
    return { allowed: false, current: 0, max: 0 };
  }

  const orgData = orgDoc.data()!;
  const max = type === 'users' ? orgData.packageMaxUsers : orgData.packageMaxChannels;

  const collectionName = type === 'users' ? 'users' : 'channels';
  const snapshot = await db.collection(collectionName).where('organizationId', '==', organizationId).get();
  const current = snapshot.size;

  return { allowed: current < max, current, max };
}

export async function getOrgLimits(
  organizationId: string
): Promise<{ currentUsers: number; maxUsers: number; currentChannels: number; maxChannels: number } | null> {
  const db = getAdminFirestore();
  const orgDoc = await db.collection('organizations').doc(organizationId).get();

  if (!orgDoc.exists) return null;

  const orgData = orgDoc.data()!;

  const [usersSnap, channelsSnap] = await Promise.all([
    db.collection('users').where('organizationId', '==', organizationId).get(),
    db.collection('channels').where('organizationId', '==', organizationId).get(),
  ]);

  return {
    currentUsers: usersSnap.size,
    maxUsers: orgData.packageMaxUsers,
    currentChannels: channelsSnap.size,
    maxChannels: orgData.packageMaxChannels,
  };
}
