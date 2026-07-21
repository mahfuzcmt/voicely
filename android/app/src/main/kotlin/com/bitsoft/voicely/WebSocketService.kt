package com.bitsoft.voicely

import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import okhttp3.*
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Native Android foreground service that maintains WebSocket connection
 * even when the Flutter app is backgrounded/suspended.
 *
 * This service runs independently of the Flutter isolate and keeps
 * the connection alive for receiving real-time messages.
 *
 * Designed to stay connected indefinitely (hours/days) until explicitly stopped.
 */
class WebSocketService : Service() {

    companion object {
        private const val TAG = "WebSocketService"
        private const val NOTIFICATION_ID = 9999
        private const val CHANNEL_ID = "voicely_websocket_channel"

        // WebSocket configuration
        private const val PING_INTERVAL_SECONDS = 15L
        private const val RECONNECT_DELAY_MS = 3000L
        private const val MAX_RECONNECT_ATTEMPTS = Int.MAX_VALUE // Never stop trying

        // Wake lock renewal interval (renew every 10 minutes to stay alive indefinitely)
        private const val WAKELOCK_RENEWAL_INTERVAL_MS = 10 * 60 * 1000L

        // Service state
        @Volatile
        private var isRunning = false

        @Volatile
        private var serverUrl: String? = null

        @Volatile
        private var authToken: String? = null

        @Volatile
        private var displayName: String? = null

        @Volatile
        private var currentRoomId: String? = null

        // Connection state callback
        var onConnectionStateChanged: ((Boolean) -> Unit)? = null
        var onMessageReceived: ((String) -> Unit)? = null

        fun isServiceRunning() = isRunning

        fun startService(context: Context, serverUrl: String, authToken: String, displayName: String?, roomId: String?) {
            this.serverUrl = serverUrl
            this.authToken = authToken
            this.displayName = displayName
            this.currentRoomId = roomId

            // Save state for boot recovery
            BootReceiver.saveServiceState(context, true, serverUrl, authToken, displayName, roomId)

            val intent = Intent(context, WebSocketService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopService(context: Context) {
            // Clear saved state
            BootReceiver.clearServiceState(context)

            context.stopService(Intent(context, WebSocketService::class.java))
        }

        fun updateCredentials(authToken: String, displayName: String?) {
            this.authToken = authToken
            this.displayName = displayName
        }

        fun joinRoom(roomId: String) {
            this.currentRoomId = roomId
            instance?.sendJoinRoom(roomId)
        }

        fun leaveRoom(roomId: String) {
            instance?.sendLeaveRoom(roomId)
            if (currentRoomId == roomId) {
                currentRoomId = null
            }
        }

        fun sendMessage(message: String) {
            instance?.send(message)
        }

        private var instance: WebSocketService? = null
    }

    private var webSocket: WebSocket? = null
    private var okHttpClient: OkHttpClient? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var reconnectAttempts = 0
    private var isConnected = false
    private var isAuthenticated = false
    private var pttReceiverRegistered = false

    // Track PTT state from service broadcasts
    @Volatile
    private var isPttPressedFromService = false

    // Dynamic PTT broadcast receiver for screen wake and PTT trigger
    private val pttBroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Log.d(TAG, "PTT broadcast received in service: ${intent.action}")
            when (intent.action) {
                "android.intent.action.PTT.down",
                "com.myt.action.PTT_DOWN",
                "com.freeme.action.PTT_DOWN" -> {
                    if (!isPttPressedFromService) {
                        isPttPressedFromService = true
                        Log.d(TAG, "PTT DOWN - waking screen and starting PTT")
                        wakeScreenAndStartPtt()
                    }
                }
                "android.intent.action.PTT.up",
                "com.myt.action.PTT_UP",
                "com.freeme.action.PTT_UP" -> {
                    if (isPttPressedFromService) {
                        isPttPressedFromService = false
                        Log.d(TAG, "PTT UP - stopping PTT")
                        sendPttUpToApp()
                    }
                }
            }
        }
    }

    /**
     * Wake the screen and launch the app with PTT start flag.
     * This is called when PTT button is pressed while screen is off.
     */
    private fun wakeScreenAndStartPtt() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val isScreenOn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
                powerManager.isInteractive
            } else {
                @Suppress("DEPRECATION")
                powerManager.isScreenOn
            }

            Log.d(TAG, "wakeScreenAndStartPtt: isScreenOn=$isScreenOn")

            // Acquire wake lock to turn on screen
            @Suppress("DEPRECATION")
            val screenWakeLock = powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "Voicely::ServiceScreenWakeLock"
            )
            screenWakeLock.acquire(10000L)
            Log.d(TAG, "Screen wake lock acquired from service")

            // Launch app with PTT_START flag
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                if (launchIntent != null) {
                    launchIntent.addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )
                    // Add extra to tell MainActivity to start PTT
                    launchIntent.putExtra("PTT_START", true)
                    launchIntent.putExtra("PTT_TIMESTAMP", System.currentTimeMillis())
                    startActivity(launchIntent)
                    Log.d(TAG, "App launched from service with PTT_START=true")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to launch app: ${e.message}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "wakeScreenAndStartPtt error: ${e.message}", e)
        }
    }

    /**
     * Send PTT UP event to the app when button is released.
     * This handles the case where PTT was started from service when screen was off.
     */
    private fun sendPttUpToApp() {
        try {
            // Send broadcast that MainActivity can receive
            val intent = Intent("com.bitsoft.voicely.PTT_UP_FROM_SERVICE")
            intent.setPackage(packageName)
            sendBroadcast(intent)
            Log.d(TAG, "Sent PTT_UP_FROM_SERVICE broadcast")
        } catch (e: Exception) {
            Log.e(TAG, "sendPttUpToApp error: ${e.message}", e)
        }
    }

    private fun registerPttReceiver() {
        if (pttReceiverRegistered) return
        try {
            val filter = IntentFilter().apply {
                addAction("android.intent.action.PTT.down")
                addAction("android.intent.action.PTT.up")
                addAction("android.intent.action.PTT.longpress")
                addAction("com.myt.action.PTT_DOWN")
                addAction("com.myt.action.PTT_UP")
                addAction("com.freeme.action.PTT_DOWN")
                addAction("com.freeme.action.PTT_UP")
                priority = IntentFilter.SYSTEM_HIGH_PRIORITY
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(pttBroadcastReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(pttBroadcastReceiver, filter)
            }
            pttReceiverRegistered = true
            Log.d(TAG, "PTT broadcast receiver registered in service")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register PTT receiver: ${e.message}")
        }
    }

    private fun unregisterPttReceiver() {
        if (!pttReceiverRegistered) return
        try {
            unregisterReceiver(pttBroadcastReceiver)
            pttReceiverRegistered = false
            Log.d(TAG, "PTT broadcast receiver unregistered")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to unregister PTT receiver: ${e.message}")
        }
    }

    private val reconnectRunnable = Runnable { connect() }
    private val handler = Handler(Looper.getMainLooper())

    // Wake lock renewal handler - keeps running indefinitely
    private val wakeLockRenewalRunnable = object : Runnable {
        override fun run() {
            renewWakeLock()
            handler.postDelayed(this, WAKELOCK_RENEWAL_INTERVAL_MS)
        }
    }

    // Heartbeat to check connection health
    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (isConnected && isAuthenticated) {
                sendPing()
            } else if (!isConnected && serverUrl != null && authToken != null) {
                // Not connected but should be - trigger reconnect
                Log.d(TAG, "Heartbeat: Not connected, triggering reconnect")
                scheduleReconnect()
            }
            handler.postDelayed(this, 30_000) // Check every 30 seconds
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        isRunning = true
        Log.d(TAG, "WebSocketService created")

        createNotificationChannel()
        acquireWakeLock()

        // Register PTT broadcast receiver for screen wake
        registerPttReceiver()

        // Start wake lock renewal (runs every 10 minutes to keep alive indefinitely)
        handler.postDelayed(wakeLockRenewalRunnable, WAKELOCK_RENEWAL_INTERVAL_MS)

        // Start heartbeat checker (ensures connection stays alive)
        handler.postDelayed(heartbeatRunnable, 30_000)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "WebSocketService onStartCommand")

        // Start as foreground service
        startForeground(NOTIFICATION_ID, createNotification("Connecting..."))

        // Initialize OkHttp client with aggressive keep-alive settings
        if (okHttpClient == null) {
            okHttpClient = OkHttpClient.Builder()
                .pingInterval(PING_INTERVAL_SECONDS, TimeUnit.SECONDS)
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MINUTES) // No read timeout for WebSocket
                .writeTimeout(30, TimeUnit.SECONDS)
                .retryOnConnectionFailure(true)
                // Keep connections alive
                .connectionPool(ConnectionPool(1, 5, TimeUnit.MINUTES))
                .build()
        }

        // Connect to WebSocket
        connect()

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.d(TAG, "WebSocketService destroyed")
        isRunning = false
        instance = null

        // Unregister PTT receiver
        unregisterPttReceiver()

        handler.removeCallbacks(reconnectRunnable)
        handler.removeCallbacks(wakeLockRenewalRunnable)
        handler.removeCallbacks(heartbeatRunnable)
        disconnect()
        releaseWakeLock()

        super.onDestroy()
    }

    private fun connect() {
        val url = serverUrl ?: run {
            Log.e(TAG, "No server URL configured")
            return
        }

        val token = authToken ?: run {
            Log.e(TAG, "No auth token configured")
            return
        }

        Log.d(TAG, "Connecting to WebSocket: $url")

        // Close existing connection
        webSocket?.close(1000, "Reconnecting")
        webSocket = null

        val request = Request.Builder()
            .url(url)
            .build()

        webSocket = okHttpClient?.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "WebSocket connected")
                isConnected = true
                reconnectAttempts = 0

                // Authenticate
                authenticate(token)

                updateNotification("Connected")
                onConnectionStateChanged?.invoke(true)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                Log.d(TAG, "WebSocket message: ${text.take(100)}")
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closing: $code - $reason")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closed: $code - $reason")
                isConnected = false
                isAuthenticated = false
                onConnectionStateChanged?.invoke(false)

                // Reconnect unless intentionally closed
                if (code != 1000) {
                    scheduleReconnect()
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "WebSocket error: ${t.message}")
                isConnected = false
                isAuthenticated = false
                onConnectionStateChanged?.invoke(false)

                updateNotification("Reconnecting...")
                scheduleReconnect()
            }
        })
    }

    private fun disconnect() {
        webSocket?.close(1000, "Service stopped")
        webSocket = null
        isConnected = false
        isAuthenticated = false
    }

    private fun scheduleReconnect() {
        // Use exponential backoff but cap at 60 seconds
        reconnectAttempts++
        val delay = minOf(RECONNECT_DELAY_MS * minOf(reconnectAttempts, 20), 60_000L)
        Log.d(TAG, "Scheduling reconnect in ${delay}ms (attempt $reconnectAttempts)")

        updateNotification("Reconnecting... (attempt $reconnectAttempts)")

        handler.removeCallbacks(reconnectRunnable)
        handler.postDelayed(reconnectRunnable, delay)
    }

    private fun authenticate(token: String) {
        val authMessage = JSONObject().apply {
            put("type", "auth")
            put("token", token)
            displayName?.let { put("displayName", it) }
            put("timestamp", System.currentTimeMillis())
        }
        send(authMessage.toString())
    }

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            val type = json.optString("type")

            when (type) {
                "auth_success" -> {
                    Log.d(TAG, "Authentication successful")
                    isAuthenticated = true
                    updateNotification("Connected - Ready")

                    // Rejoin room if we have one
                    currentRoomId?.let { sendJoinRoom(it) }
                }
                "auth_failed" -> {
                    Log.e(TAG, "Authentication failed: ${json.optString("reason")}")
                    isAuthenticated = false
                    updateNotification("Auth failed")
                }
                "pong" -> {
                    // Heartbeat response - connection is alive
                    Log.d(TAG, "Pong received")
                }
                "floor_taken", "floor_granted", "floor_released" -> {
                    // Floor control messages - forward to Flutter
                    val speakerName = json.optJSONObject("speaker")?.optString("displayName")
                    if (type == "floor_taken" && speakerName != null) {
                        updateNotification("$speakerName is speaking")
                    } else if (type == "floor_released") {
                        updateNotification("Connected - Ready")
                    }
                }
            }

            // Forward all messages to Flutter
            onMessageReceived?.invoke(text)

        } catch (e: Exception) {
            Log.e(TAG, "Error handling message: ${e.message}")
        }
    }

    fun send(message: String): Boolean {
        return if (isConnected && webSocket != null) {
            webSocket?.send(message) ?: false
        } else {
            Log.w(TAG, "Cannot send - not connected")
            false
        }
    }

    fun sendJoinRoom(roomId: String) {
        if (!isAuthenticated) {
            Log.w(TAG, "Cannot join room - not authenticated")
            return
        }

        val message = JSONObject().apply {
            put("type", "join_room")
            put("roomId", roomId)
            put("timestamp", System.currentTimeMillis())
        }
        send(message.toString())
    }

    fun sendLeaveRoom(roomId: String) {
        val message = JSONObject().apply {
            put("type", "leave_room")
            put("roomId", roomId)
            put("timestamp", System.currentTimeMillis())
        }
        send(message.toString())
    }

    fun sendPing() {
        val message = JSONObject().apply {
            put("type", "ping")
            put("timestamp", System.currentTimeMillis())
        }
        send(message.toString())
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Voicely Connection",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps Voicely connected for real-time messages"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }

            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(content: String): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            pendingIntentFlags
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Voicely")
            .setContentText(content)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification(content: String) {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, createNotification(content))
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                Log.d(TAG, "Wake lock already held")
                return
            }

            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Voicely::WebSocketWakeLock"
            ).apply {
                // Acquire with 15-minute timeout, will be renewed automatically
                acquire(15 * 60 * 1000L)
            }
            Log.d(TAG, "Wake lock acquired")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire wake lock: ${e.message}")
        }
    }

    /**
     * Renew the wake lock to keep the service running indefinitely.
     * Called periodically by wakeLockRenewalRunnable.
     */
    private fun renewWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    // Release and re-acquire to reset the timeout
                    it.release()
                }
            }
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Voicely::WebSocketWakeLock"
            ).apply {
                acquire(15 * 60 * 1000L)
            }
            Log.d(TAG, "Wake lock renewed")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to renew wake lock: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "Wake lock released")
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock: ${e.message}")
        }
    }
}
