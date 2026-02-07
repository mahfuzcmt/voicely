module.exports = {
  apps: [
    {
      name: 'voicely-admin',
      script: 'npm',
      args: 'start',
      cwd: '/var/www/voicely-admin',
      env: {
        NODE_ENV: 'production',
        PORT: 3001,
      },
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '500M',
      error_file: '/var/log/voicely-admin/error.log',
      out_file: '/var/log/voicely-admin/out.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    },
  ],
};
