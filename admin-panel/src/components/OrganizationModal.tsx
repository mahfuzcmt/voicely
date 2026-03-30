'use client';

import { useState, useEffect } from 'react';
import { X, Eye, EyeOff } from 'lucide-react';

interface OrganizationData {
  id?: string;
  name: string;
  packageMaxUsers: number;
  packageMaxChannels: number;
  orgAdminEmail?: string;
  orgAdminDisplayName?: string;
}

interface OrganizationModalProps {
  open: boolean;
  onClose: () => void;
  onSave: (data: any) => void;
  organization: OrganizationData | null;
}

export default function OrganizationModal({
  open,
  onClose,
  onSave,
  organization,
}: OrganizationModalProps) {
  const [name, setName] = useState('');
  const [packageMaxUsers, setPackageMaxUsers] = useState(50);
  const [packageMaxChannels, setPackageMaxChannels] = useState(20);
  const [orgAdminEmail, setOrgAdminEmail] = useState('');
  const [orgAdminPassword, setOrgAdminPassword] = useState('');
  const [orgAdminDisplayName, setOrgAdminDisplayName] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (organization) {
      setName(organization.name);
      setPackageMaxUsers(organization.packageMaxUsers);
      setPackageMaxChannels(organization.packageMaxChannels);
      setOrgAdminEmail('');
      setOrgAdminPassword('');
      setOrgAdminDisplayName('');
    } else {
      setName('');
      setPackageMaxUsers(50);
      setPackageMaxChannels(20);
      setOrgAdminEmail('');
      setOrgAdminPassword('');
      setOrgAdminDisplayName('');
    }
  }, [organization, open]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);

    try {
      const data: any = {
        name,
        packageMaxUsers,
        packageMaxChannels,
      };

      if (!organization) {
        data.orgAdminEmail = orgAdminEmail;
        data.orgAdminPassword = orgAdminPassword;
        data.orgAdminDisplayName = orgAdminDisplayName;
      }

      await onSave(data);
    } finally {
      setLoading(false);
    }
  };

  if (!open) return null;

  const isEditing = !!organization;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="relative bg-white rounded-xl shadow-xl w-full max-w-md mx-4 p-6 max-h-[90vh] overflow-y-auto">
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-xl font-bold text-gray-900">
            {isEditing ? 'Edit Organization' : 'Create Organization'}
          </h2>
          <button
            onClick={onClose}
            className="p-2 text-gray-400 hover:text-gray-600 rounded-lg"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label htmlFor="orgName" className="form-label">
              Organization Name *
            </label>
            <input
              id="orgName"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="form-input"
              placeholder="Enter organization name"
              required
            />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label htmlFor="maxUsers" className="form-label">
                Max Users *
              </label>
              <input
                id="maxUsers"
                type="number"
                min={1}
                value={packageMaxUsers}
                onChange={(e) => setPackageMaxUsers(Number(e.target.value))}
                className="form-input"
                required
              />
            </div>
            <div>
              <label htmlFor="maxChannels" className="form-label">
                Max Channels *
              </label>
              <input
                id="maxChannels"
                type="number"
                min={1}
                value={packageMaxChannels}
                onChange={(e) => setPackageMaxChannels(Number(e.target.value))}
                className="form-input"
                required
              />
            </div>
          </div>

          {!isEditing && (
            <>
              <div className="border-t border-gray-200 pt-4 mt-4">
                <h3 className="text-sm font-semibold text-gray-700 mb-3">Org Admin Account</h3>
              </div>

              <div>
                <label htmlFor="adminName" className="form-label">
                  Admin Display Name *
                </label>
                <input
                  id="adminName"
                  type="text"
                  value={orgAdminDisplayName}
                  onChange={(e) => setOrgAdminDisplayName(e.target.value)}
                  className="form-input"
                  placeholder="Enter admin name"
                  required
                />
              </div>

              <div>
                <label htmlFor="adminEmail" className="form-label">
                  Admin Email *
                </label>
                <input
                  id="adminEmail"
                  type="email"
                  value={orgAdminEmail}
                  onChange={(e) => setOrgAdminEmail(e.target.value)}
                  className="form-input"
                  placeholder="admin@example.com"
                  required
                />
              </div>

              <div>
                <label htmlFor="adminPassword" className="form-label">
                  Admin Password *
                </label>
                <div className="relative">
                  <input
                    id="adminPassword"
                    type={showPassword ? 'text' : 'password'}
                    value={orgAdminPassword}
                    onChange={(e) => setOrgAdminPassword(e.target.value)}
                    className="form-input pr-10"
                    placeholder="Enter password"
                    required
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword(!showPassword)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-600"
                  >
                    {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                  </button>
                </div>
              </div>
            </>
          )}

          <div className="flex gap-3 pt-4">
            <button
              type="button"
              onClick={onClose}
              className="btn btn-secondary flex-1"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={
                loading ||
                !name.trim() ||
                (!isEditing && (!orgAdminEmail.trim() || !orgAdminPassword.trim() || !orgAdminDisplayName.trim()))
              }
              className="btn btn-primary flex-1"
            >
              {loading ? 'Saving...' : isEditing ? 'Update' : 'Create'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
