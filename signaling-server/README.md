# Voicely Signaling Server

WebSocket signaling server for real-time PTT communication in the Voicely app.

## Features

- WebSocket-based signaling for low-latency communication (<50ms)
- Firebase token verification for authentication
- Floor control (who can speak)
- WebRTC offer/answer/ICE candidate relay
- Room/channel management
- Auto-reconnection handling
- Heartbeat for connection monitoring

## Prerequisites

- Node.js 18 or higher
- Firebase project with service account credentials
- Docker (optional, for containerized deployment)

## Setup

### 1. Install Dependencies

```bash
cd signaling-server
npm install
```

### 2. Configure Environment

Copy the example environment file and configure:

```bash
cp .env.example .env
```

Edit `.env` and set:
- `PORT` - Server port (default: 8080)
- `GOOGLE_APPLICATION_CREDENTIALS` - Path to Firebase service account key

### 3. Firebase Service Account

Download your service account key from:
Firebase Console → Project Settings → Service Accounts → Generate new private key

Save it as `service-account.json` in the signaling-server directory.

## Development

```bash
# Start development server with hot reload
npm run dev

# Build TypeScript
npm run build

# Start production server
npm start
```

## Docker

### Build

```bash
docker build -t voicely-signaling .
```

### Run

```bash
docker run -p 8080:8080 \
  -v $(pwd)/service-account.json:/app/service-account.json \
  -e GOOGLE_APPLICATION_CREDENTIALS=/app/service-account.json \
  voicely-signaling
```

## Cloud Run Deployment

### Deploy

```bash
# Build and deploy to Cloud Run
gcloud run deploy voicely-signaling \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --min-instances 1 \
  --set-env-vars="NODE_ENV=production"
```

Note: For Cloud Run, use the default service account which has automatic Firebase access.

### Update Flutter App

After deployment, update the signaling server URL in your Flutter app:

```bash
# Run Flutter with production signaling server
flutter run --dart-define=SIGNALING_SERVER_URL=wss://voicely-signaling-xxxxx.run.app
```

## API

### WebSocket Messages

#### Authentication
```json
{ "type": "auth", "token": "<firebase-id-token>" }
```

#### Room Management
```json
{ "type": "join_room", "roomId": "<channel-id>" }
{ "type": "leave_room", "roomId": "<channel-id>" }
```

#### Floor Control
```json
{ "type": "request_floor", "roomId": "<channel-id>" }
{ "type": "release_floor", "roomId": "<channel-id>" }
```

#### WebRTC Signaling
```json
{ "type": "webrtc_offer", "roomId": "<channel-id>", "sdp": "<sdp-string>" }
{ "type": "webrtc_answer", "roomId": "<channel-id>", "targetUserId": "<user-id>", "sdp": "<sdp-string>" }
{ "type": "webrtc_ice", "roomId": "<channel-id>", "candidate": "...", "sdpMid": "...", "sdpMLineIndex": 0 }
```

### HTTP Endpoints

- `GET /health` - Health check
- `GET /stats` - Server statistics

## Architecture

```
┌─────────────────┐     WebSocket      ┌─────────────────┐
│  Flutter App    │◄──────────────────►│ Signaling Server│
│  (Speaker)      │                    │ (Node.js + ws)  │
└────────┬────────┘                    └────────┬────────┘
         │                                      │
         │ WebRTC Audio Stream                  │ Coordinates
         ▼                                      ▼
┌─────────────────┐                    ┌─────────────────┐
│  Flutter App    │◄───────────────────│ Floor Control   │
│  (Listeners)    │   P2P connection   │ (who can speak) │
└─────────────────┘                    └─────────────────┘
```

## License

Private - Voicely
