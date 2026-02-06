import { RoomManager } from '../services/RoomManager';
import { FloorController } from '../services/FloorController';
import {
  AuthenticatedWebSocket,
  MessageType,
  WebRTCOfferMessage,
  WebRTCAnswerMessage,
  WebRTCIceMessage,
  WebRTCIceBatchMessage,
} from '../types';

/**
 * Handle WebRTC offer - relay to listeners
 * Only the floor holder can send offers
 */
export function handleWebRTCOffer(
  roomManager: RoomManager,
  floorController: FloorController,
  ws: AuthenticatedWebSocket,
  roomId: string,
  sdp: string,
  targetUserId?: string
): void {
  const userId = ws.userId!;

  // Verify user has floor
  if (!floorController.hasFloor(roomId, userId)) {
    sendError(ws, 'Cannot send offer - you do not have the floor');
    return;
  }

  const offerMessage: WebRTCOfferMessage = {
    type: MessageType.WEBRTC_OFFER,
    roomId,
    sdp,
    timestamp: Date.now(),
  };

  if (targetUserId) {
    // Send to specific user
    const targetWs = roomManager.getUserSocket(roomId, targetUserId);
    if (targetWs) {
      // Include sender info for the receiver
      sendMessage(targetWs, {
        ...offerMessage,
        fromUserId: userId,
      });
    }
  } else {
    // Broadcast to all other room members
    const sockets = roomManager.getRoomSockets(roomId, userId);
    for (const socket of sockets) {
      sendMessage(socket, {
        ...offerMessage,
        fromUserId: userId,
      });
    }
  }

  console.log(`WebRTC offer from ${userId} in room ${roomId}`);
}

/**
 * Handle WebRTC answer - relay to speaker
 * Listeners send answers back to the speaker
 */
export function handleWebRTCAnswer(
  roomManager: RoomManager,
  ws: AuthenticatedWebSocket,
  roomId: string,
  targetUserId: string,
  sdp: string
): void {
  const userId = ws.userId!;

  // Find target user's WebSocket
  const targetWs = roomManager.getUserSocket(roomId, targetUserId);
  if (!targetWs) {
    console.log(`Target user ${targetUserId} not found in room ${roomId}`);
    return;
  }

  const answerMessage: WebRTCAnswerMessage = {
    type: MessageType.WEBRTC_ANSWER,
    roomId,
    targetUserId,
    sdp,
    timestamp: Date.now(),
  };

  // Include sender info for the receiver
  sendMessage(targetWs, {
    ...answerMessage,
    fromUserId: userId,
  });

  console.log(`WebRTC answer from ${userId} to ${targetUserId} in room ${roomId}`);
}

/**
 * Handle ICE candidate - relay to peer(s)
 */
export function handleWebRTCIce(
  roomManager: RoomManager,
  ws: AuthenticatedWebSocket,
  roomId: string,
  candidate: string,
  sdpMid: string,
  sdpMLineIndex: number,
  targetUserId?: string
): void {
  const userId = ws.userId!;

  const iceMessage: WebRTCIceMessage = {
    type: MessageType.WEBRTC_ICE,
    roomId,
    candidate,
    sdpMid,
    sdpMLineIndex,
    timestamp: Date.now(),
  };

  if (targetUserId) {
    // Send to specific user
    const targetWs = roomManager.getUserSocket(roomId, targetUserId);
    if (targetWs) {
      sendMessage(targetWs, {
        ...iceMessage,
        fromUserId: userId,
      });
    }
  } else {
    // Broadcast to all other room members
    const sockets = roomManager.getRoomSockets(roomId, userId);
    for (const socket of sockets) {
      sendMessage(socket, {
        ...iceMessage,
        fromUserId: userId,
      });
    }
  }
}

/**
 * Handle batched ICE candidates - more efficient for multiple candidates
 */
export function handleWebRTCIceBatch(
  roomManager: RoomManager,
  ws: AuthenticatedWebSocket,
  roomId: string,
  candidates: Array<{
    candidate: string;
    sdpMid: string;
    sdpMLineIndex: number;
  }>,
  targetUserId?: string
): void {
  const userId = ws.userId!;

  const batchMessage: WebRTCIceBatchMessage = {
    type: MessageType.WEBRTC_ICE_BATCH,
    roomId,
    candidates,
    timestamp: Date.now(),
  };

  if (targetUserId) {
    // Send to specific user
    const targetWs = roomManager.getUserSocket(roomId, targetUserId);
    if (targetWs) {
      sendMessage(targetWs, {
        ...batchMessage,
        fromUserId: userId,
      });
    }
  } else {
    // Broadcast to all other room members
    const sockets = roomManager.getRoomSockets(roomId, userId);
    for (const socket of sockets) {
      sendMessage(socket, {
        ...batchMessage,
        fromUserId: userId,
      });
    }
  }

  console.log(`WebRTC ICE batch (${candidates.length} candidates) from ${userId} in room ${roomId}`);
}

/**
 * Send a message to a WebSocket
 */
function sendMessage(ws: AuthenticatedWebSocket, message: object): void {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(message));
  }
}

/**
 * Send an error message
 */
function sendError(ws: AuthenticatedWebSocket, message: string): void {
  if (ws.readyState === ws.OPEN) {
    ws.send(
      JSON.stringify({
        type: MessageType.ERROR,
        code: 'WEBRTC_ERROR',
        message,
        timestamp: Date.now(),
      })
    );
  }
}
