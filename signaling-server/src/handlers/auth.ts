import * as admin from 'firebase-admin';
import { AuthenticatedWebSocket, MessageType, AuthSuccessMessage, AuthFailedMessage } from '../types';

// Initialize Firebase Admin if not already initialized
let firebaseInitialized = false;
const isDevelopment = process.env.NODE_ENV !== 'production';
const skipAuth = process.env.SKIP_AUTH === 'true';

export function initializeFirebase(): void {
  if (firebaseInitialized) return;

  // In development mode or skip auth mode without credentials, skip Firebase init
  if ((isDevelopment || skipAuth) && !process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    console.log('⚠️  Auth bypass mode: Firebase auth disabled (no credentials)');
    console.log('   Set GOOGLE_APPLICATION_CREDENTIALS for real auth');
    if (skipAuth) {
      console.log('   SKIP_AUTH=true is set - accepting all tokens');
    }
    firebaseInitialized = true;
    return;
  }

  try {
    // Initialize with application default credentials
    // In Cloud Run, this uses the service account automatically
    // Locally, set GOOGLE_APPLICATION_CREDENTIALS env var
    admin.initializeApp({
      credential: admin.credential.applicationDefault(),
    });
    firebaseInitialized = true;
    console.log('Firebase Admin initialized');
  } catch (error) {
    if (isDevelopment) {
      console.log('⚠️  Development mode: Firebase init failed, auth disabled');
      firebaseInitialized = true;
      return;
    }
    console.error('Failed to initialize Firebase Admin:', error);
    throw error;
  }
}

export interface AuthResult {
  success: boolean;
  userId?: string;
  displayName?: string;
  photoUrl?: string;
  error?: string;
}

/**
 * Verify Firebase ID token and extract user info
 */
export async function verifyToken(token: string): Promise<AuthResult> {
  // Skip auth mode: accept any token and extract user info from it (works even with credentials set)
  // Development mode without credentials: also skip auth
  // Token format for dev: "dev_userId_displayName" or actual Firebase token
  if (skipAuth || (isDevelopment && !process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
    // Check if it's a dev token format
    if (token.startsWith('dev_')) {
      const parts = token.split('_');
      return {
        success: true,
        userId: parts[1] || 'dev-user-' + Date.now(),
        displayName: parts[2] || 'Dev User',
      };
    }

    // Try to decode Firebase token without verification (for testing with real app)
    try {
      // Decode the JWT without verification (development only!)
      const base64Payload = token.split('.')[1];
      if (base64Payload) {
        const payload = JSON.parse(Buffer.from(base64Payload, 'base64').toString());
        return {
          success: true,
          userId: payload.user_id || payload.sub || 'unknown-' + Date.now(),
          displayName: payload.name || payload.email?.split('@')[0] || 'User',
          photoUrl: payload.picture,
        };
      }
    } catch {
      // Fall through to accept anyway in dev mode
    }

    // Accept any token in dev mode
    return {
      success: true,
      userId: 'dev-user-' + Date.now(),
      displayName: 'Dev User',
    };
  }

  try {
    const decodedToken = await admin.auth().verifyIdToken(token);

    return {
      success: true,
      userId: decodedToken.uid,
      displayName: decodedToken.name || decodedToken.email?.split('@')[0] || 'User',
      photoUrl: decodedToken.picture,
    };
  } catch (error) {
    console.error('Token verification failed:', error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Token verification failed',
    };
  }
}

/**
 * Handle authentication message from client
 */
export async function handleAuth(
  ws: AuthenticatedWebSocket,
  token: string,
  clientDisplayName?: string
): Promise<boolean> {
  console.log(`Auth attempt - token length: ${token?.length || 0}, isDev: ${isDevelopment}, skipAuth: ${skipAuth}, hasCredentials: ${!!process.env.GOOGLE_APPLICATION_CREDENTIALS}`);

  const result = await verifyToken(token);
  console.log(`Auth result: success=${result.success}, userId=${result.userId}, error=${result.error}`);

  if (result.success) {
    // Store user info on WebSocket
    // Prioritize client-supplied displayName if provided and non-empty,
    // as the client knows the user's full profile from Firebase Auth
    ws.userId = result.userId;
    ws.displayName = (clientDisplayName && clientDisplayName.trim().length > 0)
      ? clientDisplayName.trim()
      : (result.displayName || 'User');
    ws.photoUrl = result.photoUrl;
    ws.rooms = new Set();

    const successMessage: AuthSuccessMessage = {
      type: MessageType.AUTH_SUCCESS,
      userId: result.userId!,
      displayName: ws.displayName!, // Use the resolved displayName
      timestamp: Date.now(),
    };

    ws.send(JSON.stringify(successMessage));
    console.log(`User authenticated: ${result.userId} (${result.displayName})`);
    return true;
  } else {
    const failedMessage: AuthFailedMessage = {
      type: MessageType.AUTH_FAILED,
      reason: result.error || 'Authentication failed',
      timestamp: Date.now(),
    };

    ws.send(JSON.stringify(failedMessage));
    return false;
  }
}

/**
 * Check if WebSocket is authenticated
 */
export function isAuthenticated(ws: AuthenticatedWebSocket): boolean {
  return !!ws.userId;
}

/**
 * Get user ID from authenticated WebSocket
 */
export function getUserId(ws: AuthenticatedWebSocket): string | undefined {
  return ws.userId;
}
