'use client';

import { useState, useEffect } from 'react';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  Building2,
  Users,
  Radio,
  ArrowLeft,
  Save,
  Mail,
  User,
} from 'lucide-react';

interface OrgDetail {
  id: string;
  name: string;
  packageMaxUsers: number;
  packageMaxChannels: number;
  currentUsers: number;
  currentChannels: number;
  orgAdmin: {
    id: string;
    email: string;
    displayName: string;
  } | null;
  createdAt: string | null;
}

export default function OrganizationDetailPage() {
  const { id } = useParams();
  const router = useRouter();
  const [org, setOrg] = useState<OrgDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [name, setName] = useState('');
  const [maxUsers, setMaxUsers] = useState(0);
  const [maxChannels, setMaxChannels] = useState(0);

  useEffect(() => {
    fetchOrg();
  }, [id]);

  const fetchOrg = async () => {
    try {
      const res = await fetch(`/api/organizations/${id}`);
      if (!res.ok) throw new Error('Failed to fetch');
      const data = await res.json();
      setOrg(data.organization);
      setName(data.organization.name);
      setMaxUsers(data.organization.packageMaxUsers);
      setMaxChannels(data.organization.packageMaxChannels);
    } catch (error) {
      toast.error('Failed to fetch organization');
      router.push('/dashboard/organizations');
    } finally {
      setLoading(false);
    }
  };

  const handleSave = async () => {
    setSaving(true);
    try {
      const res = await fetch(`/api/organizations/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name,
          packageMaxUsers: maxUsers,
          packageMaxChannels: maxChannels,
        }),
      });

      if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        throw new Error(errorData.error || 'Failed to update');
      }

      toast.success('Organization updated');
      fetchOrg();
    } catch (error: any) {
      toast.error(error.message || 'Failed to update organization');
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return (
      <div className="text-center py-12">
        <div className="inline-block animate-spin rounded-full h-8 w-8 border-4 border-gray-300 border-t-primary-600"></div>
      </div>
    );
  }

  if (!org) return null;

  return (
    <div>
      <div className="flex items-center gap-4 mb-6">
        <button
          onClick={() => router.push('/dashboard/organizations')}
          className="p-2 text-gray-400 hover:text-gray-600 hover:bg-gray-100 rounded-lg"
        >
          <ArrowLeft className="w-5 h-5" />
        </button>
        <div>
          <h1 className="text-2xl font-bold text-gray-900">{org.name}</h1>
          <p className="text-gray-500 mt-1">Organization details and package configuration</p>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Package Config */}
        <div className="lg:col-span-2 card">
          <h2 className="text-lg font-semibold text-gray-900 mb-4">Package Configuration</h2>
          <div className="space-y-4">
            <div>
              <label htmlFor="orgName" className="form-label">Organization Name</label>
              <input
                id="orgName"
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="form-input"
              />
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label htmlFor="maxUsers" className="form-label">
                  Max Users
                </label>
                <input
                  id="maxUsers"
                  type="number"
                  min={1}
                  value={maxUsers}
                  onChange={(e) => setMaxUsers(Number(e.target.value))}
                  className="form-input"
                />
                <p className="text-xs text-gray-400 mt-1">
                  Currently using {org.currentUsers} of {org.packageMaxUsers}
                </p>
              </div>
              <div>
                <label htmlFor="maxChannels" className="form-label">
                  Max Channels
                </label>
                <input
                  id="maxChannels"
                  type="number"
                  min={1}
                  value={maxChannels}
                  onChange={(e) => setMaxChannels(Number(e.target.value))}
                  className="form-input"
                />
                <p className="text-xs text-gray-400 mt-1">
                  Currently using {org.currentChannels} of {org.packageMaxChannels}
                </p>
              </div>
            </div>

            <button
              onClick={handleSave}
              disabled={saving || !name.trim()}
              className="btn btn-primary flex items-center gap-2"
            >
              <Save className="w-4 h-4" />
              {saving ? 'Saving...' : 'Save Changes'}
            </button>
          </div>
        </div>

        {/* Sidebar Info */}
        <div className="space-y-6">
          {/* Usage Stats */}
          <div className="card">
            <h3 className="text-sm font-semibold text-gray-700 mb-3">Usage</h3>
            <div className="space-y-3">
              <div>
                <div className="flex justify-between text-sm mb-1">
                  <span className="flex items-center gap-1 text-gray-600">
                    <Users className="w-4 h-4" /> Users
                  </span>
                  <span className="font-medium">{org.currentUsers}/{org.packageMaxUsers}</span>
                </div>
                <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
                  <div
                    className={`h-full rounded-full ${
                      org.currentUsers / org.packageMaxUsers > 0.9 ? 'bg-red-500' :
                      org.currentUsers / org.packageMaxUsers > 0.7 ? 'bg-yellow-500' :
                      'bg-green-500'
                    }`}
                    style={{ width: `${Math.min(100, (org.currentUsers / org.packageMaxUsers) * 100)}%` }}
                  />
                </div>
              </div>
              <div>
                <div className="flex justify-between text-sm mb-1">
                  <span className="flex items-center gap-1 text-gray-600">
                    <Radio className="w-4 h-4" /> Channels
                  </span>
                  <span className="font-medium">{org.currentChannels}/{org.packageMaxChannels}</span>
                </div>
                <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
                  <div
                    className={`h-full rounded-full ${
                      org.currentChannels / org.packageMaxChannels > 0.9 ? 'bg-red-500' :
                      org.currentChannels / org.packageMaxChannels > 0.7 ? 'bg-yellow-500' :
                      'bg-green-500'
                    }`}
                    style={{ width: `${Math.min(100, (org.currentChannels / org.packageMaxChannels) * 100)}%` }}
                  />
                </div>
              </div>
            </div>
          </div>

          {/* Org Admin */}
          <div className="card">
            <h3 className="text-sm font-semibold text-gray-700 mb-3">Organization Admin</h3>
            {org.orgAdmin ? (
              <div className="space-y-2">
                <div className="flex items-center gap-2 text-sm text-gray-600">
                  <User className="w-4 h-4" />
                  <span>{org.orgAdmin.displayName}</span>
                </div>
                <div className="flex items-center gap-2 text-sm text-gray-600">
                  <Mail className="w-4 h-4" />
                  <span>{org.orgAdmin.email}</span>
                </div>
              </div>
            ) : (
              <p className="text-sm text-gray-500">No admin assigned</p>
            )}
          </div>

          {/* Quick Links */}
          <div className="card">
            <h3 className="text-sm font-semibold text-gray-700 mb-3">Quick Links</h3>
            <div className="space-y-2">
              <a
                href={`/dashboard/users?organizationId=${org.id}`}
                className="flex items-center gap-2 text-sm text-primary-600 hover:text-primary-700"
              >
                <Users className="w-4 h-4" />
                View Users ({org.currentUsers})
              </a>
              <a
                href={`/dashboard/channels?organizationId=${org.id}`}
                className="flex items-center gap-2 text-sm text-primary-600 hover:text-primary-700"
              >
                <Radio className="w-4 h-4" />
                View Channels ({org.currentChannels})
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
