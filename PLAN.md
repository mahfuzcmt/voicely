# Voicely - Push-to-Talk App Implementation Plan

## Project Overview

Real-time Push-to-Talk (PTT) communication app similar to Zello, built with Flutter for Android (primary) and iOS platforms. Target scale: ~1000 users.

## Tech Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | Flutter 3.38.8 | Cross-platform mobile app |
| State Management | Riverpod | Reactive state with providers |
| Backend Auth/DB | Firebase | Authentication, Firestore, Storage |
| Real-time Audio | WebRTC (flutter_webrtc) | Peer-to-peer audio streaming |
| Signaling Server | Node.js + WebSocket | WebRTC negotiation & floor control |
| Audio Relay | SFU (mediasoup) | Scalable audio distribution |
| Push Notifications | FCM | Background alerts |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Flutter App                             │
├─────────────────────────────────────────────────────────────┤
│  UI Layer (Screens & Widgets)                               │
│  ├── Auth (Login, Register, Profile)                        │
│  ├── Channels (List, Create, Detail)                        │
│  ├── PTT (Button, Audio Visualization)                      │
│  ├── Messaging (Chat, History)                              │
│  └── Location (Map, Sharing)                                │
├─────────────────────────────────────────────────────────────┤
│  State Layer (Riverpod Providers)                           │
│  ├── AuthNotifier, ChannelNotifier                          │
│  ├── PTTStateNotifier, MessageNotifier                      │
│  └── LocationNotifier                                       │
├─────────────────────────────────────────────────────────────┤
│  Service Layer                                              │
│  ├── WebRTC Service (Peer connections, ICE)                 │
│  ├── Audio Service (Recording, Playback)                    │
│  ├── Signaling Service (WebSocket client)                   │
│  └── Background Service (Foreground notification)           │
├─────────────────────────────────────────────────────────────┤
│  Data Layer (Repositories)                                  │
│  ├── AuthRepository (Firebase Auth)                         │
│  ├── ChannelRepository (Firestore)                          │
│  ├── MessageRepository (Firestore)                          │
│  └── StorageRepository (Firebase Storage)                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Backend Services                          │
├──────────────────────┬──────────────────────────────────────┤
│  Firebase            │  Signaling Server (Node.js)          │
│  ├── Auth            │  ├── WebSocket connections           │
│  ├── Firestore       │  ├── Floor control (who speaks)      │
│  ├── Storage         │  ├── WebRTC signaling (SDP, ICE)     │
│  └── FCM             │  └── Presence management             │
├──────────────────────┼──────────────────────────────────────┤
│                      │  Media Server (mediasoup SFU)        │
│                      │  ├── Audio routing                   │
│                      │  ├── Recording (optional)            │
│                      │  └── Transcoding (optional)          │
└──────────────────────┴──────────────────────────────────────┘
```

## Project Structure

```
lib/
├── main.dart                     # App entry point
├── firebase_options.dart         # Firebase configuration
├── core/
│   ├── constants/
│   │   ├── app_constants.dart    # App-wide constants
│   │   └── firebase_constants.dart
│   ├── theme/
│   │   ├── app_colors.dart       # Color palette
│   │   └── app_theme.dart        # Light/Dark themes
│   ├── router/
│   │   └── app_router.dart       # GoRouter navigation
│   └── utils/
│       ├── logger.dart           # Debug logging
│       └── extensions.dart       # Dart extensions
├── features/
│   ├── auth/
│   │   ├── data/
│   │   │   └── auth_repository.dart
│   │   ├── domain/
│   │   │   └── models/
│   │   │       └── user_model.dart
│   │   └── presentation/
│   │       ├── screens/
│   │       │   ├── splash_screen.dart
│   │       │   ├── login_screen.dart
│   │       │   ├── register_screen.dart
│   │       │   └── profile_screen.dart
│   │       └── widgets/
│   │           └── auth_text_field.dart
│   ├── channels/
│   │   ├── data/
│   │   │   └── channel_repository.dart
│   │   ├── domain/
│   │   │   └── models/
│   │   │       └── channel_model.dart
│   │   └── presentation/
│   │       ├── screens/
│   │       │   ├── channels_screen.dart
│   │       │   ├── channel_detail_screen.dart
│   │       │   └── create_channel_screen.dart
│   │       └── widgets/
│   │           └── channel_tile.dart
│   ├── ptt/
│   │   ├── data/
│   │   │   └── ptt_repository.dart       # TODO
│   │   ├── domain/
│   │   │   └── models/
│   │   │       └── ptt_state.dart        # TODO
│   │   └── presentation/
│   │       ├── screens/
│   │       └── widgets/
│   │           └── ptt_button.dart
│   ├── messaging/
│   │   ├── data/
│   │   │   └── message_repository.dart   # TODO
│   │   ├── domain/
│   │   │   └── models/
│   │   │       └── message_model.dart
│   │   └── presentation/
│   │       ├── screens/
│   │       │   └── chat_screen.dart      # TODO
│   │       └── widgets/
│   ├── location/
│   │   └── ...                           # TODO
│   └── history/
│       └── ...                           # TODO
├── services/
│   ├── audio/
│   │   ├── audio_recorder.dart           # TODO
│   │   └── audio_player.dart             # TODO
│   ├── webrtc/
│   │   ├── webrtc_service.dart           # TODO
│   │   └── signaling_client.dart         # TODO
│   ├── notifications/
│   │   └── fcm_service.dart              # TODO
│   └── background/
│       └── foreground_service.dart       # TODO
└── di/
    └── providers.dart            # Riverpod providers
```

## Implementation Phases

### Phase 1: Foundation & Auth ✅ COMPLETE
- [x] Create Flutter project structure
- [x] Set up dependencies (pubspec.yaml)
- [x] Configure Android permissions
- [x] Implement theme system (dark/light)
- [x] Set up GoRouter navigation
- [x] Create auth screens (login, register, profile)
- [x] Create Firestore models with freezed
- [x] Set up Riverpod providers
- [ ] Configure Firebase project
- [ ] Test auth flow end-to-end

### Phase 2: Channels ✅ COMPLETE
- [x] Channel Firestore model
- [x] Channel repository (CRUD)
- [x] Channels list screen
- [x] Create channel screen
- [x] Channel detail screen
- [x] Join/leave channel logic
- [x] Member management
- [ ] Channel search functionality
- [ ] Channel invites (private channels)

### Phase 3: PTT Core 🔄 IN PROGRESS
- [x] PTT button UI with states
- [ ] WebRTC service setup
- [ ] Signaling server (Node.js)
- [ ] Floor control protocol
- [ ] Audio recording integration
- [ ] Audio streaming to peers
- [ ] Audio playback from peers
- [ ] Android foreground service
- [ ] iOS background audio

### Phase 4: Text Messaging ⏳ PENDING
- [x] Message model
- [ ] Message repository
- [ ] Chat UI screen
- [ ] Real-time message sync
- [ ] Read receipts
- [ ] Unread count badges

### Phase 5: Location Sharing ⏳ PENDING
- [ ] Location model
- [ ] Location permissions
- [ ] Share location message
- [ ] Map view widget
- [ ] Live location updates

### Phase 6: Audio History ⏳ PENDING
- [ ] Server-side recording
- [ ] Upload to Firebase Storage
- [ ] History list UI
- [ ] Audio playback with seek

### Phase 7: Push Notifications ⏳ PENDING
- [ ] FCM setup
- [ ] Channel activity notifications
- [ ] Message notifications
- [ ] Background wake on PTT

### Phase 8: Polish & Optimization ⏳ PENDING
- [ ] Audio latency optimization
- [ ] Battery optimization
- [ ] Network switching (ICE restart)
- [ ] Error handling & recovery
- [ ] Offline support
- [ ] App icon & splash screen

## Firestore Database Schema

```
users/{userId}
├── email: string
├── displayName: string
├── photoUrl: string?
├── status: 'online' | 'away' | 'busy' | 'offline'
├── lastSeen: timestamp
├── createdAt: timestamp
└── updatedAt: timestamp

channels/{channelId}
├── name: string
├── description: string?
├── ownerId: string
├── imageUrl: string?
├── isPrivate: boolean
├── memberCount: number
├── memberIds: string[]
├── createdAt: timestamp
└── updatedAt: timestamp

channels/{channelId}/members/{userId}
├── userId: string
├── channelId: string
├── role: 'owner' | 'admin' | 'member'
├── isMuted: boolean
└── joinedAt: timestamp

channels/{channelId}/messages/{messageId}
├── channelId: string
├── senderId: string
├── senderName: string
├── senderPhotoUrl: string?
├── type: 'text' | 'audio' | 'location' | 'system'
├── content: string?
├── audioUrl: string?
├── audioDuration: number?
├── location: GeoPoint?
├── timestamp: timestamp
└── isRead: boolean

locations/{userId}
├── latitude: number
├── longitude: number
└── timestamp: timestamp

audioHistory/{recordingId}
├── channelId: string
├── senderId: string
├── senderName: string
├── audioUrl: string
├── duration: number
├── timestamp: timestamp
└── participants: string[]
```

## Signaling Server Protocol

### WebSocket Messages

```typescript
// Client -> Server
{ type: 'join', channelId: string, userId: string }
{ type: 'leave', channelId: string }
{ type: 'requestFloor', channelId: string }
{ type: 'releaseFloor', channelId: string }
{ type: 'offer', channelId: string, sdp: RTCSessionDescription }
{ type: 'answer', channelId: string, sdp: RTCSessionDescription }
{ type: 'ice', channelId: string, candidate: RTCIceCandidate }

// Server -> Client
{ type: 'joined', channelId: string, members: User[] }
{ type: 'memberJoined', channelId: string, user: User }
{ type: 'memberLeft', channelId: string, userId: string }
{ type: 'floorGranted', channelId: string, userId: string }
{ type: 'floorDenied', channelId: string, reason: string }
{ type: 'floorReleased', channelId: string }
{ type: 'offer', channelId: string, fromUserId: string, sdp: RTCSessionDescription }
{ type: 'answer', channelId: string, fromUserId: string, sdp: RTCSessionDescription }
{ type: 'ice', channelId: string, fromUserId: string, candidate: RTCIceCandidate }
```

## Key Dependencies

```yaml
dependencies:
  # State Management
  flutter_riverpod: ^2.6.1

  # Firebase
  firebase_core: ^3.12.1
  firebase_auth: ^5.5.2
  cloud_firestore: ^5.6.6
  firebase_storage: ^12.4.4
  firebase_messaging: ^15.2.4

  # WebRTC & Audio
  flutter_webrtc: ^0.12.8
  record: ^5.2.1
  just_audio: ^0.9.46

  # Location
  geolocator: ^14.0.0
  google_maps_flutter: ^2.12.1

  # Navigation
  go_router: ^15.1.2

  # Code Generation
  freezed_annotation: ^3.0.0
  json_annotation: ^4.9.0
```

## Android Permissions

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

## Setup Instructions

### 1. Prerequisites
- Flutter SDK 3.38.8+
- Android Studio with Android SDK
- Node.js 18+ (for signaling server)
- Firebase CLI

### 2. Firebase Setup
```bash
npm install -g firebase-tools
firebase login
dart pub global activate flutterfire_cli
flutterfire configure
```

### 3. Run the App
```bash
cd C:\xampp\htdocs\Voicely
flutter pub get
flutter run
```

### 4. Signaling Server (TODO)
```bash
cd server/
npm install
npm start
```

## Testing Strategy

### Unit Tests
- Repository tests with mock Firestore
- Provider tests with mock repositories
- Model serialization tests

### Integration Tests
- Auth flow (register -> login -> logout)
- Channel flow (create -> join -> leave)
- PTT flow (request floor -> transmit -> release)

### E2E Tests
- Full user journey with Playwright/Patrol
- Multi-device PTT testing

## Performance Targets

| Metric | Target |
|--------|--------|
| PTT latency | < 200ms |
| Audio quality | 48kHz mono |
| Battery drain | < 5%/hour active |
| App cold start | < 2 seconds |
| Channel join | < 1 second |

## Security Considerations

- Firebase Security Rules for Firestore/Storage
- JWT authentication for signaling server
- End-to-end encryption for audio (SRTP via WebRTC)
- Rate limiting on floor requests
- Input validation on all user data

## Resources

- [Flutter WebRTC](https://pub.dev/packages/flutter_webrtc)
- [Firebase Flutter](https://firebase.google.com/docs/flutter/setup)
- [Riverpod Documentation](https://riverpod.dev/)
- [WebRTC Samples](https://webrtc.github.io/samples/)
- [mediasoup SFU](https://mediasoup.org/)
