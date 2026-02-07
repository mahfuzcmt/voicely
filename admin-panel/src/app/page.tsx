import { redirect } from 'next/navigation';
import { getAdminFromToken } from '@/lib/auth';

export default async function Home() {
  const admin = await getAdminFromToken();

  if (admin) {
    redirect('/dashboard');
  } else {
    redirect('/login');
  }
}
