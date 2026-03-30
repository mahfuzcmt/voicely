import { redirect } from 'next/navigation';
import { getAdminFromToken } from '@/lib/auth';

export default async function OrganizationsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const admin = await getAdminFromToken();

  if (!admin || admin.role !== 'super_admin') {
    redirect('/dashboard');
  }

  return <>{children}</>;
}
