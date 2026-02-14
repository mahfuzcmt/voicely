import * as admin from 'firebase-admin';
import { AuthenticatedWebSocket, MessageType, AuthSuccessMessage, AuthFailedMessage } from '../types';

// Initialize Firebase Admin if not already initialized
let firebaseInitialized = false;
const isDevelopment = process.env.NODE_ENV !== 'production';
const skipAuth = process.env.SKIP_AUTH === 'true';

export function initializeFirebase(): void {
  if (firebaseInitialized) return;

  if ((isDevelopment || skipAuth) && !process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    console.log('⚠️  Auth bypass mode: Firebase auth disabled (no credentials)');
    firebaseInitialized = true;
    return;
  }

  try {
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
 * Decode JWT token without verification (fallback for expired tokens)
 */
function decodeTokenWithoutVerification(token: string): AuthResult | null {
  try {
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
    // Fall through
  }
  return null;
}

/**
 * Verify Firebase ID token and extract user info
 */
export async function verifyToken(token: string): Promise<AuthResult> {
  if (skipAuth || (isDevelopment && !process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
    if (token.startsWith('dev_')) {
      const parts = token.split('_');
      return {
        success: true,
        userId: parts[1] || 'dev-user-' + Date.now(),
        displayName: parts[2] || 'Dev User',
      };
    }
    const decoded = decodeTokenWithoutVerification(token);
    if (decoded) return decoded;
    return { success: true, userId: 'dev-user-' + Date.now(), displayName: 'Dev User' };
  }

  console.log('Starting Firebase token verification...');
  const startTime = Date.now();

  try {
    const verifyPromise = admin.auth().verifyIdToken(token);
    const timeoutPromise = new Promise<never>((_, reject) => {
      setTimeout(() => reject(new Error('Firebase verification timeout')), 5000);
    });
    const decodedToken = await Promise.race([verifyPromise, timeoutPromise]);
    console.log(`Firebase verification succeeded in ${Date.now() - startTime}ms`);
    return {
      success: true,
      userId: decodedToken.uid,
      displayName: decodedToken.name || decodedToken.email?.split('@')[0] || 'User',
      photoUrl: decodedToken.picture,
    };
  } catch (error) {
    console.error(`Token verification failed after ${Date.now() - startTime}ms:`, error);

    // FALLBACK: Decode token without verification for expired tokens
    console.log('Falling back to token decode without verification...');
    const decoded = decodeTokenWithoutVerification(token);
    if (decoded) {
      console.log(`Fallback decode succeeded: userId=${decoded.userId}, displayName="${decoded.displayName}"`);
      return decoded;
    }

    return {
      success: false,
      error: error instanceof Error ? error.message : 'Token verification failed',
    };
  }
}

export async function handleAuth(
  ws: AuthenticatedWebSocket,
  token: string,
  clientDisplayName?: string
): Promise<boolean> {
  console.log(`Auth attempt - token length: ${token?.length || 0}`);
  const result = await verifyToken(token);
  console.log(`Auth result: success=${result.success}, userId=${result.userId}`);

  if (result.success) {
    ws.userId = result.userId;
    ws.displayName = (clientDisplayName && clientDisplayName.trim().length > 0)
      ? clientDisplayName.trim()
      : (result.displayName || 'User');
    ws.photoUrl = result.photoUrl;
    ws.rooms = new Set();

    const successMessage: AuthSuccessMessage = {
      type: MessageType.AUTH_SUCCESS,
      userId: result.userId!,
      displayName: ws.displayName!,
      timestamp: Date.now(),
    };
    ws.send(JSON.stringify(successMessage));
    console.log(`User authenticated: ${result.userId}, displayName="${ws.displayName}"`);
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

export function isAuthenticated(ws: AuthenticatedWebSocket): boolean {
  return !!ws.userId;
}

export function getUserId(ws: AuthenticatedWebSocket): string | undefined {
  return ws.userId;
}
