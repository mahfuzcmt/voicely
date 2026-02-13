export interface Admin {
  id: string;
  email: string;
  displayName: string;
  role: 'super_admin' | 'admin';
  createdAt: Date;
  updatedAt: Date;
}

export interface User {
  id: string;
  phoneNumber: string;
  displayName: string;
  email?: string;
  photoUrl?: string;
  status: 'online' | 'away' | 'busy' | 'offline';
  lastSeen?: Date;
  createdAt?: Date;
  updatedAt?: Date;
}

export interface Channel {
  id: string;
  name: string;
  description?: string;
  ownerId: string;
  imageUrl?: string;
  isPrivate: boolean;
  memberCount: number;
  memberIds: string[];
  audioArchiveEnabled?: boolean;
  createdAt?: Date;
  updatedAt?: Date;
}

export interface ChannelMember {
  id: string;
  userId: string;
  channelId: string;
  role: 'owner' | 'admin' | 'member';
  isMuted: boolean;
  joinedAt?: Date;
}

export interface DashboardStats {
  totalUsers: number;
  totalChannels: number;
  activeUsers: number;
  totalMessages: number;
}
