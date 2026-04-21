export interface Organization {
  id: string;
  name: string;
  packageMaxUsers: number;
  packageMaxChannels: number;
  orgAdminId: string;
  orgAdminEmail?: string;
  currentUsers?: number;
  currentChannels?: number;
  createdAt: Date;
  updatedAt: Date;
}

export interface Admin {
  id: string;
  email: string;
  displayName: string;
  role: 'super_admin' | 'org_admin';
  organizationId?: string | null;
  organizationName?: string | null;
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
  organizationId: string;
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
  isActive: boolean; // For billing - if false, PTT is disabled
  memberCount: number;
  memberIds: string[];
  audioArchiveEnabled?: boolean;
  organizationId: string;
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
  organizationName?: string;
  packageMaxUsers?: number;
  packageMaxChannels?: number;
}

// Usage statistics types
export interface UserDailyStats {
  userId: string;
  userName: string;
  date: string;
  voicesSent: number;
  durationSent: number; // in seconds
  lastActivity?: Date;
}

export interface UserMonthlyStats {
  userId: string;
  userName: string;
  month: string;
  voicesSent: number;
  durationSent: number;
  lastActivity?: Date;
}

export interface ChannelDailyStats {
  channelId: string;
  date: string;
  totalVoices: number;
  totalDuration: number;
  lastActivity?: Date;
}

export interface ChannelMonthlyStats {
  channelId: string;
  month: string;
  totalVoices: number;
  totalDuration: number;
  lastActivity?: Date;
}

export interface ChannelUserStats {
  userId: string;
  userName: string;
  channelId: string;
  totalVoices: number;
  totalDuration: number;
  lastActivity?: Date;
}
