import express, { Express, Request, Response } from 'express';
import cors from 'cors';
import { WebSocketServer, WebSocket } from 'ws';
import http from 'http';
import { RoomManager } from './services/RoomManager';
import { FloorController } from './services/FloorController';
import { initializeFirebase, handleAuth, isAuthenticated } from './handlers/auth';
import { handleJoinRoom, handleLeaveRoom, handleDisconnect } from './handlers/room';
import { handleRequestFloor, handleReleaseFloor } from './handlers/floor';
import {
  handleWebRTCOffer,
  handleWebRTCAnswer,
  handleWebRTCIce,
  handleWebRTCIceBatch,
} from './handlers/webrtc';
import { AuthenticatedWebSocket, MessageType, ErrorMessage } from './types';

// Configuration
const PORT = parseInt(process.env.PORT || '8080', 10);
const HEARTBEAT_INTERVAL = parseInt(process.env.WS_HEARTBEAT_INTERVAL || '15000', 10); // Reduced from 30s for faster dead connection detection
const CONNECTION_TIMEOUT = parseInt(process.env.WS_CONNECTION_TIMEOUT || '30000', 10); // Reduced from 60s
const MAX_CONNECTIONS_PER_ROOM = parseInt(process.env.MAX_CONNECTIONS_PER_ROOM || '50', 10);
const MAX_TOTAL_CONNECTIONS = parseInt(process.env.MAX_TOTAL_CONNECTIONS || '500', 10);
const MESSAGE_RATE_LIMIT = parseInt(process.env.MESSAGE_RATE_LIMIT || '100', 10); // messages per second
const MESSAGE_RATE_WINDOW = 1000; // 1 second window

// Services
const roomManager = new RoomManager();
const floorController = new FloorController(roomManager);

// Express app
const app: Express = express();

// Middleware
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS === '*' ? '*' : process.env.ALLOWED_ORIGINS?.split(','),
}));
app.use(express.json());

// Health check endpoint
app.get('/health', (_req: Request, res: Response) => {
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    rooms: roomManager.getRoomCount(),
    connections: roomManager.getTotalConnections(),
  });
});

// Stats endpoint
app.get('/stats', (_req: Request, res: Response) => {
  res.json({
    rooms: roomManager.getRoomCount(),
    connections: roomManager.getTotalConnections(),
    uptime: process.uptime(),
    memory: process.memoryUsage(),
  });
});

// Debug endpoint to check auth configuration
app.get('/debug', (_req: Request, res: Response) => {
  res.json({
    nodeEnv: process.env.NODE_ENV || 'not set',
    hasFirebaseCredentials: !!process.env.GOOGLE_APPLICATION_CREDENTIALS,
    credentialsPath: process.env.GOOGLE_APPLICATION_CREDENTIALS ? '[set]' : '[not set]',
    skipAuth: process.env.SKIP_AUTH === 'true',
    port: PORT,
  });
});

// Create HTTP server
const server = http.createServer(app);

// Create WebSocket server
const wss = new WebSocketServer({ server });

// Heartbeat to detect dead connections
function heartbeat(ws: AuthenticatedWebSocket): void {
  ws.isAlive = true;
}

// Track consecutive missed heartbeats for graceful degradation
const missedHeartbeats = new WeakMap<WebSocket, number>();

// Ping all connections periodically
const pingInterval = setInterval(() => {
  wss.clients.forEach((ws) => {
    const authWs = ws as AuthenticatedWebSocket;
    const missed = missedHeartbeats.get(ws) || 0;

    if (authWs.isAlive === false) {
      // Increment missed heartbeat counter
      missedHeartbeats.set(ws, missed + 1);

      // Allow 2 missed heartbeats before terminating (handles brief network glitches)
      if (missed >= 2) {
        console.log(`Terminating dead connection: ${authWs.userId} (missed ${missed + 1} heartbeats)`);
        handleDisconnect(roomManager, floorController, authWs);
        missedHeartbeats.delete(ws);
        return ws.terminate();
      } else {
        console.log(`Warning: ${authWs.userId} missed heartbeat (${missed + 1}/3)`);
      }
    } else {
      // Reset counter on successful pong
      missedHeartbeats.set(ws, 0);
    }

    authWs.isAlive = false;
    ws.ping();
  });
}, HEARTBEAT_INTERVAL);

wss.on('close', () => {
  clearInterval(pingInterval);
});

// Rate limiter state per connection
interface RateLimiterState {
  messageCount: number;
  windowStart: number;
}
const rateLimiters = new WeakMap<WebSocket, RateLimiterState>();

/**
 * Check if a message should be rate limited
 */
function checkRateLimit(ws: WebSocket): boolean {
  const now = Date.now();
  let state = rateLimiters.get(ws);

  if (!state) {
    state = { messageCount: 0, windowStart: now };
    rateLimiters.set(ws, state);
  }

  // Reset window if expired
  if (now - state.windowStart >= MESSAGE_RATE_WINDOW) {
    state.messageCount = 0;
    state.windowStart = now;
  }

  state.messageCount++;
  return state.messageCount > MESSAGE_RATE_LIMIT;
}

// Handle new WebSocket connections
wss.on('connection', (ws: WebSocket) => {
  // Check total connection limit
  if (wss.clients.size > MAX_TOTAL_CONNECTIONS) {
    console.log(`Connection rejected: max total connections (${MAX_TOTAL_CONNECTIONS}) reached`);
    ws.close(4003, 'Server at capacity');
    return;
  }

  const authWs = ws as AuthenticatedWebSocket;
  authWs.isAlive = true;
  authWs.messageCount = 0;
  authWs.lastMessageTime = Date.now();

  console.log(`New WebSocket connection (total: ${wss.clients.size})`);

  // Set connection timeout for authentication
  const authTimeout = setTimeout(() => {
    if (!isAuthenticated(authWs)) {
      console.log('Connection timed out waiting for auth');
      ws.close(4001, 'Authentication timeout');
    }
  }, CONNECTION_TIMEOUT);

  // Handle pong (heartbeat response)
  ws.on('pong', () => heartbeat(authWs));

  // Handle incoming messages
  ws.on('message', async (data: Buffer) => {
    // Rate limiting check
    if (checkRateLimit(ws)) {
      sendError(authWs, 'RATE_LIMITED', 'Too many messages, please slow down');
      return;
    }

    let message;
    try {
      message = JSON.parse(data.toString());
    } catch {
      sendError(authWs, 'PARSE_ERROR', 'Invalid JSON message');
      return;
    }

    // Handle authentication (must be first message)
    if (message.type === MessageType.AUTH) {
      const success = await handleAuth(authWs, message.token, message.displayName);
      if (success) {
        clearTimeout(authTimeout);
      } else {
        // Close connection after failed auth
        setTimeout(() => ws.close(4002, 'Authentication failed'), 100);
      }
      return;
    }

    // All other messages require authentication
    if (!isAuthenticated(authWs)) {
      sendError(authWs, 'NOT_AUTHENTICATED', 'Please authenticate first');
      return;
    }

    // Handle ping/pong manually if client sends ping message
    if (message.type === MessageType.PING) {
      ws.send(JSON.stringify({ type: MessageType.PONG, timestamp: Date.now() }));
      return;
    }

    // Route message to appropriate handler
    try {
      switch (message.type) {
        // Room management
        case MessageType.JOIN_ROOM:
          handleJoinRoom(roomManager, floorController, authWs, message.roomId);
          break;

        case MessageType.LEAVE_ROOM:
          handleLeaveRoom(roomManager, floorController, authWs, message.roomId);
          break;

        // Floor control
        case MessageType.REQUEST_FLOOR:
          handleRequestFloor(floorController, authWs, message.roomId);
          break;

        case MessageType.RELEASE_FLOOR:
          handleReleaseFloor(floorController, authWs, message.roomId);
          break;

        // WebRTC signaling
        case MessageType.WEBRTC_OFFER:
          handleWebRTCOffer(
            roomManager,
            floorController,
            authWs,
            message.roomId,
            message.sdp,
            message.targetUserId
          );
          break;

        case MessageType.WEBRTC_ANSWER:
          handleWebRTCAnswer(
            roomManager,
            authWs,
            message.roomId,
            message.targetUserId,
            message.sdp
          );
          break;

        case MessageType.WEBRTC_ICE:
          handleWebRTCIce(
            roomManager,
            authWs,
            message.roomId,
            message.candidate,
            message.sdpMid,
            message.sdpMLineIndex,
            message.targetUserId
          );
          break;

        case MessageType.WEBRTC_ICE_BATCH:
          handleWebRTCIceBatch(
            roomManager,
            authWs,
            message.roomId,
            message.candidates,
            message.targetUserId
          );
          break;

        default:
          sendError(authWs, 'UNKNOWN_MESSAGE', `Unknown message type: ${message.type}`);
      }
    } catch (error) {
      console.error('Error handling message:', error);
      sendError(
        authWs,
        'HANDLER_ERROR',
        error instanceof Error ? error.message : 'Internal error'
      );
    }
  });

  // Handle connection close
  ws.on('close', (code, reason) => {
    clearTimeout(authTimeout);
    console.log(`Connection closed: ${authWs.userId} (code: ${code}, reason: ${reason})`);
    handleDisconnect(roomManager, floorController, authWs);
  });

  // Handle errors
  ws.on('error', (error) => {
    console.error(`WebSocket error for ${authWs.userId}:`, error);
    handleDisconnect(roomManager, floorController, authWs);
  });
});

/**
 * Send error message to client
 */
function sendError(ws: AuthenticatedWebSocket, code: string, message: string): void {
  const errorMessage: ErrorMessage = {
    type: MessageType.ERROR,
    code,
    message,
    timestamp: Date.now(),
  };
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(errorMessage));
  }
}

/**
 * Start the server
 */
export function startServer(): void {
  // Initialize Firebase
  initializeFirebase();

  server.listen(PORT, () => {
    console.log(`Signaling server running on port ${PORT}`);
    console.log(`Health check: http://localhost:${PORT}/health`);
    console.log(`WebSocket endpoint: ws://localhost:${PORT}`);
  });
}

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down...');
  wss.close(() => {
    server.close(() => {
      console.log('Server closed');
      process.exit(0);
    });
  });
});
