'use client';

import { useState, useEffect } from 'react';
import toast from 'react-hot-toast';
import { Plus, Pencil, Trash2, Users, Lock, Unlock, Search } from 'lucide-react';
import { Channel } from '@/types';
import ChannelModal from '@/components/ChannelModal';
import ConfirmDialog from '@/components/ConfirmDialog';

export default function ChannelsPage() {
  const [channels, setChannels] = useState<Channel[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [editingChannel, setEditingChannel] = useState<Channel | null>(null);
  const [deleteDialog, setDeleteDialog] = useState<{ open: boolean; channel: Channel | null }>({
    open: false,
    channel: null,
  });

  useEffect(() => {
    fetchChannels();
  }, []);

  const fetchChannels = async () => {
    try {
      const res = await fetch('/api/channels');
      const data = await res.json();
      setChannels(data.channels || []);
    } catch (error) {
      toast.error('Failed to fetch channels');
    } finally {
      setLoading(false);
    }
  };

  const handleCreate = () => {
    setEditingChannel(null);
    setModalOpen(true);
  };

  const handleEdit = (channel: Channel) => {
    setEditingChannel(channel);
    setModalOpen(true);
  };

  const handleDelete = async () => {
    if (!deleteDialog.channel) return;

    try {
      const res = await fetch(`/api/channels/${deleteDialog.channel.id}`, {
        method: 'DELETE',
      });

      if (!res.ok) throw new Error('Failed to delete');

      toast.success('Channel deleted successfully');
      setDeleteDialog({ open: false, channel: null });
      fetchChannels();
    } catch (error) {
      toast.error('Failed to delete channel');
    }
  };

  const handleSave = async (data: Partial<Channel>) => {
    try {
      const url = editingChannel
        ? `/api/channels/${editingChannel.id}`
        : '/api/channels';
      const method = editingChannel ? 'PUT' : 'POST';

      const res = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      });

      if (!res.ok) throw new Error('Failed to save');

      toast.success(editingChannel ? 'Channel updated' : 'Channel created');
      setModalOpen(false);
      fetchChannels();
    } catch (error) {
      toast.error('Failed to save channel');
    }
  };

  const filteredChannels = channels.filter(
    (channel) =>
      channel.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      channel.description?.toLowerCase().includes(searchTerm.toLowerCase())
  );

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Channels</h1>
          <p className="text-gray-500 mt-1">Manage your PTT channels</p>
        </div>
        <button onClick={handleCreate} className="btn btn-primary flex items-center gap-2">
          <Plus className="w-4 h-4" />
          Create Channel
        </button>
      </div>

      <div className="card mb-6">
        <div className="relative">
          <Search className="w-5 h-5 text-gray-400 absolute left-3 top-1/2 -translate-y-1/2" />
          <input
            type="text"
            placeholder="Search channels..."
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
      ) : filteredChannels.length === 0 ? (
        <div className="text-center py-12 card">
          <p className="text-gray-500">No channels found</p>
        </div>
      ) : (
        <div className="grid gap-4">
          {filteredChannels.map((channel) => (
            <div key={channel.id} className="card flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="w-12 h-12 bg-primary-100 rounded-lg flex items-center justify-center">
                  {channel.isPrivate ? (
                    <Lock className="w-6 h-6 text-primary-600" />
                  ) : (
                    <Unlock className="w-6 h-6 text-primary-600" />
                  )}
                </div>
                <div>
                  <h3 className="font-semibold text-gray-900">{channel.name}</h3>
                  <p className="text-sm text-gray-500">
                    {channel.description || 'No description'}
                  </p>
                  <div className="flex items-center gap-4 mt-1 text-xs text-gray-400">
                    <span className="flex items-center gap-1">
                      <Users className="w-3 h-3" />
                      {channel.memberCount} members
                    </span>
                    <span>{channel.isPrivate ? 'Private' : 'Public'}</span>
                  </div>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => handleEdit(channel)}
                  className="p-2 text-gray-400 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
                >
                  <Pencil className="w-4 h-4" />
                </button>
                <button
                  onClick={() => setDeleteDialog({ open: true, channel })}
                  className="p-2 text-gray-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      <ChannelModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        onSave={handleSave}
        channel={editingChannel}
      />

      <ConfirmDialog
        open={deleteDialog.open}
        onClose={() => setDeleteDialog({ open: false, channel: null })}
        onConfirm={handleDelete}
        title="Delete Channel"
        message={`Are you sure you want to delete "${deleteDialog.channel?.name}"? This action cannot be undone.`}
      />
    </div>
  );
}
