# Voicely Signaling Server - Ubuntu 22.04 Deployment Guide

## Prerequisites

### 1. Update System
```bash
sudo apt update && sudo apt upgrade -y
```

### 2. Install Node.js 18+
```bash
# Add NodeSource repository
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -

# Install Node.js
sudo apt install -y nodejs

# Verify installation
node --version  # Should be v18.x or higher
npm --version
```

### 3. Install PM2 (Process Manager)
```bash
sudo npm install -g pm2
```

### 4. Install Nginx (Reverse Proxy)
```bash
sudo apt install -y nginx
```

---

## Server Setup

### 1. Create Application Directory
```bash
sudo mkdir -p /opt/voicely
```

### 2. Clone/Upload the Code
```bash
# Option A: Clone from GitHub
sudo git clone https://github.com/mahfuzcmt/voicely.git /opt/voicely/app

# Option B: Upload via SCP (from your local machine)
# scp -r signaling-server/ user@your-server:/opt/voicely/app/signaling-server
```

### 3. Navigate to Signaling Server
```bash
cd /opt/voicely/app/signaling-server
```

### 4. Install Dependencies
```bash
sudo npm install
```

### 5. Build TypeScript
```bash
sudo npm run build
```

---

## Firebase Configuration

### 1. Get Service Account Key
1. Go to [Firebase Console](https://console.firebase.google.com)
2. Select your project → Project Settings → Service Accounts
3. Click "Generate new private key"
4. Download the JSON file

### 2. Upload Service Account Key
```bash
# From your local machine
scp path/to/service-account.json user@your-server:/opt/voicely/app/signaling-server/

# Set permissions
sudo chmod 600 /opt/voicely/app/signaling-server/service-account.json
```

### 3. Create Environment File
```bash
sudo nano /opt/voicely/app/signaling-server/.env
```

Add the following:
```env
NODE_ENV=production
PORT=8080
GOOGLE_APPLICATION_CREDENTIALS=/opt/voicely/app/signaling-server/service-account.json
ALLOWED_ORIGINS=*
WS_HEARTBEAT_INTERVAL=30000
WS_CONNECTION_TIMEOUT=60000
```

---

## PM2 Process Manager Setup

### 1. Create PM2 Ecosystem File
```bash
sudo nano /opt/voicely/app/signaling-server/ecosystem.config.js
```

Add:
```javascript
module.exports = {
  apps: [{
    name: 'voicely-signaling',
    script: 'dist/index.js',
    cwd: '/opt/voicely/app/signaling-server',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: 8080
    },
    env_file: '/opt/voicely/app/signaling-server/.env'
  }]
};
```

### 2. Start the Server
```bash
cd /opt/voicely/app/signaling-server
sudo pm2 start ecosystem.config.js
```

### 3. Save PM2 Configuration
```bash
sudo pm2 save
```

### 4. Setup PM2 Startup Script
```bash
pm2 startup systemd
# Run the command it outputs
```

### 5. Verify Server is Running
```bash
sudo pm2 status
curl http://localhost:8080/health
```

---

## Nginx Reverse Proxy with SSL

### 1. Configure Nginx
```bash
sudo nano /etc/nginx/sites-available/voicely-signaling
```

Add (replace `voicelyent.xyz` with your actual domain):
```nginx
upstream voicely_signaling {
    server 127.0.0.1:8080;
}

server {
    listen 80;
    server_name voicelyent.xyz;

    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name voicelyent.xyz;

    # SSL certificates (will be added by Certbot)
    ssl_certificate /etc/letsencrypt/live/voicelyent.xyz/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/voicelyent.xyz/privkey.pem;

    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    # WebSocket support
    location / {
        proxy_pass http://voicely_signaling;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket timeout settings
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

### 2. Enable the Site
```bash
sudo ln -s /etc/nginx/sites-available/voicely-signaling /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 3. Install SSL Certificate (Let's Encrypt)
```bash
# Install Certbot
sudo apt install -y certbot python3-certbot-nginx

# Get SSL certificate
sudo certbot --nginx -d voicelyent.xyz

# Auto-renewal is enabled by default
sudo systemctl status certbot.timer
```

---

## coTURN (TURN/STUN) Server Setup

The Flutter client connects with `iceTransportPolicy: 'relay'` (TURN-only — there is **no** peer-to-peer fallback). This means **all** PTT audio is relayed through this TURN server. If a relay allocation is denied, that user has no media path and their voice silently goes missing. Configure coTURN carefully.

### 1. Install coTURN
```bash
sudo apt install -y coturn
# Enable the service
sudo sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
```

### 2. Configure `/etc/turnserver.conf`
```bash
sudo nano /etc/turnserver.conf
```

Use the following (replace `<SERVER_PUBLIC_IP>` and `voicelyent.xyz` with your values):
```ini
listening-port=3478
tls-listening-port=5349
external-ip=<SERVER_PUBLIC_IP>
listening-ip=0.0.0.0
relay-ip=<SERVER_PUBLIC_IP>
realm=turn.voicelyent.xyz
server-name=turn.voicelyent.xyz
userdb=/var/lib/turn/turndb
lt-cred-mech
relay-threads=4
no-udp-relay=false
no-tcp-relay=false
log-file=/var/log/turnserver.log
verbose
fingerprint
no-multicast-peers
no-cli
no-tlsv1
no-tlsv1_1
min-port=49152
max-port=65535

# REQUIRED: allocation quota.
# 0 = UNLIMITED. Do NOT set a low cap (e.g. 100). Because the app is
# TURN-relay-only, hitting the quota returns "486 Allocation Quota Reached"
# and those users lose audio entirely ("some voices missing"). The real
# ceiling is the relay port range (min-port..max-port ≈ 16k ports), which
# is far larger than any low quota. Leave this at 0 on every new server.
total-quota=0

stale-nonce=600
proc-user=turnserver
proc-group=turnserver
cert=/etc/letsencrypt/live/voicelyent.xyz/fullchain.pem
pkey=/etc/letsencrypt/live/voicelyent.xyz/privkey.pem
allow-loopback-peers
```

### 3. Create the TURN User
Credentials must match `iceServers` in `lib/core/constants/app_constants.dart`:
```bash
sudo turnadmin -a -u voicely -r turn.voicelyent.xyz -p '<TURN_PASSWORD>' -b /var/lib/turn/turndb
```

### 4. Start and Verify
```bash
sudo systemctl enable --now coturn
sudo systemctl status coturn --no-pager

# Confirm it is listening on 3478 (UDP+TCP) and 5349 (TLS)
sudo ss -lnup | grep -E '3478|5349'

# Confirm relays are granted (no "486 Allocation Quota Reached")
sudo journalctl -u coturn --since today | grep '486: Allocation Quota Reached' | wc -l   # expect 0
```

> If you ever change `total-quota`, run `sudo systemctl restart coturn` and re-check the `486` count above.

---

## Firewall Configuration

```bash
# Allow SSH, HTTP, HTTPS
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'

# TURN/STUN signaling + TLS
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp

# TURN relay media port range (must match min-port/max-port in turnserver.conf)
sudo ufw allow 49152:65535/udp
sudo ufw allow 49152:65535/tcp

sudo ufw enable
sudo ufw status
```

---

## Update Flutter App

Update the signaling server URL in your Flutter app:

### Option 1: Update Default in Code
Edit `lib/core/constants/app_constants.dart`:
```dart
static const String signalingServerUrl = String.fromEnvironment(
  'SIGNALING_SERVER_URL',
  defaultValue: 'wss://voicelyent.xyz',
);
```

### Option 2: Build with Environment Variable
```bash
flutter build apk --dart-define=SIGNALING_SERVER_URL=wss://voicelyent.xyz
```

---

## Monitoring & Maintenance

### View Logs
```bash
# PM2 logs
sudo pm2 logs voicely-signaling

# Real-time logs
sudo pm2 logs voicely-signaling --lines 100
```

### Monitor Status
```bash
sudo pm2 monit
```

### Restart Server
```bash
sudo pm2 restart voicely-signaling
```

### Update Application
```bash
cd /opt/voicely/app/signaling-server
sudo git pull
sudo npm install
sudo npm run build
sudo pm2 restart voicely-signaling
```

---

## Health Check Endpoints

- **Health**: `https://voicelyent.xyz/health`
- **Stats**: `https://voicelyent.xyz/stats`

---

## Troubleshooting

### Check if server is running
```bash
sudo pm2 status
curl http://localhost:8080/health
```

### Check logs for errors
```bash
sudo pm2 logs voicely-signaling --err --lines 50
```

### Check Nginx errors
```bash
sudo tail -f /var/log/nginx/error.log
```

### Test WebSocket connection
```bash
# Install websocat
sudo apt install -y websocat

# Test connection
websocat wss://voicelyent.xyz
```

### Common Issues

1. **Connection refused**: Check if PM2 is running and port 8080 is listening
2. **502 Bad Gateway**: Nginx can't reach the backend - check PM2 status
3. **WebSocket upgrade failed**: Check Nginx proxy settings for WebSocket headers
4. **Auth failed**: Verify Firebase service account key path and permissions
5. **"Some voices missing" / users can't be heard intermittently**: The TURN server is denying relay allocations. Check `sudo journalctl -u coturn --since today | grep -c '486: Allocation Quota Reached'` — if non-zero, raise `total-quota` in `/etc/turnserver.conf` (set to `0` for unlimited) and `sudo systemctl restart coturn`. See the coTURN Server Setup section above.

---

## Quick Commands Reference

```bash
# Start server
sudo pm2 start ecosystem.config.js

# Stop server
sudo pm2 stop voicely-signaling

# Restart server
sudo pm2 restart voicely-signaling

# View logs
sudo pm2 logs

# Check status
sudo pm2 status

# Monitor resources
sudo pm2 monit
```
