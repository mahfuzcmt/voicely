# Voicely - TODO List

## Legend
- [ ] Not started
- [x] Completed
- [~] In progress
- [!] Blocked/Issue

---

## Phase 1: Foundation & Auth

### Project Setup
- [x] Create Flutter project
- [x] Configure pubspec.yaml with dependencies
- [x] Set up project folder structure
- [x] Create .gitignore
- [x] Create PLAN.md documentation

### Theme & UI
- [x] Create color palette (app_colors.dart)
- [x] Create dark theme
- [x] Create light theme
- [x] Set up app constants

### Navigation
- [x] Set up GoRouter
- [x] Configure route guards (auth redirect)
- [x] Create navigation structure

### Authentication
- [x] Create UserModel with freezed
- [x] Create AuthRepository
- [x] Create auth providers (Riverpod)
- [x] Build splash screen
- [x] Build login screen
- [x] Build register screen
- [x] Build profile screen
- [ ] Configure Firebase project
- [ ] Add Firebase Auth to project
- [ ] Test login flow
- [ ] Test registration flow
- [ ] Test password reset
- [ ] Add social login (Google, Apple) - optional

### Android Configuration
- [x] Add audio permissions
- [x] Add location permissions
- [x] Add foreground service permissions
- [x] Add notification permissions
- [ ] Configure signing keys
- [ ] Set up app icon
- [ ] Set up splash screen

---

## Phase 2: Channels

### Data Layer
- [x] Create ChannelModel with freezed
- [x] Create ChannelMember model
- [x] Create ChannelRepository
- [x] Create channel providers

### UI
- [x] Build channels list screen
- [x] Build create channel screen
- [x] Build channel detail screen
- [x] Create channel tile widget

### Features
- [x] Create channel functionality
- [x] Join channel functionality
- [x] Leave channel functionality
- [x] Delete channel functionality
- [ ] Edit channel functionality
- [ ] Channel search
- [ ] Channel invites (private channels)
- [ ] Channel member roles management

---

## Phase 3: PTT Core (Critical Path)

### UI Components
- [x] Create PTT button widget
- [x] PTT button states (idle, transmitting, receiving, waiting)
- [x] Audio visualization animation
- [ ] Speaker indicator UI
- [ ] Active speakers list
- [ ] Floor control indicator

### WebRTC Setup
- [ ] Create WebRTC service class
- [ ] Implement peer connection management
- [ ] Handle ICE candidates
- [ ] Implement SDP offer/answer exchange
- [ ] Audio track management
- [ ] Connection state handling

### Signaling Server (Node.js)
- [ ] Create server project structure
- [ ] Set up WebSocket server
- [ ] Implement room/channel management
- [ ] Implement floor control protocol
- [ ] Handle user presence
- [ ] Relay SDP messages
- [ ] Relay ICE candidates
- [ ] Add authentication (JWT)
- [ ] Deploy to server

### Audio Recording
- [ ] Integrate record package
- [ ] Configure audio settings (48kHz, mono)
- [ ] Handle recording permissions
- [ ] Start/stop recording on PTT
- [ ] Audio level metering

### Audio Playback
- [ ] Integrate just_audio package
- [ ] Play incoming audio streams
- [ ] Handle multiple speakers (queue)
- [ ] Audio ducking for notifications

### Background Service
- [ ] Create Android foreground service
- [ ] Persistent notification
- [ ] Keep WebSocket alive in background
- [ ] Handle app lifecycle
- [ ] iOS background audio configuration

### Floor Control
- [ ] Request floor on PTT press
- [ ] Handle floor granted
- [ ] Handle floor denied
- [ ] Release floor on PTT release
- [ ] Timeout handling
- [ ] Queue management

---

## Phase 4: Text Messaging

### Data Layer
- [x] Create MessageModel with freezed
- [ ] Create MessageRepository
- [ ] Create message providers

### UI
- [ ] Build chat screen
- [ ] Message bubble widget
- [ ] Text input with send button
- [ ] Audio message bubble
- [ ] Location message bubble
- [ ] System message bubble

### Features
- [ ] Send text messages
- [ ] Real-time message sync
- [ ] Message timestamps
- [ ] Read receipts
- [ ] Unread count badges
- [ ] Message pagination
- [ ] Delete message

---

## Phase 5: Location Sharing

### Data Layer
- [ ] Create LocationModel
- [ ] Create LocationRepository
- [ ] Create location providers

### Permissions
- [ ] Request location permission
- [ ] Handle permission denied
- [ ] Background location (optional)

### UI
- [ ] Map view widget
- [ ] Location message bubble
- [ ] Location preview
- [ ] Full screen map

### Features
- [ ] Share current location
- [ ] Live location sharing
- [ ] Location updates interval
- [ ] Stop sharing location

---

## Phase 6: Audio History

### Data Layer
- [ ] Create AudioHistoryModel
- [ ] Create AudioHistoryRepository
- [ ] Create history providers

### Server-side
- [ ] Record PTT audio on server
- [ ] Upload to Firebase Storage
- [ ] Store metadata in Firestore

### UI
- [ ] History list screen
- [ ] Audio player widget
- [ ] Seek bar
- [ ] Playback speed control

### Features
- [ ] List PTT recordings
- [ ] Play recordings
- [ ] Download recordings
- [ ] Delete recordings
- [ ] Filter by date/channel

---

## Phase 7: Push Notifications

### Setup
- [ ] Configure FCM in Firebase
- [ ] Add FCM to Flutter app
- [ ] Handle notification permissions

### Features
- [ ] Channel activity notifications
- [ ] New message notifications
- [ ] PTT activity notifications
- [ ] Notification channels (Android)
- [ ] Notification sounds
- [ ] Badge count

### Background Handling
- [ ] Handle notification tap
- [ ] Background message handler
- [ ] Wake app for PTT

---

## Phase 8: Polish & Optimization

### Performance
- [ ] Optimize audio latency
- [ ] Reduce battery drain
- [ ] Optimize network usage
- [ ] Lazy loading
- [ ] Image caching

### Reliability
- [ ] Network switching (WiFi <-> Mobile)
- [ ] ICE restart on disconnect
- [ ] Automatic reconnection
- [ ] Offline queue
- [ ] Error recovery

### UX
- [ ] Loading states
- [ ] Error states
- [ ] Empty states
- [ ] Pull to refresh
- [ ] Haptic feedback
- [ ] Sound effects

### Testing
- [ ] Unit tests for repositories
- [ ] Unit tests for providers
- [ ] Widget tests for screens
- [ ] Integration tests
- [ ] E2E tests

### Release
- [ ] App icon (all sizes)
- [ ] Splash screen
- [ ] App store screenshots
- [ ] Privacy policy
- [ ] Terms of service
- [ ] Play Store listing
- [ ] App Store listing

---

## Bugs & Issues

| ID | Description | Status | Priority |
|----|-------------|--------|----------|
| - | None yet | - | - |

---

## Technical Debt

| Item | Description | Priority |
|------|-------------|----------|
| TD-1 | Add proper error handling to repositories | Medium |
| TD-2 | Add input validation to forms | Medium |
| TD-3 | Add retry logic for network requests | Low |
| TD-4 | Add analytics/crash reporting | Low |

---

## Ideas / Future Features

- [ ] Voice messages (async, not PTT)
- [ ] Channel groups/folders
- [ ] Custom PTT sounds
- [ ] Bluetooth PTT button support
- [ ] Desktop app (Windows/macOS)
- [ ] Web app
- [ ] Admin dashboard
- [ ] Usage analytics
- [ ] End-to-end encryption
- [ ] Message translation
- [ ] Voice transcription
- [ ] Channel bots

---

## Notes

### Firebase Setup Required
1. Create Firebase project at https://console.firebase.google.com
2. Enable Authentication (Email/Password)
3. Create Firestore database
4. Enable Cloud Storage
5. Enable Cloud Messaging
6. Run `flutterfire configure`

### Signaling Server Deployment Options
- Heroku (free tier available)
- Railway
- Render
- DigitalOcean App Platform
- AWS EC2/ECS
- Google Cloud Run

### Testing Devices Needed
- Android phone (primary)
- iOS device (secondary)
- Multiple devices for PTT testing

---

*Last updated: January 2025*
