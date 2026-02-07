#!/bin/bash

# Voicely Admin Panel Deployment Script
# Run this on your server: bash deploy.sh

set -e

echo "=========================================="
echo "  Voicely Admin Panel Deployment"
echo "=========================================="

# Configuration
APP_DIR="/var/www/voicely-admin"
LOG_DIR="/var/log/voicely-admin"
DOMAIN="app.voicelyent.xyz"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root (sudo bash deploy.sh)"
    exit 1
fi

# Update system
print_status "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install Node.js 20
print_status "Installing Node.js 20..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
node --version

# Install PM2 globally
print_status "Installing PM2..."
npm install -g pm2

# Install Nginx
print_status "Installing Nginx..."
apt-get install -y nginx

# Install Certbot for SSL
print_status "Installing Certbot..."
apt-get install -y certbot python3-certbot-nginx

# Create app directory
print_status "Creating application directory..."
mkdir -p $APP_DIR
mkdir -p $LOG_DIR

# Copy application files (assuming they're in current directory)
if [ -f "package.json" ]; then
    print_status "Copying application files..."
    cp -r ./* $APP_DIR/
    cd $APP_DIR
else
    print_warning "No package.json found in current directory"
    print_warning "Please copy your application files to $APP_DIR manually"
    cd $APP_DIR
fi

# Install dependencies
print_status "Installing dependencies..."
npm ci --production=false

# Build the application
print_status "Building application..."
npm run build

# Setup Nginx
print_status "Configuring Nginx..."
cp nginx.conf /etc/nginx/sites-available/voicely-admin

# Check if site is already enabled
if [ -L "/etc/nginx/sites-enabled/voicely-admin" ]; then
    rm /etc/nginx/sites-enabled/voicely-admin
fi
ln -s /etc/nginx/sites-available/voicely-admin /etc/nginx/sites-enabled/

# Test Nginx configuration
nginx -t

# Get SSL certificate
print_status "Setting up SSL certificate..."
print_warning "Make sure DNS A record for $DOMAIN points to this server's IP"
read -p "Press Enter to continue with SSL setup (or Ctrl+C to skip)..."

# Create temporary HTTP config for certbot
cat > /etc/nginx/sites-available/voicely-admin-temp << 'EOF'
server {
    listen 80;
    server_name app.voicelyent.xyz;

    location / {
        proxy_pass http://127.0.0.1:3001;
    }
}
EOF

ln -sf /etc/nginx/sites-available/voicely-admin-temp /etc/nginx/sites-enabled/voicely-admin
systemctl restart nginx

# Get SSL certificate
certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email mahfuzcmt@gmail.com

# Restore full nginx config
ln -sf /etc/nginx/sites-available/voicely-admin /etc/nginx/sites-enabled/voicely-admin
systemctl restart nginx

# Start application with PM2
print_status "Starting application with PM2..."
cd $APP_DIR
pm2 delete voicely-admin 2>/dev/null || true
pm2 start ecosystem.config.js
pm2 save
pm2 startup

# Setup log rotation
print_status "Setting up log rotation..."
cat > /etc/logrotate.d/voicely-admin << EOF
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data www-data
    sharedscripts
    postrotate
        pm2 reloadLogs
    endscript
}
EOF

# Create .env.local if it doesn't exist
if [ ! -f "$APP_DIR/.env.local" ]; then
    print_warning "Creating .env.local template..."
    cat > $APP_DIR/.env.local << 'EOF'
# Firebase Configuration
NEXT_PUBLIC_FIREBASE_API_KEY=AIzaSyA1KsBNX2HQnkRc4OjW10NDdNrKj-p2se0
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=voicely-1d3b2.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=voicely-1d3b2
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=voicely-1d3b2.firebasestorage.app
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=842514114359
NEXT_PUBLIC_FIREBASE_APP_ID=1:842514114359:android:3b9e29dc1f8589a9db5cb2

# Admin JWT Secret
JWT_SECRET=voicely-admin-jwt-secret-key-2024-change-in-production

# Super Admin Email
SUPER_ADMIN_EMAIL=mahfuzcmt@gmail.com
EOF
    print_warning "Please update .env.local with your actual values"
fi

# Restart application to load env
pm2 restart voicely-admin

echo ""
echo "=========================================="
echo "  Deployment Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Visit https://$DOMAIN/api/auth/init to create the super admin"
echo "2. Login with: mahfuzcmt@gmail.com / !Mahfuz20"
echo ""
echo "Useful commands:"
echo "  pm2 status              - Check app status"
echo "  pm2 logs voicely-admin  - View logs"
echo "  pm2 restart voicely-admin - Restart app"
echo ""
print_status "Admin panel is now available at: https://$DOMAIN"
