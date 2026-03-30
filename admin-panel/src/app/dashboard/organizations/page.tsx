'use client';

import { useState, useEffect } from 'react';
import toast from 'react-hot-toast';
import { Plus, Pencil, Trash2, Building2, Users, Radio, Search } from 'lucide-react';
import OrganizationModal from '@/components/OrganizationModal';
import ConfirmDialog from '@/components/ConfirmDialog';

interface OrgData {
  id: string;
  name: string;
  packageMaxUsers: number;
  packageMaxChannels: number;
  orgAdminId: string;
  orgAdminEmail: string;
  currentUsers: number;
  currentChannels: number;
  createdAt: string | null;
}

export default function OrganizationsPage() {
  const [organizations, setOrganizations] = useState<OrgData[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [editingOrg, setEditingOrg] = useState<OrgData | null>(null);
  const [deleteDialog, setDeleteDialog] = useState<{ open: boolean; org: OrgData | null }>({
    open: false,
    org: null,
  });

  useEffect(() => {
    fetchOrganizations();
  }, []);

  const fetchOrganizations = async () => {
    try {
      const res = await fetch('/api/organizations');
      const data = await res.json();
      setOrganizations(data.organizations || []);
    } catch (error) {
      toast.error('Failed to fetch organizations');
    } finally {
      setLoading(false);
    }
  };

  const handleCreate = () => {
    setEditingOrg(null);
    setModalOpen(true);
  };

  const handleEdit = (org: OrgData) => {
    setEditingOrg(org);
    setModalOpen(true);
  };

  const handleDelete = async () => {
    if (!deleteDialog.org) return;

    try {
      const res = await fetch(`/api/organizations/${deleteDialog.org.id}`, {
        method: 'DELETE',
      });

      if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        throw new Error(errorData.error || 'Failed to delete organization');
      }

      toast.success('Organization deleted successfully');
      setDeleteDialog({ open: false, org: null });
      fetchOrganizations();
    } catch (error: any) {
      toast.error(error.message || 'Failed to delete organization');
    }
  };

  const handleSave = async (data: any) => {
    try {
      const url = editingOrg
        ? `/api/organizations/${editingOrg.id}`
        : '/api/organizations';
      const method = editingOrg ? 'PUT' : 'POST';

      const res = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      });

      if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        throw new Error(errorData.error || 'Failed to save organization');
      }

      toast.success(editingOrg ? 'Organization updated' : 'Organization created');
      setModalOpen(false);
      fetchOrganizations();
    } catch (error: any) {
      toast.error(error.message || 'Failed to save organization');
    }
  };

  const filteredOrgs = organizations.filter(
    (org) =>
      org.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      org.orgAdminEmail?.toLowerCase().includes(searchTerm.toLowerCase())
  );

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Organizations</h1>
          <p className="text-gray-500 mt-1">Manage organizations and their packages</p>
        </div>
        <button onClick={handleCreate} className="btn btn-primary flex items-center gap-2">
          <Plus className="w-4 h-4" />
          Create Organization
        </button>
      </div>

      <div className="card mb-6">
        <div className="relative">
          <Search className="w-5 h-5 text-gray-400 absolute left-3 top-1/2 -translate-y-1/2" />
          <input
            type="text"
            placeholder="Search organizations..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="form-input pl-10"
          />
        </div>
      </div>

      {loading ? (
        <div className="text-center py-12">
          <div className="inline-block animate-spin rounded-full h-8 w-8 border-4 border-gray-300 border-t-primary-600"></div>
        </div>
      ) : filteredOrgs.length === 0 ? (
        <div className="text-center py-12 card">
          <p className="text-gray-500">No organizations found</p>
        </div>
      ) : (
        <div className="grid gap-4">
          {filteredOrgs.map((org) => (
            <div key={org.id} className="card">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-4">
                  <div className="w-12 h-12 bg-primary-100 rounded-lg flex items-center justify-center">
                    <Building2 className="w-6 h-6 text-primary-600" />
                  </div>
                  <div>
                    <h3 className="font-semibold text-gray-900">{org.name}</h3>
                    <p className="text-sm text-gray-500">
                      Admin: {org.orgAdminEmail || 'Not assigned'}
                    </p>
                    <div className="flex items-center gap-4 mt-1">
                      <span className="flex items-center gap-1 text-xs text-gray-400">
                        <Users className="w-3 h-3" />
                        {org.currentUsers}/{org.packageMaxUsers} users
                      </span>
                      <span className="flex items-center gap-1 text-xs text-gray-400">
                        <Radio className="w-3 h-3" />
                        {org.currentChannels}/{org.packageMaxChannels} channels
                      </span>
                    </div>
                  </div>
                </div>

                <div className="flex items-center gap-4">
                  {/* Usage bars */}
                  <div className="hidden md:flex items-center gap-3">
                    <div className="w-24">
                      <div className="text-xs text-gray-500 mb-1">Users</div>
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
                    <div className="w-24">
                      <div className="text-xs text-gray-500 mb-1">Channels</div>
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

                  <div className="flex items-center gap-2">
                    <button
                      onClick={() => handleEdit(org)}
                      className="p-2 text-gray-400 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
                    >
                      <Pencil className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => setDeleteDialog({ open: true, org })}
                      className="p-2 text-gray-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      <OrganizationModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        onSave={handleSave}
        organization={editingOrg}
      />

      <ConfirmDialog
        open={deleteDialog.open}
        onClose={() => setDeleteDialog({ open: false, org: null })}
        onConfirm={handleDelete}
        title="Delete Organization"
        message={`Are you sure you want to delete "${deleteDialog.org?.name}"? This will delete ALL users, channels, and data in this organization. This action cannot be undone.`}
      />
    </div>
  );
}
