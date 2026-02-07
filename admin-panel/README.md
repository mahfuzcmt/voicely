# Voicely Admin Panel

Admin panel for managing Voicely PTT app - channels, users, and settings.

## Features

- **Dashboard** - Overview stats (users, channels, messages)
- **Channel Management** - Create, edit, delete channels
- **User Management** - Create, edit, delete users, assign channels
- **Super Admin Authentication** - Secure JWT-based auth

## Tech Stack

- **Next.js 14** - React framework with App Router
- **Firebase** - Firestore database & Auth
- **Tailwind CSS** - Styling
- **TypeScript** - Type safety

## Local Development

1. Install dependencies:
```bash
npm install
```

2. Create `.env.local` file (copy from `.env.local.example`):
```bash
cp .env.local.example .env.local
```

3. Start development server:
```bash
npm run dev
```

4. Initialize super admin by visiting:
```
http://localhost:3000/api/auth/init
```

5. Login with:
- Email: `mahfuzcmt@gmail.com`
- Password: `!Mahfuz20`

## Deployment to Server

### Prerequisites

- Ubuntu 20.04+ server
- Domain pointing to server (app.voicelyent.xyz)
- Root/sudo access

### Quick Deploy

1. Copy the admin-panel folder to your server:
```bash
scp -r admin-panel/ root@103.159.37.167:/tmp/
```

2. SSH into your server:
```bash
ssh root@103.159.37.167
```

3. Run the deployment script:
```bash
cd /tmp/admin-panel
chmod +x deploy.sh
./deploy.sh
```

4. Initialize super admin:
```
https://app.voicelyent.xyz/api/auth/init
```

### Manual Deployment

1. Install Node.js 20:
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

2. Install PM2:
```bash
sudo npm install -g pm2
```

3. Create app directory:
```bash
sudo mkdir -p /var/www/voicely-admin
sudo mkdir -p /var/log/voicely-admin
```

4. Copy files and install:
```bash
cd /var/www/voicely-admin
npm ci
npm run build
```

5. Start with PM2:
```bash
pm2 start ecosystem.config.js
pm2 save
pm2 startup
```

6. Configure Nginx:
```bash
sudo cp nginx.conf /etc/nginx/sites-available/voicely-admin
sudo ln -s /etc/nginx/sites-available/voicely-admin /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

7. Get SSL certificate:
```bash
sudo certbot --nginx -d app.voicelyent.xyz
```

## API Endpoints

### Authentication
- `POST /api/auth/login` - Admin login
- `POST /api/auth/logout` - Admin logout
- `GET /api/auth/init` - Initialize super admin

### Channels
- `GET /api/channels` - List all channels
- `POST /api/channels` - Create channel
- `GET /api/channels/[id]` - Get channel
- `PUT /api/channels/[id]` - Update channel
- `DELETE /api/channels/[id]` - Delete channel

### Users
- `GET /api/users` - List all users
- `POST /api/users` - Create user
- `GET /api/users/[id]` - Get user
- `PUT /api/users/[id]` - Update user
- `DELETE /api/users/[id]` - Delete user
- `GET /api/users/[id]/channels` - Get user's channels
- `PUT /api/users/[id]/channels` - Assign channels to user

## Super Admin Credentials

- **Email:** mahfuzcmt@gmail.com
- **Password:** !Mahfuz20

## Support

For issues, contact the development team or check the logs:
```bash
pm2 logs voicely-admin
```
