import { WebSocket } from 'ws';

// WebSocket message types
export enum MessageType {
  // Connection
  AUTH = 'auth',
  AUTH_SUCCESS = 'auth_success',
  AUTH_FAILED = 'auth_failed',
  PING = 'ping',
  PONG = 'pong',

  // Room management
  JOIN_ROOM = 'join_room',
  LEAVE_ROOM = 'leave_room',
  ROOM_JOINED = 'room_joined',
  ROOM_LEFT = 'room_left',
  ROOM_MEMBERS = 'room_members',
  MEMBER_JOINED = 'member_joined',
  MEMBER_LEFT = 'member_left',

  // Floor control
  REQUEST_FLOOR = 'request_floor',
  FLOOR_GRANTED = 'floor_granted',
  FLOOR_DENIED = 'floor_denied',
  RELEASE_FLOOR = 'release_floor',
  FLOOR_RELEASED = 'floor_released',
  FLOOR_TAKEN = 'floor_taken',
  FLOOR_STATE = 'floor_state',
  FLOOR_TIMEOUT = 'floor_timeout',

  // WebRTC signaling
  WEBRTC_OFFER = 'webrtc_offer',
  WEBRTC_ANSWER = 'webrtc_answer',
  WEBRTC_ICE = 'webrtc_ice',
  WEBRTC_ICE_BATCH = 'webrtc_ice_batch',

  // Errors
  ERROR = 'error',
}

// Base message structure
export interface BaseMessage {
  type: MessageType;
  timestamp?: number;
}

// Auth messages
export interface AuthMessage extends BaseMessage {
  type: MessageType.AUTH;
  token: string;
}

export interface AuthSuccessMessage extends BaseMessage {
  type: MessageType.AUTH_SUCCESS;
  userId: string;
  displayName: string;
}

export interface AuthFailedMessage extends BaseMessage {
  type: MessageType.AUTH_FAILED;
  reason: string;
}

// Room messages
export interface JoinRoomMessage extends BaseMessage {
  type: MessageType.JOIN_ROOM;
  roomId: string;
}

export interface LeaveRoomMessage extends BaseMessage {
  type: MessageType.LEAVE_ROOM;
  roomId: string;
}

export interface RoomJoinedMessage extends BaseMessage {
  type: MessageType.ROOM_JOINED;
  roomId: string;
  members: RoomMember[];
  floorState: FloorState | null;
}

export interface RoomMembersMessage extends BaseMessage {
  type: MessageType.ROOM_MEMBERS;
  roomId: string;
  members: RoomMember[];
}

export interface MemberJoinedMessage extends BaseMessage {
  type: MessageType.MEMBER_JOINED;
  roomId: string;
  member: RoomMember;
}

export interface MemberLeftMessage extends BaseMessage {
  type: MessageType.MEMBER_LEFT;
  roomId: string;
  userId: string;
}

// Floor control messages
export interface RequestFloorMessage extends BaseMessage {
  type: MessageType.REQUEST_FLOOR;
  roomId: string;
}

export interface FloorGrantedMessage extends BaseMessage {
  type: MessageType.FLOOR_GRANTED;
  roomId: string;
  expiresAt: number;
}

export interface FloorDeniedMessage extends BaseMessage {
  type: MessageType.FLOOR_DENIED;
  roomId: string;
  reason: string;
  currentSpeaker?: RoomMember;
}

export interface ReleaseFloorMessage extends BaseMessage {
  type: MessageType.RELEASE_FLOOR;
  roomId: string;
}

export interface FloorReleasedMessage extends BaseMessage {
  type: MessageType.FLOOR_RELEASED;
  roomId: string;
}

export interface FloorTakenMessage extends BaseMessage {
  type: MessageType.FLOOR_TAKEN;
  roomId: string;
  speaker: RoomMember;
  expiresAt: number;
}

export interface FloorStateMessage extends BaseMessage {
  type: MessageType.FLOOR_STATE;
  roomId: string;
  state: FloorState | null;
}

export interface FloorTimeoutMessage extends BaseMessage {
  type: MessageType.FLOOR_TIMEOUT;
  roomId: string;
}

// WebRTC signaling messages
export interface WebRTCOfferMessage extends BaseMessage {
  type: MessageType.WEBRTC_OFFER;
  roomId: string;
  targetUserId?: string; // If null, broadcast to all
  sdp: string;
}

export interface WebRTCAnswerMessage extends BaseMessage {
  type: MessageType.WEBRTC_ANSWER;
  roomId: string;
  targetUserId: string;
  sdp: string;
}

export interface WebRTCIceMessage extends BaseMessage {
  type: MessageType.WEBRTC_ICE;
  roomId: string;
  targetUserId?: string; // If null, broadcast to all
  candidate: string;
  sdpMid: string;
  sdpMLineIndex: number;
}

export interface WebRTCIceBatchMessage extends BaseMessage {
  type: MessageType.WEBRTC_ICE_BATCH;
  roomId: string;
  targetUserId?: string;
  candidates: Array<{
    candidate: string;
    sdpMid: string;
    sdpMLineIndex: number;
  }>;
}

// Error message
export interface ErrorMessage extends BaseMessage {
  type: MessageType.ERROR;
  code: string;
  message: string;
}

// Union type for all messages
export type WSMessage =
  | AuthMessage
  | AuthSuccessMessage
  | AuthFailedMessage
  | JoinRoomMessage
  | LeaveRoomMessage
  | RoomJoinedMessage
  | RoomMembersMessage
  | MemberJoinedMessage
  | MemberLeftMessage
  | RequestFloorMessage
  | FloorGrantedMessage
  | FloorDeniedMessage
  | ReleaseFloorMessage
  | FloorReleasedMessage
  | FloorTakenMessage
  | FloorStateMessage
  | FloorTimeoutMessage
  | WebRTCOfferMessage
  | WebRTCAnswerMessage
  | WebRTCIceMessage
  | WebRTCIceBatchMessage
  | ErrorMessage;

// Room member
export interface RoomMember {
  userId: string;
  displayName: string;
  photoUrl?: string;
  joinedAt: number;
}

// Floor state
export interface FloorState {
  speakerId: string;
  speakerName: string;
  speakerPhotoUrl?: string;
  startedAt: number;
  expiresAt: number;
}

// Extended WebSocket with user info
export interface AuthenticatedWebSocket extends WebSocket {
  userId?: string;
  displayName?: string;
  photoUrl?: string;
  isAlive?: boolean;
  rooms?: Set<string>;
}

// Room state
export interface Room {
  id: string;
  members: Map<string, AuthenticatedWebSocket>;
  floorState: FloorState | null;
  floorTimeout?: NodeJS.Timeout;
}
