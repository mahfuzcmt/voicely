// Voicely signaling server PM2 ecosystem config.
//
// History: previous config pointed at a stale /opt/voicely path that no
// longer matches the running tree. The live process has been running from
// /root/voicely-signaling (verified in pm2 dump). This file is the
// authoritative declarative config for the signaling server.

module.exports = {
  apps: [
    {
      name: 'voicely-signaling',
      script: 'dist/index.js',
      cwd: '/root/voicely-signaling',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '500M',
      env: {
        NODE_ENV: 'production',
        PORT: 8080,

        // Firebase Admin credentials path (preserved from prior runtime env)
        GOOGLE_APPLICATION_CREDENTIALS:
          '/root/voicely-signaling/service-account.json',

        // Force IPv4 first to avoid IPv6 DNS resolution stalls
        NODE_OPTIONS: '--dns-result-order=ipv4first',

        // === Heartbeat tuning (mobile-friendly) ===
        // Was: 15s interval / 3-miss kill = ~45s tolerance, too aggressive
        // for flaky cellular WS connections. Doubling the interval keeps
        // the 3-miss policy in the code but extends tolerance to ~90s,
        // which should eliminate the reconnect storm seen for users on
        // poor networks.
        WS_HEARTBEAT_INTERVAL: 30000,
        WS_CONNECTION_TIMEOUT: 60000,
      },
    },
  ],
};
