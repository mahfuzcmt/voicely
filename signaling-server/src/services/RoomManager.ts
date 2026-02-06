import { AuthenticatedWebSocket, Room, RoomMember, FloorState } from '../types';

export class RoomManager {
  private rooms: Map<string, Room> = new Map();

  /**
   * Get or create a room
   */
  getOrCreateRoom(roomId: string): Room {
    let room = this.rooms.get(roomId);
    if (!room) {
      room = {
        id: roomId,
        members: new Map(),
        floorState: null,
      };
      this.rooms.set(roomId, room);
      console.log(`Room created: ${roomId}`);
    }
    return room;
  }

  /**
   * Get a room by ID
   */
  getRoom(roomId: string): Room | undefined {
    return this.rooms.get(roomId);
  }

  /**
   * Add a member to a room
   */
  joinRoom(roomId: string, ws: AuthenticatedWebSocket): RoomMember[] {
    const room = this.getOrCreateRoom(roomId);

    if (!ws.userId) {
      throw new Error('User not authenticated');
    }

    // Remove from previous connection if exists (handles reconnects)
    const existingWs = room.members.get(ws.userId);
    if (existingWs && existingWs !== ws) {
      existingWs.rooms?.delete(roomId);
    }

    room.members.set(ws.userId, ws);

    // Track room membership on the WebSocket
    if (!ws.rooms) {
      ws.rooms = new Set();
    }
    ws.rooms.add(roomId);

    console.log(`User ${ws.userId} joined room ${roomId}. Members: ${room.members.size}`);

    return this.getRoomMembers(roomId);
  }

  /**
   * Remove a member from a room
   */
  leaveRoom(roomId: string, userId: string): boolean {
    const room = this.rooms.get(roomId);
    if (!room) return false;

    const ws = room.members.get(userId);
    if (ws) {
      ws.rooms?.delete(roomId);
    }

    const removed = room.members.delete(userId);

    // Clean up empty rooms
    if (room.members.size === 0) {
      if (room.floorTimeout) {
        clearTimeout(room.floorTimeout);
      }
      this.rooms.delete(roomId);
      console.log(`Room deleted (empty): ${roomId}`);
    }

    console.log(`User ${userId} left room ${roomId}. Members: ${room.members.size}`);

    return removed;
  }

  /**
   * Remove user from all rooms
   */
  removeUserFromAllRooms(userId: string): string[] {
    const leftRooms: string[] = [];

    for (const [roomId, room] of this.rooms) {
      if (room.members.has(userId)) {
        this.leaveRoom(roomId, userId);
        leftRooms.push(roomId);
      }
    }

    return leftRooms;
  }

  /**
   * Get all members in a room
   */
  getRoomMembers(roomId: string): RoomMember[] {
    const room = this.rooms.get(roomId);
    if (!room) return [];

    const members: RoomMember[] = [];
    for (const [userId, ws] of room.members) {
      members.push({
        userId,
        displayName: ws.displayName || 'Unknown',
        photoUrl: ws.photoUrl,
        joinedAt: Date.now(), // Could track actual join time if needed
      });
    }

    return members;
  }

  /**
   * Get WebSocket connections in a room, optionally excluding a user
   */
  getRoomSockets(roomId: string, excludeUserId?: string): AuthenticatedWebSocket[] {
    const room = this.rooms.get(roomId);
    if (!room) return [];

    const sockets: AuthenticatedWebSocket[] = [];
    for (const [userId, ws] of room.members) {
      if (userId !== excludeUserId) {
        sockets.push(ws);
      }
    }

    return sockets;
  }

  /**
   * Get a specific user's WebSocket in a room
   */
  getUserSocket(roomId: string, userId: string): AuthenticatedWebSocket | undefined {
    const room = this.rooms.get(roomId);
    return room?.members.get(userId);
  }

  /**
   * Set floor state for a room
   */
  setFloorState(roomId: string, state: FloorState | null): void {
    const room = this.rooms.get(roomId);
    if (room) {
      room.floorState = state;
    }
  }

  /**
   * Get floor state for a room
   */
  getFloorState(roomId: string): FloorState | null {
    const room = this.rooms.get(roomId);
    return room?.floorState || null;
  }

  /**
   * Set floor timeout for a room
   */
  setFloorTimeout(roomId: string, timeout: NodeJS.Timeout): void {
    const room = this.rooms.get(roomId);
    if (room) {
      if (room.floorTimeout) {
        clearTimeout(room.floorTimeout);
      }
      room.floorTimeout = timeout;
    }
  }

  /**
   * Clear floor timeout for a room
   */
  clearFloorTimeout(roomId: string): void {
    const room = this.rooms.get(roomId);
    if (room?.floorTimeout) {
      clearTimeout(room.floorTimeout);
      room.floorTimeout = undefined;
    }
  }

  /**
   * Check if a user is in a specific room
   */
  isUserInRoom(roomId: string, userId: string): boolean {
    const room = this.rooms.get(roomId);
    return room?.members.has(userId) || false;
  }

  /**
   * Get room count (for monitoring)
   */
  getRoomCount(): number {
    return this.rooms.size;
  }

  /**
   * Get total connection count across all rooms
   */
  getTotalConnections(): number {
    const uniqueUsers = new Set<string>();
    for (const room of this.rooms.values()) {
      for (const userId of room.members.keys()) {
        uniqueUsers.add(userId);
      }
    }
    return uniqueUsers.size;
  }
}
