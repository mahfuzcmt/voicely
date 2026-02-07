'use client';

import { useState, useEffect } from 'react';
import { X, Check } from 'lucide-react';
import { User, Channel } from '@/types';

interface AssignChannelModalProps {
  open: boolean;
  onClose: () => void;
  onSave: (channelIds: string[]) => void;
  user: User | null;
  channels: Channel[];
}

export default function AssignChannelModal({
  open,
  onClose,
  onSave,
  user,
  channels,
}: AssignChannelModalProps) {
  const [selectedChannels, setSelectedChannels] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (user && open) {
      // Fetch user's current channels
      fetchUserChannels();
    }
  }, [user, open]);

  const fetchUserChannels = async () => {
    if (!user) return;

    try {
      const res = await fetch(`/api/users/${user.id}/channels`);
      const data = await res.json();
      setSelectedChannels(data.channelIds || []);
    } catch (error) {
      console.error('Failed to fetch user channels');
      setSelectedChannels([]);
    }
  };

  const toggleChannel = (channelId: string) => {
    setSelectedChannels((prev) =>
      prev.includes(channelId)
        ? prev.filter((id) => id !== channelId)
        : [...prev, channelId]
    );
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);

    try {
      await onSave(selectedChannels);
    } finally {
      setLoading(false);
    }
  };

  if (!open || !user) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="relative bg-white rounded-xl shadow-xl w-full max-w-md mx-4 p-6 max-h-[90vh] overflow-hidden flex flex-col">
        <div className="flex items-center justify-between mb-6">
          <div>
            <h2 className="text-xl font-bold text-gray-900">Assign Channels</h2>
            <p className="text-sm text-gray-500 mt-1">
              Select channels for {user.displayName}
            </p>
          </div>
          <button
            onClick={onClose}
            className="p-2 text-gray-400 hover:text-gray-600 rounded-lg"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="flex flex-col flex-1 overflow-hidden">
          <div className="flex-1 overflow-y-auto space-y-2 mb-4">
            {channels.length === 0 ? (
              <p className="text-center text-gray-500 py-4">No channels available</p>
            ) : (
              channels.map((channel) => (
                <label
                  key={channel.id}
                  className={`flex items-center gap-3 p-3 rounded-lg cursor-pointer transition-colors ${
                    selectedChannels.includes(channel.id)
                      ? 'bg-primary-50 border-2 border-primary-500'
                      : 'bg-gray-50 border-2 border-transparent hover:bg-gray-100'
                  }`}
                >
                  <input
                    type="checkbox"
                    checked={selectedChannels.includes(channel.id)}
                    onChange={() => toggleChannel(channel.id)}
                    className="sr-only"
                  />
                  <div
                    className={`w-5 h-5 rounded flex items-center justify-center ${
                      selectedChannels.includes(channel.id)
                        ? 'bg-primary-600'
                        : 'bg-white border-2 border-gray-300'
                    }`}
                  >
                    {selectedChannels.includes(channel.id) && (
                      <Check className="w-3 h-3 text-white" />
                    )}
                  </div>
                  <div className="flex-1">
                    <p className="font-medium text-gray-900">{channel.name}</p>
                    {channel.description && (
                      <p className="text-sm text-gray-500">{channel.description}</p>
                    )}
                  </div>
                  <span className="text-xs text-gray-400">
                    {channel.memberCount} members
                  </span>
                </label>
              ))
            )}
          </div>

          <div className="flex gap-3 pt-4 border-t border-gray-100">
            <button
              type="button"
              onClick={onClose}
              className="btn btn-secondary flex-1"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={loading}
              className="btn btn-primary flex-1"
            >
              {loading ? 'Saving...' : `Assign ${selectedChannels.length} Channels`}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
