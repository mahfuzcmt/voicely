import { db } from '@/lib/firebase';
import { collection, getDocs, query, where } from 'firebase/firestore';
import { Users, Radio, MessageSquare, Activity, Building2, Package } from 'lucide-react';
import { getAdminFromToken } from '@/lib/auth';
import { redirect } from 'next/navigation';

async function getStats(admin: { role: string; organizationId: string | null; organizationName: string | null }) {
  try {
    const isSuper = admin.role === 'super_admin';
    const orgId = admin.organizationId;

    // Build queries based on role
    const usersRef = collection(db, 'users');
    const channelsRef = collection(db, 'channels');

    let usersQuery;
    let activeUsersQuery;
    let channelsQuery;

    if (isSuper) {
      usersQuery = usersRef;
      activeUsersQuery = query(usersRef, where('status', '==', 'online'));
      channelsQuery = channelsRef;
    } else {
      usersQuery = query(usersRef, where('organizationId', '==', orgId));
      activeUsersQuery = query(usersRef, where('organizationId', '==', orgId), where('status', '==', 'online'));
      channelsQuery = query(channelsRef, where('organizationId', '==', orgId));
    }

    const [usersSnap, activeUsersSnap, channelsSnap, messagesSnap] = await Promise.all([
      getDocs(usersQuery),
      getDocs(activeUsersQuery),
      getDocs(channelsQuery),
      getDocs(collection(db, 'messages')),
    ]);

    // For super admin, get org count
    let totalOrgs = 0;
    let packageMaxUsers = 0;
    let packageMaxChannels = 0;

    if (isSuper) {
      const orgsSnap = await getDocs(collection(db, 'organizations'));
      totalOrgs = orgsSnap.size;
    } else if (orgId) {
      // Get package limits for org admin
      const { getDoc, doc } = await import('firebase/firestore');
      const orgDoc = await getDoc(doc(db, 'organizations', orgId));
      if (orgDoc.exists()) {
        const orgData = orgDoc.data();
        packageMaxUsers = orgData.packageMaxUsers;
        packageMaxChannels = orgData.packageMaxChannels;
      }
    }

    return {
      totalUsers: usersSnap.size,
      activeUsers: activeUsersSnap.size,
      totalChannels: channelsSnap.size,
      totalMessages: messagesSnap.size,
      totalOrgs,
      packageMaxUsers,
      packageMaxChannels,
      organizationName: admin.organizationName,
    };
  } catch (error) {
    console.error('Failed to get stats:', error);
    return {
      totalUsers: 0,
      activeUsers: 0,
      totalChannels: 0,
      totalMessages: 0,
      totalOrgs: 0,
      packageMaxUsers: 0,
      packageMaxChannels: 0,
      organizationName: null,
    };
  }
}

export default async function DashboardPage() {
  const admin = await getAdminFromToken();
  if (!admin) redirect('/login');

  const stats = await getStats(admin);
  const isSuper = admin.role === 'super_admin';
  const isOrgAdmin = admin.role === 'org_admin';

  const statCards = [
    ...(isSuper ? [{
      name: 'Organizations',
      value: stats.totalOrgs,
      icon: Building2,
      color: 'bg-indigo-500',
    }] : []),
    {
      name: 'Total Users',
      value: isOrgAdmin && stats.packageMaxUsers
        ? `${stats.totalUsers}/${stats.packageMaxUsers}`
        : stats.totalUsers,
      icon: Users,
      color: 'bg-blue-500',
    },
    {
      name: 'Active Users',
      value: stats.activeUsers,
      icon: Activity,
      color: 'bg-green-500',
    },
    {
      name: 'Total Channels',
      value: isOrgAdmin && stats.packageMaxChannels
        ? `${stats.totalChannels}/${stats.packageMaxChannels}`
        : stats.totalChannels,
      icon: Radio,
      color: 'bg-purple-500',
    },
    {
      name: 'Total Messages',
      value: stats.totalMessages,
      icon: MessageSquare,
      color: 'bg-orange-500',
    },
  ];

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900">Dashboard</h1>
        <p className="text-gray-500 mt-1">
          {isOrgAdmin && stats.organizationName
            ? `Overview of ${stats.organizationName}`
            : 'Overview of your Voicely app'}
        </p>
      </div>

      {/* Package usage bars for org admin */}
      {isOrgAdmin && stats.packageMaxUsers > 0 && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
          <div className="card">
            <div className="flex justify-between text-sm mb-2">
              <span className="text-gray-600 font-medium">User Quota</span>
              <span className="font-semibold">{stats.totalUsers} / {stats.packageMaxUsers}</span>
            </div>
            <div className="h-3 bg-gray-200 rounded-full overflow-hidden">
              <div
                className={`h-full rounded-full transition-all ${
                  stats.totalUsers / stats.packageMaxUsers > 0.9 ? 'bg-red-500' :
                  stats.totalUsers / stats.packageMaxUsers > 0.7 ? 'bg-yellow-500' :
                  'bg-green-500'
                }`}
                style={{ width: `${Math.min(100, (stats.totalUsers / stats.packageMaxUsers) * 100)}%` }}
              />
            </div>
          </div>
          <div className="card">
            <div className="flex justify-between text-sm mb-2">
              <span className="text-gray-600 font-medium">Channel Quota</span>
              <span className="font-semibold">{stats.totalChannels} / {stats.packageMaxChannels}</span>
            </div>
            <div className="h-3 bg-gray-200 rounded-full overflow-hidden">
              <div
                className={`h-full rounded-full transition-all ${
                  stats.totalChannels / stats.packageMaxChannels > 0.9 ? 'bg-red-500' :
                  stats.totalChannels / stats.packageMaxChannels > 0.7 ? 'bg-yellow-500' :
                  'bg-green-500'
                }`}
                style={{ width: `${Math.min(100, (stats.totalChannels / stats.packageMaxChannels) * 100)}%` }}
              />
            </div>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        {statCards.map((stat) => (
          <div key={stat.name} className="card">
            <div className="flex items-center gap-4">
              <div className={`p-3 rounded-lg ${stat.color}`}>
                <stat.icon className="w-6 h-6 text-white" />
              </div>
              <div>
                <p className="text-sm text-gray-500">{stat.name}</p>
                <p className="text-2xl font-bold text-gray-900">{stat.value}</p>
              </div>
            </div>
          </div>
        ))}
      </div>

      <div className="mt-8 card">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">
          Quick Actions
        </h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {isSuper && (
            <a
              href="/dashboard/organizations"
              className="p-4 border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors"
            >
              <Building2 className="w-6 h-6 text-primary-600 mb-2" />
              <h3 className="font-medium text-gray-900">Manage Organizations</h3>
              <p className="text-sm text-gray-500">Create and configure organizations</p>
            </a>
          )}
          <a
            href="/dashboard/channels"
            className="p-4 border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors"
          >
            <Radio className="w-6 h-6 text-primary-600 mb-2" />
            <h3 className="font-medium text-gray-900">Manage Channels</h3>
            <p className="text-sm text-gray-500">Create, edit, or delete channels</p>
          </a>
          <a
            href="/dashboard/users"
            className="p-4 border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors"
          >
            <Users className="w-6 h-6 text-primary-600 mb-2" />
            <h3 className="font-medium text-gray-900">Manage Users</h3>
            <p className="text-sm text-gray-500">View and manage app users</p>
          </a>
          {isSuper && (
            <a
              href="/api/auth/init"
              target="_blank"
              className="p-4 border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors"
            >
              <Activity className="w-6 h-6 text-primary-600 mb-2" />
              <h3 className="font-medium text-gray-900">System Status</h3>
              <p className="text-sm text-gray-500">Initialize and check system health</p>
            </a>
          )}
        </div>
      </div>
    </div>
  );
}
