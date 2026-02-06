import { FloorController } from '../services/FloorController';
import {
  AuthenticatedWebSocket,
  MessageType,
  FloorStateMessage,
} from '../types';

/**
 * Handle floor request from a user
 */
export function handleRequestFloor(
  floorController: FloorController,
  ws: AuthenticatedWebSocket,
  roomId: string
): void {
  const { granted, response } = floorController.requestFloor(roomId, ws);

  // Send response to the requester
  sendMessage(ws, response);

  if (granted) {
    console.log(`Floor granted to ${ws.userId} in room ${roomId}`);
  } else {
    console.log(`Floor denied to ${ws.userId} in room ${roomId}`);
  }
}

/**
 * Handle floor release from a user
 */
export function handleReleaseFloor(
  floorController: FloorController,
  ws: AuthenticatedWebSocket,
  roomId: string
): void {
  const userId = ws.userId!;
  const released = floorController.releaseFloor(roomId, userId);

  if (released) {
    console.log(`Floor released by ${userId} in room ${roomId}`);
  } else {
    console.log(`Floor release failed for ${userId} in room ${roomId} (not holding floor)`);
  }
}

/**
 * Send current floor state to a user
 */
export function sendFloorState(
  floorController: FloorController,
  ws: AuthenticatedWebSocket,
  roomId: string
): void {
  const state = floorController.getFloorState(roomId);

  const stateMessage: FloorStateMessage = {
    type: MessageType.FLOOR_STATE,
    roomId,
    state,
    timestamp: Date.now(),
  };

  sendMessage(ws, stateMessage);
}

/**
 * Send a message to a WebSocket
 */
function sendMessage(ws: AuthenticatedWebSocket, message: object): void {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(message));
  }
}
