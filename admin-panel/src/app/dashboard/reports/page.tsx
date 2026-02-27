'use client';

import { useState, useEffect } from 'react';
import { useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  BarChart3,
  Users,
  Clock,
  Mic,
  Calendar,
  ChevronDown,
  ArrowLeft,
} from 'lucide-react';
import Link from 'next/link';
import { Channel, User } from '@/types';

interface ChannelStats {
  channelId: string;
  channelName?: string;
  date?: string;
  month?: string;
  totalVoices: number;
  totalDuration: number;
  isActive?: boolean;
  memberCount?: number;
}

interface UserStats {
  userId: string;
  userName?: string;
  phoneNumber?: string;
  date?: string;
  month?: string;
  voicesSent: number;
  durationSent: number;
}

interface ChannelUserStats {
  userId: string;
  userName: string;
  totalVoices: number;
  totalDuration: number;
}

export default function ReportsPage() {
  const searchParams = useSearchParams();
  const initialType = searchParams.get('type') || 'overview';
  const initialId = searchParams.get('id') || '';

  const [viewType, setViewType] = useState<'overview' | 'channel' | 'user'>(
    initialType as 'overview' | 'channel' | 'user'
  );
  const [selectedId, setSelectedId] = useState(initialId);
  const [period, setPeriod] = useState<'daily' | 'monthly' | 'users'>('monthly');
  const [loading, setLoading] = useState(true);

  const [channels, setChannels] = useState<Channel[]>([]);
  const [users, setUsers] = useState<User[]>([]);

  const [channelOverview, setChannelOverview] = useState<ChannelStats[]>([]);
  const [userOverview, setUserOverview] = useState<UserStats[]>([]);
  const [detailStats, setDetailStats] = useState<(ChannelStats | UserStats | ChannelUserStats)[]>([]);

  useEffect(() => {
    fetchChannelsAndUsers();
  }, []);

  useEffect(() => {
    if (viewType === 'overview') {
      fetchOverviewStats();
    } else if (selectedId) {
      fetchDetailStats();
    }
  }, [viewType, selectedId, period]);

  const fetchChannelsAndUsers = async () => {
    try {
      const [channelsRes, usersRes] = await Promise.all([
        fetch('/api/channels'),
        fetch('/api/users'),
      ]);
      const channelsData = await channelsRes.json();
      const usersData = await usersRes.json();
      setChannels(channelsData.channels || []);
      setUsers(usersData.users || []);
    } catch (error) {
      console.error('Error fetching data:', error);
    }
  };

  const fetchOverviewStats = async () => {
    setLoading(true);
    try {
      const [channelRes, userRes] = await Promise.all([
        fetch('/api/stats?type=all-channels&period=monthly'),
        fetch('/api/stats?type=all-users&period=monthly'),
      ]);
      const channelData = await channelRes.json();
      const userData = await userRes.json();
      setChannelOverview(channelData.stats || []);
      setUserOverview(userData.stats || []);
    } catch (error) {
      toast.error('Failed to fetch overview stats');
    } finally {
      setLoading(false);
    }
  };

  const fetchDetailStats = async () => {
    setLoading(true);
    try {
      const res = await fetch(
        `/api/stats?type=${viewType}&id=${selectedId}&period=${period}`
      );
      const data = await res.json();
      setDetailStats(data.stats || []);
    } catch (error) {
      toast.error('Failed to fetch stats');
    } finally {
      setLoading(false);
    }
  };

  const formatDuration = (seconds: number) => {
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const secs = seconds % 60;
    if (minutes < 60) return `${minutes}m ${secs}s`;
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    return `${hours}h ${mins}m`;
  };

  const getTotalVoices = (stats: ChannelStats[] | UserStats[]) => {
    return stats.reduce((sum, s) => {
      if ('totalVoices' in s) return sum + (s.totalVoices || 0);
      if ('voicesSent' in s) return sum + (s.voicesSent || 0);
      return sum;
    }, 0);
  };

  const getTotalDuration = (stats: ChannelStats[] | UserStats[]) => {
    return stats.reduce((sum, s) => {
      if ('totalDuration' in s) return sum + (s.totalDuration || 0);
      if ('durationSent' in s) return sum + (s.durationSent || 0);
      return sum;
    }, 0);
  };

  const renderOverview = () => (
    <div className="space-y-8">
      {/* Summary Cards */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <div className="card">
          <div className="flex items-center gap-3">
            <div className="p-3 bg-blue-100 rounded-lg">
              <BarChart3 className="w-6 h-6 text-blue-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">Total Channels</p>
              <p className="text-2xl font-bold">{channelOverview.length}</p>
            </div>
          </div>
        </div>
        <div className="card">
          <div className="flex items-center gap-3">
            <div className="p-3 bg-green-100 rounded-lg">
              <Users className="w-6 h-6 text-green-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">Total Users</p>
              <p className="text-2xl font-bold">{userOverview.length}</p>
            </div>
          </div>
        </div>
        <div className="card">
          <div className="flex items-center gap-3">
            <div className="p-3 bg-purple-100 rounded-lg">
              <Mic className="w-6 h-6 text-purple-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">Total Voices (Month)</p>
              <p className="text-2xl font-bold">{getTotalVoices(channelOverview)}</p>
            </div>
          </div>
        </div>
        <div className="card">
          <div className="flex items-center gap-3">
            <div className="p-3 bg-orange-100 rounded-lg">
              <Clock className="w-6 h-6 text-orange-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">Total Duration (Month)</p>
              <p className="text-2xl font-bold">{formatDuration(getTotalDuration(channelOverview))}</p>
            </div>
          </div>
        </div>
      </div>

      {/* Channel Stats Table */}
      <div>
        <h2 className="text-lg font-semibold mb-4">Channel Usage (This Month)</h2>
        <div className="card overflow-hidden">
          <table className="w-full">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Channel</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Status</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Members</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Voices</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Duration</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {channelOverview.map((stat) => (
                <tr key={stat.channelId} className="hover:bg-gray-50">
                  <td className="px-4 py-3 font-medium">{stat.channelName || stat.channelId}</td>
                  <td className="px-4 py-3">
                    <span className={`px-2 py-1 text-xs rounded-full ${
                      stat.isActive !== false
                        ? 'bg-green-100 text-green-700'
                        : 'bg-red-100 text-red-700'
                    }`}>
                      {stat.isActive !== false ? 'Active' : 'Inactive'}
                    </span>
                  </td>
                  <td className="px-4 py-3">{stat.memberCount || 0}</td>
                  <td className="px-4 py-3">{stat.totalVoices || 0}</td>
                  <td className="px-4 py-3">{formatDuration(stat.totalDuration || 0)}</td>
                  <td className="px-4 py-3">
                    <button
                      onClick={() => {
                        setViewType('channel');
                        setSelectedId(stat.channelId);
                        setPeriod('monthly');
                      }}
                      className="text-primary-600 hover:text-primary-800 text-sm"
                    >
                      View Details
                    </button>
                  </td>
                </tr>
              ))}
              {channelOverview.length === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-8 text-center text-gray-500">
                    No channel usage data available
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* User Stats Table */}
      <div>
        <h2 className="text-lg font-semibold mb-4">User Usage (This Month)</h2>
        <div className="card overflow-hidden">
          <table className="w-full">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">User</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Phone</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Voices Sent</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Duration</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {userOverview.map((stat) => (
                <tr key={stat.userId} className="hover:bg-gray-50">
                  <td className="px-4 py-3 font-medium">{stat.userName || 'Unknown'}</td>
                  <td className="px-4 py-3 text-gray-500">{stat.phoneNumber || '-'}</td>
                  <td className="px-4 py-3">{stat.voicesSent || 0}</td>
                  <td className="px-4 py-3">{formatDuration(stat.durationSent || 0)}</td>
                  <td className="px-4 py-3">
                    <button
                      onClick={() => {
                        setViewType('user');
                        setSelectedId(stat.userId);
                        setPeriod('monthly');
                      }}
                      className="text-primary-600 hover:text-primary-800 text-sm"
                    >
                      View Details
                    </button>
                  </td>
                </tr>
              ))}
              {userOverview.length === 0 && (
                <tr>
                  <td colSpan={5} className="px-4 py-8 text-center text-gray-500">
                    No user usage data available
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );

  const renderChannelDetail = () => {
    const channel = channels.find((c) => c.id === selectedId);
    return (
      <div className="space-y-6">
        <div className="flex items-center gap-4">
          <button
            onClick={() => {
              setViewType('overview');
              setSelectedId('');
            }}
            className="p-2 hover:bg-gray-100 rounded-lg"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div>
            <h2 className="text-xl font-semibold">{channel?.name || 'Channel'} Stats</h2>
            <p className="text-sm text-gray-500">Detailed usage statistics</p>
          </div>
        </div>

        {/* Period Selector */}
        <div className="flex gap-2">
          <button
            onClick={() => setPeriod('daily')}
            className={`px-4 py-2 rounded-lg text-sm font-medium ${
              period === 'daily'
                ? 'bg-primary-600 text-white'
                : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
            }`}
          >
            Daily
          </button>
          <button
            onClick={() => setPeriod('monthly')}
            className={`px-4 py-2 rounded-lg text-sm font-medium ${
              period === 'monthly'
                ? 'bg-primary-600 text-white'
                : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
            }`}
          >
            Monthly
          </button>
          <button
            onClick={() => setPeriod('users')}
            className={`px-4 py-2 rounded-lg text-sm font-medium ${
              period === 'users'
                ? 'bg-primary-600 text-white'
                : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
            }`}
          >
            By User
          </button>
        </div>

        {/* Stats Table */}
        <div className="card overflow-hidden">
          {period === 'users' ? (
            <table className="w-full">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">User</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Voices</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Duration</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-200">
                {(detailStats as ChannelUserStats[]).map((stat, idx) => (
                  <tr key={idx} className="hover:bg-gray-50">
                    <td className="px-4 py-3 font-medium">{stat.userName}</td>
                    <td className="px-4 py-3">{stat.totalVoices}</td>
                    <td className="px-4 py-3">{formatDuration(stat.totalDuration)}</td>
                  </tr>
                ))}
                {detailStats.length === 0 && (
                  <tr>
                    <td colSpan={3} className="px-4 py-8 text-center text-gray-500">
                      No data available
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          ) : (
            <table className="w-full">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    {period === 'daily' ? 'Date' : 'Month'}
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Voices</th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Duration</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-200">
                {(detailStats as ChannelStats[]).map((stat, idx) => (
                  <tr key={idx} className="hover:bg-gray-50">
                    <td className="px-4 py-3 font-medium">{stat.date || stat.month}</td>
                    <td className="px-4 py-3">{stat.totalVoices}</td>
                    <td className="px-4 py-3">{formatDuration(stat.totalDuration)}</td>
                  </tr>
                ))}
                {detailStats.length === 0 && (
                  <tr>
                    <td colSpan={3} className="px-4 py-8 text-center text-gray-500">
                      No data available
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          )}
        </div>
      </div>
    );
  };

  const renderUserDetail = () => {
    const user = users.find((u) => u.id === selectedId);
    return (
      <div className="space-y-6">
        <div className="flex items-center gap-4">
          <button
            onClick={() => {
              setViewType('overview');
              setSelectedId('');
            }}
            className="p-2 hover:bg-gray-100 rounded-lg"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div>
            <h2 className="text-xl font-semibold">{user?.displayName || 'User'} Stats</h2>
            <p className="text-sm text-gray-500">{user?.phoneNumber || 'Detailed usage statistics'}</p>
          </div>
        </div>

        {/* Period Selector */}
        <div className="flex gap-2">
          <button
            onClick={() => setPeriod('daily')}
            className={`px-4 py-2 rounded-lg text-sm font-medium ${
              period === 'daily'
                ? 'bg-primary-600 text-white'
                : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
            }`}
          >
            Daily
          </button>
          <button
            onClick={() => setPeriod('monthly')}
            className={`px-4 py-2 rounded-lg text-sm font-medium ${
              period === 'monthly'
                ? 'bg-primary-600 text-white'
                : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
            }`}
          >
            Monthly
          </button>
        </div>

        {/* Stats Table */}
        <div className="card overflow-hidden">
          <table className="w-full">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  {period === 'daily' ? 'Date' : 'Month'}
                </th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Voices Sent</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Duration</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {(detailStats as UserStats[]).map((stat, idx) => (
                <tr key={idx} className="hover:bg-gray-50">
                  <td className="px-4 py-3 font-medium">{stat.date || stat.month}</td>
                  <td className="px-4 py-3">{stat.voicesSent}</td>
                  <td className="px-4 py-3">{formatDuration(stat.durationSent)}</td>
                </tr>
              ))}
              {detailStats.length === 0 && (
                <tr>
                  <td colSpan={3} className="px-4 py-8 text-center text-gray-500">
                    No data available
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    );
  };

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Usage Reports</h1>
          <p className="text-gray-500 mt-1">View voice usage statistics for channels and users</p>
        </div>
      </div>

      {loading ? (
        <div className="text-center py-12">
          <div className="inline-block animate-spin rounded-full h-8 w-8 border-4 border-gray-300 border-t-primary-600"></div>
        </div>
      ) : viewType === 'overview' ? (
        renderOverview()
      ) : viewType === 'channel' ? (
        renderChannelDetail()
      ) : (
        renderUserDetail()
      )}
    </div>
  );
}
