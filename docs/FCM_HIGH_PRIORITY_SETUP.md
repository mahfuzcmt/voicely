# High-Priority FCM for Real-Time PTT Wake-Up

This document explains the high-priority FCM data messages implementation that wakes up Android devices instantly when someone starts speaking in a channel.

## Overview

For real-time PTT (Push-to-Talk), the app needs to wake up instantly when someone starts speaking, even if the device is in deep sleep. This is achieved using **high-priority FCM data messages**.

## Key Points

1. **Data-only messages** (no `notification` field) - These are handled by your app code, not the system
2. **High priority** - Wakes up the device from Doze mode
3. **Time-sensitive** - Delivered immediately, not batched

## Implementation Status

✅ **Implemented in this codebase:**

### Server-Side (`signaling-server/`)
- `src/services/FcmService.ts` - FCM service that sends high-priority notifications
- `src/services/FloorController.ts` - Calls FCM when floor is granted/released
- `src/server.ts` - Initializes FCM service on startup

### Client-Side (`lib/`)
- `core/services/fcm_ptt_service.dart` - Handles FCM messages for PTT wake-up
- `features/ptt/presentation/providers/live_ptt_providers.dart` - Auto-connects WebSocket on FCM wake-up
- `main.dart` - Routes FCM messages to PTT service

## Server-Side Code

### FCM Service (`signaling-server/src/services/FcmService.ts`)

```javascript
const admin = require('firebase-admin');

// Initialize Firebase Admin
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

/**
 * Send high-priority FCM when someone starts speaking
 * Call this from your WebSocket server when floor is granted
 */
async function notifyLiveBroadcastStarted({
  channelId,
  channelName,
  speakerId,
  speakerName,
  memberTokens, // Array of FCM tokens for channel members (excluding speaker)
}) {
  if (!memberTokens || memberTokens.length === 0) {
    console.log('No tokens to notify');
    return;
  }

  const message = {
    // DATA-ONLY message (no 'notification' field!)
    data: {
      type: 'live_broadcast_started',
      channelId: channelId,
      channelName: channelName,
      speakerId: speakerId,
      speakerName: speakerName,
      timestamp: Date.now().toString(),
    },
    // HIGH PRIORITY for instant delivery
    android: {
      priority: 'high',
      // TTL of 30 seconds - if not delivered, it's stale
      ttl: 30000,
    },
    apns: {
      headers: {
        'apns-priority': '10', // High priority for iOS
        'apns-push-type': 'background',
      },
      payload: {
        aps: {
          'content-available': 1, // Silent push for iOS
        },
      },
    },
  };

  try {
    // Send to multiple devices
    const response = await admin.messaging().sendEachForMulticast({
      tokens: memberTokens,
      ...message,
    });

    console.log(`FCM sent: ${response.successCount} success, ${response.failureCount} failed`);

    // Handle failed tokens (remove invalid ones from database)
    if (response.failureCount > 0) {
      response.responses.forEach((resp, idx) => {
        if (!resp.success) {
          console.log(`Token failed: ${memberTokens[idx]}, error: ${resp.error?.message}`);
          // TODO: Remove invalid token from database
        }
      });
    }
  } catch (error) {
    console.error('FCM send error:', error);
  }
}

/**
 * Send notification when broadcast ends (optional)
 */
async function notifyLiveBroadcastEnded({
  channelId,
  channelName,
  speakerId,
  speakerName,
  memberTokens,
}) {
  const message = {
    data: {
      type: 'live_broadcast_ended',
      channelId: channelId,
      channelName: channelName,
      speakerId: speakerId,
      speakerName: speakerName,
      timestamp: Date.now().toString(),
    },
    android: {
      priority: 'normal', // Normal priority is fine for end notification
    },
  };

  try {
    await admin.messaging().sendEachForMulticast({
      tokens: memberTokens,
      ...message,
    });
  } catch (error) {
    console.error('FCM send error:', error);
  }
}

module.exports = {
  notifyLiveBroadcastStarted,
  notifyLiveBroadcastEnded,
};
```

### Integration with WebSocket Server

In your WebSocket server, call the FCM function when floor is granted:

```javascript
// When handling floor_granted message
socket.on('floor_granted', async (data) => {
  const { roomId, speakerId, speakerName } = data;

  // Get channel info and member tokens from database
  const channel = await db.getChannel(roomId);
  const memberTokens = await db.getChannelMemberTokens(roomId, speakerId);

  // Notify all other members via high-priority FCM
  await notifyLiveBroadcastStarted({
    channelId: roomId,
    channelName: channel.name,
    speakerId: speakerId,
    speakerName: speakerName,
    memberTokens: memberTokens,
  });

  // Broadcast to WebSocket clients as usual
  io.to(roomId).emit('floor_state', { ... });
});
```

## Android Manifest Requirements

The Flutter app already has these configured, but ensure your AndroidManifest.xml includes:

```xml
<!-- High-priority FCM requires these permissions -->
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

<!-- FCM service -->
<service
    android:name="io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingBackgroundService"
    android:exported="false"
    android:permission="android.permission.BIND_JOB_SERVICE" />
```

## Testing

1. Put the device in Doze mode:
   ```bash
   adb shell dumpsys deviceidle force-idle
   ```

2. Send a test FCM message:
   ```bash
   curl -X POST https://fcm.googleapis.com/v1/projects/YOUR_PROJECT/messages:send \
     -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -d '{
       "message": {
         "token": "DEVICE_FCM_TOKEN",
         "data": {
           "type": "live_broadcast_started",
           "channelId": "test-channel-id",
           "channelName": "Test Channel",
           "speakerId": "speaker-123",
           "speakerName": "John"
         },
         "android": {
           "priority": "high"
         }
       }
     }'
   ```

3. Verify the app wakes up and connects to WebSocket.

## Important Notes

1. **Battery Optimization**: Request users to disable battery optimization for the app. The app already prompts for this.

2. **FCM Quotas**: High-priority messages have stricter quotas. Use them only for time-sensitive notifications.

3. **Token Management**: FCM tokens can expire. Handle `messaging/invalid-registration-token` and `messaging/registration-token-not-registered` errors by removing stale tokens.

4. **iOS Limitations**: iOS doesn't guarantee instant delivery like Android. Consider using VoIP push notifications for iOS.

## Flow Diagram

```
User A presses PTT
        │
        ▼
WebSocket Server grants floor
        │
        ├──────────────────────────────────┐
        ▼                                  ▼
WebSocket broadcast                  FCM high-priority
to connected clients                 to sleeping devices
        │                                  │
        ▼                                  ▼
User B (app open)                    User C (app sleeping)
receives floor_state                 device wakes up
        │                                  │
        ▼                                  ▼
Ready to receive                     App connects WebSocket
audio stream                         joins room, receives audio
```
