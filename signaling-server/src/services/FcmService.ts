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
   * Get FCM token recipients for channel members. Returns parallel arrays
   * of userIds and tokens so callers can update per-user state after send.
   */
  private async getChannelMemberRecipients(
    channelId: string,
    excludeUserId: string
  ): Promise<Array<{ userId: string; token: string }>> {
    if (!this.firestore) {
      console.log('FCM Service: Firestore not available');
      return [];
    }

    try {
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
      const otherMemberIds = memberIds.filter((id) => id !== excludeUserId);

      if (otherMemberIds.length === 0) {
        return [];
      }

      const recipients: Array<{ userId: string; token: string }> = [];
      const batchSize = 10;
      for (let i = 0; i < otherMemberIds.length; i += batchSize) {
        const batch = otherMemberIds.slice(i, i + batchSize);
        const userDocs = await Promise.all(
          batch.map((userId) =>
            this.firestore!.collection('users').doc(userId).get()
          )
        );

        userDocs.forEach((userDoc, idx) => {
          if (!userDoc.exists) return;
          const token = userDoc.data()?.fcmToken;
          if (token && typeof token === 'string' && token.length > 0) {
            recipients.push({ userId: batch[idx], token });
          }
        });
      }

      console.log(
        `FCM Service: Found ${recipients.length} tokens for ${otherMemberIds.length} members in channel ${channelId}`
      );
      return recipients;
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

    const recipients = await this.getChannelMemberRecipients(channelId, speakerId);

    if (recipients.length === 0) {
      console.log('FCM Service: No tokens to notify');
      return;
    }

    const tokens = recipients.map((r) => r.token);
    const channelName = await this.getChannelName(channelId);

    // Android: data-only high-priority message so the Flutter background handler
    // fires reliably (the app renders its own notification via
    // _showLiveBroadcastNotification in fcm_ptt_service.dart) and can wake the
    // WebSocket. iOS keeps an alert payload so the system still renders UI.
    const message: admin.messaging.MulticastMessage = {
      tokens,
      data: {
        type: FcmMessageType.LIVE_BROADCAST_STARTED,
        channelId,
        channelName,
        speakerId,
        speakerName,
        title: `${speakerName} is speaking`,
        body: `Tap to listen in ${channelName}`,
        timestamp: Date.now().toString(),
        click_action: 'FLUTTER_NOTIFICATION_CLICK',
      },
      android: {
        priority: 'high',
        // Doze-friendly TTL: give phones up to 5 minutes to wake and deliver
        ttl: 5 * 60 * 1000,
      },
      apns: {
        headers: {
          'apns-priority': '10',
          'apns-push-type': 'alert',
        },
        payload: {
          aps: {
            alert: {
              title: `${speakerName} is speaking`,
              body: `Tap to listen in ${channelName}`,
            },
            sound: 'default',
            badge: 1,
            'content-available': 1,
            'interruption-level': 'time-sensitive',
          },
        },
      },
    };

    try {
      const response = await this.messaging.sendEachForMulticast(message);

      console.log(
        `FCM Service: Sent to ${tokens.length} devices - Success: ${response.successCount}, Failed: ${response.failureCount}`
      );

      // Update per-user failure tracking. Tokens are only deleted after
      // MAX_TOKEN_FAILURES consecutive failures — transient errors no longer
      // permanently invalidate a real device.
      response.responses.forEach((resp, idx) => {
        const userId = recipients[idx].userId;
        if (resp.success) {
          this.resetTokenFailure(userId).catch(() => {});
          return;
        }
        const errorCode = resp.error?.code;
        console.log(
          `FCM Service: Token ${idx} (${userId}) failed - ${errorCode}: ${resp.error?.message}`
        );
        if (
          errorCode === 'messaging/invalid-registration-token' ||
          errorCode === 'messaging/registration-token-not-registered'
        ) {
          this.incrementTokenFailure(userId).catch((err) =>
            console.error('FCM Service: Error tracking token failure:', err)
          );
        }
      });
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

    const recipients = await this.getChannelMemberRecipients(channelId, speakerId);

    if (recipients.length === 0) {
      return;
    }

    const tokens = recipients.map((r) => r.token);
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
   * Threshold for permanently deleting an FCM token. A token must fail this
   * many times in a row before it is removed; transient errors no longer
   * permanently invalidate a real device.
   */
  private static readonly MAX_TOKEN_FAILURES = 3;

  /**
   * Increment the per-user token failure counter. If the counter reaches
   * MAX_TOKEN_FAILURES, the token is deleted.
   */
  private async incrementTokenFailure(userId: string): Promise<void> {
    if (!this.firestore) return;
    const ref = this.firestore.collection('users').doc(userId);
    try {
      await this.firestore.runTransaction(async (tx) => {
        const doc = await tx.get(ref);
        if (!doc.exists) return;
        const data = doc.data() || {};
        if (!data.fcmToken) return; // Already cleaned up
        const next = (data.fcmTokenFailureCount || 0) + 1;
        if (next >= FcmService.MAX_TOKEN_FAILURES) {
          tx.update(ref, {
            fcmToken: admin.firestore.FieldValue.delete(),
            fcmTokenFailureCount: 0,
            fcmTokenUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          console.log(
            `FCM Service: Removed token for ${userId} after ${next} consecutive failures`
          );
        } else {
          tx.update(ref, { fcmTokenFailureCount: next });
        }
      });
    } catch (error) {
      console.error('FCM Service: Error incrementing failure count:', error);
    }
  }

  /**
   * Reset the failure counter after a successful FCM send.
   */
  private async resetTokenFailure(userId: string): Promise<void> {
    if (!this.firestore) return;
    try {
      const ref = this.firestore.collection('users').doc(userId);
      // Only write if the counter is non-zero — saves writes when everything is healthy.
      const snap = await ref.get();
      if (snap.exists && (snap.data()?.fcmTokenFailureCount || 0) > 0) {
        await ref.update({ fcmTokenFailureCount: 0 });
      }
    } catch (error) {
      // Non-fatal
    }
  }
}

// Export singleton instance
export const fcmService = FcmService.getInstance();
