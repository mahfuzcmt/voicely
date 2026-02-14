import { RoomManager } from '../services/RoomManager';
import { FloorController } from '../services/FloorController';
import {
  AuthenticatedWebSocket,
  MessageType,
  RoomJoinedMessage,
  MemberJoinedMessage,
  MemberLeftMessage,
  RoomMembersMessage,
} from '../types';

// Max connections per room (from env or default)
const MAX_CONNECTIONS_PER_ROOM = parseInt(process.env.MAX_CONNECTIONS_PER_ROOM || '50', 10);

/**
 * Handle user joining a room
 */
export function handleJoinRoom(
  roomManager: RoomManager,
  floorController: FloorController,
  ws: AuthenticatedWebSocket,
  roomId: string
): void {
  const userId = ws.userId!;
  const displayName = ws.displayName || 'Unknown';

  // Check room capacity before joining
  const existingRoom = roomManager.getRoom(roomId);
  if (existingRoom && existingRoom.members.size >= MAX_CONNECTIONS_PER_ROOM) {
    // Room is full
    const errorMessage = {
      type: 'error',
      code: 'ROOM_FULL',
      message: `Room is at capacity (${MAX_CONNECTIONS_PER_ROOM} members)`,
      timestamp: Date.now(),
    };
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify(errorMessage));
    }
    console.log(`User ${userId} rejected from room ${roomId} - room full`);
    return;
  }

  // Add user to room
  const members = roomManager.joinRoom(roomId, ws);

  // Get current floor state
  const floorState = floorController.getFloorState(roomId);

  // Send room joined confirmation to the user
  const joinedMessage: RoomJoinedMessage = {
    type: MessageType.ROOM_JOINED,
    roomId,
    members,
    floorState,
    timestamp: Date.now(),
  };
  // DEBUG: Log exact JSON being sent
  const jsonStr = JSON.stringify(joinedMessage);
  console.log(`ROOM_JOINED JSON being sent to ${userId}:`);
  console.log(jsonStr);
  sendMessage(ws, joinedMessage);

  // Notify other room members about the new member
  const memberJoinedMessage: MemberJoinedMessage = {
    type: MessageType.MEMBER_JOINED,
    roomId,
    member: {
      userId,
      displayName,
      photoUrl: ws.photoUrl,
      joinedAt: Date.now(),
    },
    timestamp: Date.now(),
  };

  const otherSockets = roomManager.getRoomSockets(roomId, userId);
  for (const socket of otherSockets) {
    sendMessage(socket, memberJoinedMessage);
  }

  console.log(`User ${userId} joined room ${roomId}`);
}

/**
 * Handle user leaving a room
 */
export function handleLeaveRoom(
  roomManager: RoomManager,
  floorController: FloorController,
  ws: AuthenticatedWebSocket,
  roomId: string
): void {
  const userId = ws.userId!;

  // Release floor if user had it
  floorController.releaseFloor(roomId, userId);

  // Get other members before removing user
  const otherSockets = roomManager.getRoomSockets(roomId, userId);

  // Remove user from room
  roomManager.leaveRoom(roomId, userId);

  // Notify other room members
  const memberLeftMessage: MemberLeftMessage = {
    type: MessageType.MEMBER_LEFT,
    roomId,
    userId,
    timestamp: Date.now(),
  };

  for (const socket of otherSockets) {
    sendMessage(socket, memberLeftMessage);
  }

  console.log(`User ${userId} left room ${roomId}`);
}

/**
 * Handle user disconnect - remove from all rooms
 */
export function handleDisconnect(
  roomManager: RoomManager,
  floorController: FloorController,
  ws: AuthenticatedWebSocket
): void {
  const userId = ws.userId;
  if (!userId) return;

  const roomIds = ws.rooms ? Array.from(ws.rooms) : [];

  // Handle floor release for all rooms
  floorController.handleUserDisconnect(userId, roomIds);

  // Notify members of each room
  for (const roomId of roomIds) {
    // Get other members before removing user
    const otherSockets = roomManager.getRoomSockets(roomId, userId);

    // Remove from room
    roomManager.leaveRoom(roomId, userId);

    // Notify others
    const memberLeftMessage: MemberLeftMessage = {
      type: MessageType.MEMBER_LEFT,
      roomId,
      userId,
      timestamp: Date.now(),
    };

    for (const socket of otherSockets) {
      sendMessage(socket, memberLeftMessage);
    }
  }

  console.log(`User ${userId} disconnected from ${roomIds.length} rooms`);
}

/**
 * Send current room members to a user
 */
export function sendRoomMembers(
  roomManager: RoomManager,
  ws: AuthenticatedWebSocket,
  roomId: string
): void {
  const members = roomManager.getRoomMembers(roomId);

  const membersMessage: RoomMembersMessage = {
    type: MessageType.ROOM_MEMBERS,
    roomId,
    members,
    timestamp: Date.now(),
  };

  sendMessage(ws, membersMessage);
}

/**
 * Send a message to a WebSocket
 */
function sendMessage(ws: AuthenticatedWebSocket, message: object): void {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(message));
  }
}
