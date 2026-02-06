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
