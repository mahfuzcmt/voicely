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

### 1. Create Application User
```bash
sudo useradd -m -s /bin/bash voicely
sudo mkdir -p /opt/voicely
sudo chown voicely:voicely /opt/voicely
```

### 2. Clone/Upload the Code
```bash
# Option A: Clone from GitHub
sudo -u voicely git clone https://github.com/mahfuzcmt/voicely.git /opt/voicely/app

# Option B: Upload via SCP (from your local machine)
# scp -r signaling-server/ user@your-server:/opt/voicely/signaling-server
```

### 3. Navigate to Signaling Server
```bash
cd /opt/voicely/app/signaling-server
# OR if uploaded separately:
# cd /opt/voicely/signaling-server
```

### 4. Install Dependencies
```bash
sudo -u voicely npm install
```

### 5. Build TypeScript
```bash
sudo -u voicely npm run build
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
scp path/to/service-account.json user@your-server:/opt/voicely/signaling-server/

# Set permissions
sudo chown voicely:voicely /opt/voicely/signaling-server/service-account.json
sudo chmod 600 /opt/voicely/signaling-server/service-account.json
```

### 3. Create Environment File
```bash
sudo -u voicely nano /opt/voicely/signaling-server/.env
```

Add the following:
```env
NODE_ENV=production
PORT=8080
GOOGLE_APPLICATION_CREDENTIALS=/opt/voicely/signaling-server/service-account.json
ALLOWED_ORIGINS=*
WS_HEARTBEAT_INTERVAL=30000
WS_CONNECTION_TIMEOUT=60000
```

---

## PM2 Process Manager Setup

### 1. Create PM2 Ecosystem File
```bash
sudo -u voicely nano /opt/voicely/signaling-server/ecosystem.config.js
```

Add:
```javascript
module.exports = {
  apps: [{
    name: 'voicely-signaling',
    script: 'dist/index.js',
    cwd: '/opt/voicely/signaling-server',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: 8080
    },
    env_file: '/opt/voicely/signaling-server/.env'
  }]
};
```

### 2. Start the Server
```bash
cd /opt/voicely/signaling-server
sudo -u voicely pm2 start ecosystem.config.js
```

### 3. Save PM2 Configuration
```bash
sudo -u voicely pm2 save
```

### 4. Setup PM2 Startup Script
```bash
pm2 startup systemd -u voicely --hp /home/voicely
# Run the command it outputs
```

### 5. Verify Server is Running
```bash
sudo -u voicely pm2 status
curl http://localhost:8080/health
```

---

## Nginx Reverse Proxy with SSL

### 1. Configure Nginx
```bash
sudo nano /etc/nginx/sites-available/voicely-signaling
```

Add (replace `your-domain.com` with your actual domain):
```nginx
upstream voicely_signaling {
    server 127.0.0.1:8080;
}

server {
    listen 80;
    server_name your-domain.com;

    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # SSL certificates (will be added by Certbot)
    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

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
sudo certbot --nginx -d your-domain.com

# Auto-renewal is enabled by default
sudo systemctl status certbot.timer
```

---

## Firewall Configuration

```bash
# Allow SSH, HTTP, HTTPS
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
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
  defaultValue: 'wss://your-domain.com',
);
```

### Option 2: Build with Environment Variable
```bash
flutter build apk --dart-define=SIGNALING_SERVER_URL=wss://your-domain.com
```

---

## Monitoring & Maintenance

### View Logs
```bash
# PM2 logs
sudo -u voicely pm2 logs voicely-signaling

# Real-time logs
sudo -u voicely pm2 logs voicely-signaling --lines 100
```

### Monitor Status
```bash
sudo -u voicely pm2 monit
```

### Restart Server
```bash
sudo -u voicely pm2 restart voicely-signaling
```

### Update Application
```bash
cd /opt/voicely/signaling-server
sudo -u voicely git pull
sudo -u voicely npm install
sudo -u voicely npm run build
sudo -u voicely pm2 restart voicely-signaling
```

---

## Health Check Endpoints

- **Health**: `https://your-domain.com/health`
- **Stats**: `https://your-domain.com/stats`

---

## Troubleshooting

### Check if server is running
```bash
sudo -u voicely pm2 status
curl http://localhost:8080/health
```

### Check logs for errors
```bash
sudo -u voicely pm2 logs voicely-signaling --err --lines 50
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
websocat wss://your-domain.com
```

### Common Issues

1. **Connection refused**: Check if PM2 is running and port 8080 is listening
2. **502 Bad Gateway**: Nginx can't reach the backend - check PM2 status
3. **WebSocket upgrade failed**: Check Nginx proxy settings for WebSocket headers
4. **Auth failed**: Verify Firebase service account key path and permissions

---

## Quick Commands Reference

```bash
# Start server
sudo -u voicely pm2 start ecosystem.config.js

# Stop server
sudo -u voicely pm2 stop voicely-signaling

# Restart server
sudo -u voicely pm2 restart voicely-signaling

# View logs
sudo -u voicely pm2 logs

# Check status
sudo -u voicely pm2 status

# Monitor resources
sudo -u voicely pm2 monit
```
