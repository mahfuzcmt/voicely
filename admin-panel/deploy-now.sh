#!/bin/bash

# Quick Deploy Script for Voicely Admin Panel
# Run: bash deploy-now.sh

SERVER_IP="103.159.37.167"
SERVER_USER="root"
SERVER_PASS="6waNDKBrEqfoBOgjWc7K"
APP_DIR="/var/www/voicely-admin"

echo "=========================================="
echo "  Deploying Voicely Admin Panel"
echo "=========================================="

# Check if sshpass is installed
if ! command -v sshpass &> /dev/null; then
    echo "Installing sshpass..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install sshpass 2>/dev/null || brew install hudochenkov/sshpass/sshpass
    else
        apt-get install -y sshpass
    fi
fi

# Build the app
echo "[1/4] Building application..."
npm run build

# Create deployment package
echo "[2/4] Creating deployment package..."
tar -czvf /tmp/admin-panel-deploy.tar.gz \
    --exclude='node_modules' \
    --exclude='.next/cache' \
    --exclude='.git' \
    .

# Upload to server
echo "[3/4] Uploading to server..."
sshpass -p "$SERVER_PASS" scp -o StrictHostKeyChecking=no \
    /tmp/admin-panel-deploy.tar.gz \
    ${SERVER_USER}@${SERVER_IP}:/tmp/

# Deploy on server
echo "[4/4] Deploying on server..."
sshpass -p "$SERVER_PASS" ssh -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} << 'ENDSSH'
    set -e

    APP_DIR="/var/www/voicely-admin"

    # Backup current deployment
    if [ -d "$APP_DIR" ]; then
        echo "Backing up current deployment..."
        cp -r $APP_DIR ${APP_DIR}_backup_$(date +%Y%m%d_%H%M%S)
    fi

    # Extract new deployment
    echo "Extracting new deployment..."
    mkdir -p $APP_DIR
    cd $APP_DIR
    tar -xzvf /tmp/admin-panel-deploy.tar.gz

    # Install dependencies
    echo "Installing dependencies..."
    npm ci --production=false

    # Rebuild if needed (in case of architecture differences)
    echo "Rebuilding..."
    npm run build

    # Restart PM2
    echo "Restarting application..."
    pm2 restart voicely-admin || pm2 start ecosystem.config.js

    # Cleanup
    rm /tmp/admin-panel-deploy.tar.gz

    echo "Deployment complete!"
    pm2 status
ENDSSH

echo ""
echo "=========================================="
echo "  Deployment Complete!"
echo "=========================================="
echo "Visit: https://app.voicelyent.xyz"
