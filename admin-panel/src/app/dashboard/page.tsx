import { db } from '@/lib/firebase';
import { collection, getDocs, query, where } from 'firebase/firestore';
import { Users, Radio, MessageSquare, Activity } from 'lucide-react';

async function getStats() {
  try {
    // Get total users
    const usersSnapshot = await getDocs(collection(db, 'users'));
    const totalUsers = usersSnapshot.size;

    // Get active users (online status)
    const activeUsersQuery = query(
      collection(db, 'users'),
      where('status', '==', 'online')
    );
    const activeUsersSnapshot = await getDocs(activeUsersQuery);
    const activeUsers = activeUsersSnapshot.size;

    // Get total channels
    const channelsSnapshot = await getDocs(collection(db, 'channels'));
    const totalChannels = channelsSnapshot.size;

    // Get total messages
    const messagesSnapshot = await getDocs(collection(db, 'messages'));
    const totalMessages = messagesSnapshot.size;

    return {
      totalUsers,
      activeUsers,
      totalChannels,
      totalMessages,
    };
  } catch (error) {
    console.error('Failed to get stats:', error);
    return {
      totalUsers: 0,
      activeUsers: 0,
      totalChannels: 0,
      totalMessages: 0,
    };
  }
}

export default async function DashboardPage() {
  const stats = await getStats();

  const statCards = [
    {
      name: 'Total Users',
      value: stats.totalUsers,
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
      value: stats.totalChannels,
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
        <p className="text-gray-500 mt-1">Overview of your Voicely app</p>
      </div>

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
          <a
            href="/api/auth/init"
            target="_blank"
            className="p-4 border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors"
          >
            <Activity className="w-6 h-6 text-primary-600 mb-2" />
            <h3 className="font-medium text-gray-900">System Status</h3>
            <p className="text-sm text-gray-500">Check system health</p>
          </a>
        </div>
      </div>
    </div>
  );
}
