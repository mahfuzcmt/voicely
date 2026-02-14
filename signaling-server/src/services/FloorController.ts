import { RoomManager } from './RoomManager';
import { fcmService } from './FcmService';
import {
  AuthenticatedWebSocket,
  FloorState,
  MessageType,
  FloorGrantedMessage,
  FloorDeniedMessage,
  FloorTakenMessage,
  FloorReleasedMessage,
  FloorTimeoutMessage,
} from '../types';

// Floor holding duration: 2 minutes max
const FLOOR_MAX_DURATION_MS = 2 * 60 * 1000;

export class FloorController {
  private roomManager: RoomManager;

  constructor(roomManager: RoomManager) {
    this.roomManager = roomManager;
  }

  /**
   * Request floor control for speaking
   */
  requestFloor(
    roomId: string,
    ws: AuthenticatedWebSocket
  ): { granted: boolean; response: FloorGrantedMessage | FloorDeniedMessage } {
    const userId = ws.userId!;
    const displayName = ws.displayName || 'Unknown';
    const photoUrl = ws.photoUrl;

    // Check if floor is available
    const currentFloor = this.roomManager.getFloorState(roomId);

    if (currentFloor) {
      // Check if current floor has expired
      if (Date.now() > currentFloor.expiresAt) {
        // Floor expired, release it
        this.releaseFloor(roomId, currentFloor.speakerId);
      } else if (currentFloor.speakerId !== userId) {
        // Floor is held by someone else
        return {
          granted: false,
          response: {
            type: MessageType.FLOOR_DENIED,
            roomId,
            reason: 'Floor is currently held by another user',
            currentSpeaker: {
              userId: currentFloor.speakerId,
              displayName: currentFloor.speakerName,
              photoUrl: currentFloor.speakerPhotoUrl,
              joinedAt: currentFloor.startedAt,
            },
            timestamp: Date.now(),
          },
        };
      } else {
        // User already has floor, extend it
        const expiresAt = Date.now() + FLOOR_MAX_DURATION_MS;
        const newFloorState: FloorState = {
          ...currentFloor,
          expiresAt,
        };
        this.roomManager.setFloorState(roomId, newFloorState);
        this.setupFloorTimeout(roomId, userId, expiresAt);

        return {
          granted: true,
          response: {
            type: MessageType.FLOOR_GRANTED,
            roomId,
            expiresAt,
            timestamp: Date.now(),
          },
        };
      }
    }

    // Grant the floor
    const now = Date.now();
    const expiresAt = now + FLOOR_MAX_DURATION_MS;

    const floorState: FloorState = {
      speakerId: userId,
      speakerName: displayName,
      speakerPhotoUrl: photoUrl,
      startedAt: now,
      expiresAt,
    };

    this.roomManager.setFloorState(roomId, floorState);
    this.setupFloorTimeout(roomId, userId, expiresAt);

    // Notify other room members via WebSocket
    this.broadcastFloorTaken(roomId, floorState, userId);

    // CRITICAL: Send high-priority FCM to wake up sleeping devices
    // This runs async and doesn't block the response
    fcmService.notifyLiveBroadcastStarted({
      channelId: roomId,
      speakerId: userId,
      speakerName: displayName,
    }).catch((err) => {
      console.error('FCM notification failed:', err);
    });

    return {
      granted: true,
      response: {
        type: MessageType.FLOOR_GRANTED,
        roomId,
        expiresAt,
        timestamp: Date.now(),
      },
    };
  }

  /**
   * Release floor control
   */
  releaseFloor(roomId: string, userId: string): boolean {
    const currentFloor = this.roomManager.getFloorState(roomId);

    if (!currentFloor || currentFloor.speakerId !== userId) {
      return false;
    }

    const speakerName = currentFloor.speakerName;

    // Clear the floor
    this.roomManager.setFloorState(roomId, null);
    this.roomManager.clearFloorTimeout(roomId);

    // Notify all room members via WebSocket
    this.broadcastFloorReleased(roomId);

    // Send FCM notification that broadcast ended (lower priority)
    fcmService.notifyLiveBroadcastEnded({
      channelId: roomId,
      speakerId: userId,
      speakerName,
    }).catch((err) => {
      console.error('FCM end notification failed:', err);
    });

    console.log(`Floor released by ${userId} in room ${roomId}`);
    return true;
  }

  /**
   * Force release floor (for disconnections, timeouts)
   */
  forceReleaseFloor(roomId: string): void {
    const currentFloor = this.roomManager.getFloorState(roomId);
    if (currentFloor) {
      this.roomManager.setFloorState(roomId, null);
      this.roomManager.clearFloorTimeout(roomId);
      this.broadcastFloorReleased(roomId);
      console.log(`Floor force-released in room ${roomId}`);
    }
  }

  /**
   * Handle user disconnection - release floor if they held it
   */
  handleUserDisconnect(userId: string, roomIds: string[]): void {
    for (const roomId of roomIds) {
      const currentFloor = this.roomManager.getFloorState(roomId);
      if (currentFloor && currentFloor.speakerId === userId) {
        this.forceReleaseFloor(roomId);
      }
    }
  }

  /**
   * Get current floor state
   */
  getFloorState(roomId: string): FloorState | null {
    return this.roomManager.getFloorState(roomId);
  }

  /**
   * Check if a user currently has the floor
   */
  hasFloor(roomId: string, userId: string): boolean {
    const floor = this.roomManager.getFloorState(roomId);
    return floor?.speakerId === userId && Date.now() <= floor.expiresAt;
  }

  /**
   * Setup automatic floor release timeout
   */
  private setupFloorTimeout(roomId: string, userId: string, expiresAt: number): void {
    const timeUntilExpiry = expiresAt - Date.now();

    const timeout = setTimeout(() => {
      const currentFloor = this.roomManager.getFloorState(roomId);
      if (currentFloor && currentFloor.speakerId === userId) {
        console.log(`Floor timeout for ${userId} in room ${roomId}`);
        this.roomManager.setFloorState(roomId, null);

        // Notify the user their time is up
        const userWs = this.roomManager.getUserSocket(roomId, userId);
        if (userWs) {
          const timeoutMessage: FloorTimeoutMessage = {
            type: MessageType.FLOOR_TIMEOUT,
            roomId,
            timestamp: Date.now(),
          };
          this.sendMessage(userWs, timeoutMessage);
        }

        // Notify all that floor is released
        this.broadcastFloorReleased(roomId);
      }
    }, timeUntilExpiry);

    this.roomManager.setFloorTimeout(roomId, timeout);
  }

  /**
   * Broadcast floor taken message to room members
   */
  private broadcastFloorTaken(roomId: string, floorState: FloorState, excludeUserId: string): void {
    const message: FloorTakenMessage = {
      type: MessageType.FLOOR_TAKEN,
      roomId,
      speaker: {
        userId: floorState.speakerId,
        displayName: floorState.speakerName,
        photoUrl: floorState.speakerPhotoUrl,
        joinedAt: floorState.startedAt,
      },
      expiresAt: floorState.expiresAt,
      timestamp: Date.now(),
    };

    const sockets = this.roomManager.getRoomSockets(roomId, excludeUserId);
    for (const socket of sockets) {
      this.sendMessage(socket, message);
    }
  }

  /**
   * Broadcast floor released message to all room members
   */
  private broadcastFloorReleased(roomId: string): void {
    const message: FloorReleasedMessage = {
      type: MessageType.FLOOR_RELEASED,
      roomId,
      timestamp: Date.now(),
    };

    const sockets = this.roomManager.getRoomSockets(roomId);
    for (const socket of sockets) {
      this.sendMessage(socket, message);
    }
  }

  /**
   * Send a message to a WebSocket
   */
  private sendMessage(ws: AuthenticatedWebSocket, message: object): void {
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify(message));
    }
  }
}
