'use client';

import { useState, useEffect } from 'react';
import { X, Eye, EyeOff } from 'lucide-react';
import { User, Organization } from '@/types';

interface UserModalProps {
  open: boolean;
  onClose: () => void;
  onSave: (data: Partial<User> & { password?: string; organizationId?: string }) => void;
  user: User | null;
}

interface AdminInfo {
  role: string;
  organizationId: string | null;
}

export default function UserModal({
  open,
  onClose,
  onSave,
  user,
}: UserModalProps) {
  const [displayName, setDisplayName] = useState('');
  const [phoneNumber, setPhoneNumber] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [status, setStatus] = useState<User['status']>('offline');
  const [organizationId, setOrganizationId] = useState('');
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [adminInfo, setAdminInfo] = useState<AdminInfo | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadingOrgs, setLoadingOrgs] = useState(false);

  // Fetch admin info and organizations on mount
  useEffect(() => {
    const fetchAdminInfo = async () => {
      try {
        const res = await fetch('/api/auth/me');
        if (res.ok) {
          const data = await res.json();
          setAdminInfo(data);

          // If super_admin, fetch organizations
          if (data.role === 'super_admin') {
            setLoadingOrgs(true);
            const orgsRes = await fetch('/api/organizations');
            if (orgsRes.ok) {
              const orgsData = await orgsRes.json();
              setOrganizations(orgsData.organizations || []);
            }
            setLoadingOrgs(false);
          }
        }
      } catch (error) {
        console.error('Failed to fetch admin info:', error);
      }
    };

    if (open) {
      fetchAdminInfo();
    }
  }, [open]);

  useEffect(() => {
    if (user) {
      setDisplayName(user.displayName);
      setPhoneNumber(user.phoneNumber);
      setEmail(user.email || '');
      setPassword('');
      setStatus(user.status);
      setOrganizationId(user.organizationId || '');
    } else {
      setDisplayName('');
      setPhoneNumber('');
      setEmail('');
      setPassword('');
      setStatus('offline');
      // For org_admin, organization is auto-assigned; for super_admin, select first org
      if (adminInfo?.role === 'super_admin' && organizations.length > 0) {
        setOrganizationId(organizations[0].id);
      } else {
        setOrganizationId('');
      }
    }
  }, [user, open, adminInfo, organizations]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);

    try {
      await onSave({
        displayName,
        phoneNumber,
        email: email || undefined,
        password: password || undefined,
        status,
        organizationId: organizationId || undefined,
      });
    } finally {
      setLoading(false);
    }
  };

  const isSuperAdmin = adminInfo?.role === 'super_admin';
  const needsOrgSelection = isSuperAdmin && !user; // Only for creating new users as super_admin

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="relative bg-white rounded-xl shadow-xl w-full max-w-md mx-4 p-6">
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-xl font-bold text-gray-900">
            {user ? 'Edit User' : 'Create User'}
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
            <label htmlFor="displayName" className="form-label">
              Display Name *
            </label>
            <input
              id="displayName"
              type="text"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              className="form-input"
              placeholder="Enter display name"
              required
            />
          </div>

          <div>
            <label htmlFor="phoneNumber" className="form-label">
              Phone Number *
            </label>
            <input
              id="phoneNumber"
              type="tel"
              value={phoneNumber}
              onChange={(e) => setPhoneNumber(e.target.value)}
              className="form-input"
              placeholder="+1234567890"
              required
            />
          </div>

          <div>
            <label htmlFor="email" className="form-label">
              Email
            </label>
            <input
              id="email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="form-input"
              placeholder="user@example.com"
            />
          </div>

          <div>
            <label htmlFor="password" className="form-label">
              Password {user ? '(leave blank to keep current)' : '*'}
            </label>
            <div className="relative">
              <input
                id="password"
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="form-input pr-10"
                placeholder={user ? 'Enter new password' : 'Enter password'}
                required={!user}
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

          <div>
            <label htmlFor="status" className="form-label">
              Status
            </label>
            <select
              id="status"
              value={status}
              onChange={(e) => setStatus(e.target.value as User['status'])}
              className="form-input"
            >
              <option value="online">Online</option>
              <option value="away">Away</option>
              <option value="busy">Busy</option>
              <option value="offline">Offline</option>
            </select>
          </div>

          {needsOrgSelection && (
            <div>
              <label htmlFor="organizationId" className="form-label">
                Organization *
              </label>
              {loadingOrgs ? (
                <div className="form-input bg-gray-50 text-gray-500">Loading organizations...</div>
              ) : organizations.length === 0 ? (
                <div className="form-input bg-red-50 text-red-600">
                  No organizations found. Please create an organization first.
                </div>
              ) : (
                <select
                  id="organizationId"
                  value={organizationId}
                  onChange={(e) => setOrganizationId(e.target.value)}
                  className="form-input"
                  required
                >
                  <option value="">Select an organization</option>
                  {organizations.map((org) => (
                    <option key={org.id} value={org.id}>
                      {org.name} ({org.currentUsers || 0}/{org.packageMaxUsers} users)
                    </option>
                  ))}
                </select>
              )}
            </div>
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
                !displayName.trim() ||
                !phoneNumber.trim() ||
                (!user && !password.trim()) ||
                (needsOrgSelection && !organizationId)
              }
              className="btn btn-primary flex-1"
            >
              {loading ? 'Saving...' : user ? 'Update' : 'Create'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
