import * as admin from 'firebase-admin';

/**
 * FCM message types for PTT
 */
export enum FcmMessageType {
  LIVE_BROADCAST_STARTED = 'live_broadcast_started',
  LIVE_BROADCAST_ENDED = 'live_broadcast_ended',
}

/**
 * FCM Service for sending high-priority push notifications
 * to wake up devices when someone starts speaking
 */
export class FcmService {
  private static instance: FcmService;
  private firestore: admin.firestore.Firestore | null = null;
  private messaging: admin.messaging.Messaging | null = null;
  private initialized = false;

  private constructor() {}

  static getInstance(): FcmService {
    if (!FcmService.instance) {
      FcmService.instance = new FcmService();
    }
    return FcmService.instance;
  }

  /**
   * Initialize FCM service (call after Firebase Admin is initialized)
   */
  initialize(): void {
    if (this.initialized) return;

    try {
      // Check if Firebase Admin is initialized
      if (admin.apps.length === 0) {
        console.log('FCM Service: Firebase Admin not initialized, FCM disabled');
        return;
      }

      this.firestore = admin.firestore();
      this.messaging = admin.messaging();
      this.initialized = true;
      console.log('FCM Service: Initialized');
    } catch (error) {
      console.error('FCM Service: Failed to initialize:', error);
    }
  }

  /**
   * Get FCM tokens for channel members from Firestore
   */
  private async getChannelMemberTokens(
    channelId: string,
    excludeUserId: string
  ): Promise<string[]> {
    if (!this.firestore) {
      console.log('FCM Service: Firestore not available');
      return [];
    }

    try {
      // Get channel document to find member IDs
      const channelDoc = await this.firestore
        .collection('channels')
        .doc(channelId)
        .get();

      if (!channelDoc.exists) {
        console.log(`FCM Service: Channel ${channelId} not found`);
        return [];
      }

      const channelData = channelDoc.data();
      const memberIds: string[] = channelData?.memberIds || [];

      // Filter out the speaker
      const otherMemberIds = memberIds.filter((id) => id !== excludeUserId);

      if (otherMemberIds.length === 0) {
        return [];
      }

      // Get FCM tokens for each member
      const tokens: string[] = [];

      // Batch get user documents (Firestore has a limit of 10 per batch)
      const batchSize = 10;
      for (let i = 0; i < otherMemberIds.length; i += batchSize) {
        const batch = otherMemberIds.slice(i, i + batchSize);
        const userDocs = await Promise.all(
          batch.map((userId) =>
            this.firestore!.collection('users').doc(userId).get()
          )
        );

        for (const userDoc of userDocs) {
          if (userDoc.exists) {
            const userData = userDoc.data();
            const token = userData?.fcmToken;
            if (token && typeof token === 'string' && token.length > 0) {
              tokens.push(token);
            }
          }
        }
      }

      console.log(
        `FCM Service: Found ${tokens.length} tokens for ${otherMemberIds.length} members in channel ${channelId}`
      );
      return tokens;
    } catch (error) {
      console.error('FCM Service: Error getting member tokens:', error);
      return [];
    }
  }

  /**
   * Get channel name from Firestore
   */
  private async getChannelName(channelId: string): Promise<string> {
    if (!this.firestore) return 'Channel';

    try {
      const channelDoc = await this.firestore
        .collection('channels')
        .doc(channelId)
        .get();

      if (channelDoc.exists) {
        return channelDoc.data()?.name || 'Channel';
      }
    } catch (error) {
      console.error('FCM Service: Error getting channel name:', error);
    }

    return 'Channel';
  }

  /**
   * Send high-priority FCM notification when someone starts speaking
   * This wakes up Android devices from Doze mode instantly
   */
  async notifyLiveBroadcastStarted(params: {
    channelId: string;
    speakerId: string;
    speakerName: string;
  }): Promise<void> {
    if (!this.messaging || !this.initialized) {
      console.log('FCM Service: Not initialized, skipping notification');
      return;
    }

    const { channelId, speakerId, speakerName } = params;

    console.log(
      `FCM Service: Notifying live broadcast started - Channel: ${channelId}, Speaker: ${speakerName}`
    );

    // Get FCM tokens for channel members
    const tokens = await this.getChannelMemberTokens(channelId, speakerId);

    if (tokens.length === 0) {
      console.log('FCM Service: No tokens to notify');
      return;
    }

    // Get channel name for the notification
    const channelName = await this.getChannelName(channelId);

    // Build the high-priority data message
    // IMPORTANT: This is a DATA-ONLY message (no 'notification' field)
    // Data messages are handled by the app, not the system
    const message: admin.messaging.MulticastMessage = {
      tokens,
      data: {
        type: FcmMessageType.LIVE_BROADCAST_STARTED,
        channelId,
        channelName,
        speakerId,
        speakerName,
        timestamp: Date.now().toString(),
      },
      android: {
        // HIGH PRIORITY: Wakes up device from Doze mode
        priority: 'high',
        // Short TTL: If not delivered in 30 seconds, it's stale
        ttl: 30 * 1000,
      },
      apns: {
        headers: {
          'apns-priority': '10', // High priority for iOS
          'apns-push-type': 'background',
        },
        payload: {
          aps: {
            'content-available': 1, // Silent push for iOS background wake
          },
        },
      },
    };

    try {
      const response = await this.messaging.sendEachForMulticast(message);

      console.log(
        `FCM Service: Sent to ${tokens.length} devices - Success: ${response.successCount}, Failed: ${response.failureCount}`
      );

      // Log and handle failed tokens
      if (response.failureCount > 0) {
        const failedTokens: string[] = [];

        response.responses.forEach((resp, idx) => {
          if (!resp.success) {
            const errorCode = resp.error?.code;
            console.log(
              `FCM Service: Token ${idx} failed - ${errorCode}: ${resp.error?.message}`
            );

            // Mark tokens for removal if they're invalid
            if (
              errorCode === 'messaging/invalid-registration-token' ||
              errorCode === 'messaging/registration-token-not-registered'
            ) {
              failedTokens.push(tokens[idx]);
            }
          }
        });

        // Optionally: Remove invalid tokens from Firestore
        // This could be done asynchronously to not block the response
        if (failedTokens.length > 0) {
          this.removeInvalidTokens(failedTokens).catch((err) =>
            console.error('FCM Service: Error removing invalid tokens:', err)
          );
        }
      }
    } catch (error) {
      console.error('FCM Service: Error sending notification:', error);
    }
  }

  /**
   * Send notification when broadcast ends (optional, lower priority)
   */
  async notifyLiveBroadcastEnded(params: {
    channelId: string;
    speakerId: string;
    speakerName: string;
  }): Promise<void> {
    if (!this.messaging || !this.initialized) {
      return;
    }

    const { channelId, speakerId, speakerName } = params;

    const tokens = await this.getChannelMemberTokens(channelId, speakerId);

    if (tokens.length === 0) {
      return;
    }

    const channelName = await this.getChannelName(channelId);

    const message: admin.messaging.MulticastMessage = {
      tokens,
      data: {
        type: FcmMessageType.LIVE_BROADCAST_ENDED,
        channelId,
        channelName,
        speakerId,
        speakerName,
        timestamp: Date.now().toString(),
      },
      android: {
        // Normal priority for end notification
        priority: 'normal',
      },
    };

    try {
      await this.messaging.sendEachForMulticast(message);
      console.log(`FCM Service: Broadcast ended notification sent for channel ${channelId}`);
    } catch (error) {
      console.error('FCM Service: Error sending end notification:', error);
    }
  }

  /**
   * Remove invalid FCM tokens from Firestore
   */
  private async removeInvalidTokens(tokens: string[]): Promise<void> {
    if (!this.firestore || tokens.length === 0) return;

    try {
      // Find and update users with these invalid tokens
      const usersSnapshot = await this.firestore
        .collection('users')
        .where('fcmToken', 'in', tokens.slice(0, 10)) // Firestore 'in' query limit is 10
        .get();

      const batch = this.firestore.batch();

      usersSnapshot.docs.forEach((doc) => {
        batch.update(doc.ref, {
          fcmToken: admin.firestore.FieldValue.delete(),
          fcmTokenUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      });

      if (!usersSnapshot.empty) {
        await batch.commit();
        console.log(
          `FCM Service: Removed ${usersSnapshot.size} invalid tokens`
        );
      }
    } catch (error) {
      console.error('FCM Service: Error removing invalid tokens:', error);
    }
  }
}

// Export singleton instance
export const fcmService = FcmService.getInstance();
