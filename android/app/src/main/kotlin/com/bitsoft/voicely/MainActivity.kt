package com.bitsoft.voicely

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothA2dp
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.view.KeyEvent
import android.media.AudioManager
import android.media.AudioRecord
import android.media.ToneGenerator
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.bitsoft.voicely/audio"
    private val WAKELOCK_CHANNEL = "com.voicely.app/wakelock"
    private val WEBSOCKET_CHANNEL = "com.voicely.app/websocket"
    private val PTT_CHANNEL = "com.voicely.app/ptt"

    // Event channel for PTT hardware button events
    private var pttEventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    // Track PTT button state to prevent duplicate events
    private var isPttButtonPressed = false

    // Common PTT button key codes used by Chinese PTT devices
    // Different manufacturers use different codes
    private val PTT_KEY_CODES = setOf(
        KeyEvent.KEYCODE_HEADSETHOOK,         // 79 - Standard headset button
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,    // 85 - Media play/pause
        KeyEvent.KEYCODE_CALL,                // 5 - Some devices use call button
        // KeyEvent.KEYCODE_VOLUME_UP,        // 24 - Volume up (DISABLED - conflicts with volume control)
        // KeyEvent.KEYCODE_VOLUME_DOWN,      // 25 - Volume down (not used)
        79,   // KEYCODE_HEADSETHOOK explicit
        141,  // Inrico T310 PTT key (from manufacturer docs)
        142,  // Inrico T310 SOS key
        232,  // Inrico T310 F3 key
        293,  // Custom PTT key code used by some Chinese devices
        294,  // Custom PTT key code variant
        295,  // Custom PTT key code variant
        296,  // Custom PTT key code variant
        297,  // Custom PTT key code variant
        298,  // Custom PTT key code variant
        299,  // Custom PTT key code variant
        300,  // Custom PTT key code variant
        301,  // Custom PTT key code variant
        302,  // F1 on some devices used as PTT
        303,  // F2 on some devices used as PTT
        500,  // Some Motorola PTT devices
        501,  // Some Motorola PTT devices
    )

    // Set of key codes to enable PTT (can be configured from Flutter)
    private var enabledPttKeyCodes = PTT_KEY_CODES.toMutableSet()

    // Hardware noise suppressor (zero latency)
    private var noiseSuppressor: NoiseSuppressor? = null
    private var echoCanceler: AcousticEchoCanceler? = null

    // Inrico T310 PTT broadcast receiver
    private var pttBroadcastReceiver: BroadcastReceiver? = null

    // Partial wake lock for keeping CPU awake during background operation
    private var partialWakeLock: PowerManager.WakeLock? = null

    // Event channel for WebSocket messages
    private var webSocketEventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // WebSocket service method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WEBSOCKET_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val serverUrl = call.argument<String>("serverUrl")
                    val authToken = call.argument<String>("authToken")
                    val displayName = call.argument<String>("displayName")
                    val roomId = call.argument<String>("roomId")

                    if (serverUrl != null && authToken != null) {
                        WebSocketService.startService(this, serverUrl, authToken, displayName, roomId)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "serverUrl and authToken required", null)
                    }
                }
                "stopService" -> {
                    WebSocketService.stopService(this)
                    result.success(true)
                }
                "isRunning" -> {
                    result.success(WebSocketService.isServiceRunning())
                }
                "updateCredentials" -> {
                    val authToken = call.argument<String>("authToken")
                    val displayName = call.argument<String>("displayName")
                    if (authToken != null) {
                        WebSocketService.updateCredentials(authToken, displayName)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "authToken required", null)
                    }
                }
                "joinRoom" -> {
                    val roomId = call.argument<String>("roomId")
                    if (roomId != null) {
                        WebSocketService.joinRoom(roomId)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "roomId required", null)
                    }
                }
                "leaveRoom" -> {
                    val roomId = call.argument<String>("roomId")
                    if (roomId != null) {
                        WebSocketService.leaveRoom(roomId)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "roomId required", null)
                    }
                }
                "sendMessage" -> {
                    val message = call.argument<String>("message")
                    if (message != null) {
                        val sent = WebSocketService.sendMessage(message)
                        result.success(sent)
                    } else {
                        result.error("INVALID_ARGS", "message required", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // WebSocket event channel for receiving messages
        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "$WEBSOCKET_CHANNEL/events")
            .setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                    webSocketEventSink = events

                    // Set up callbacks from WebSocketService
                    WebSocketService.onConnectionStateChanged = { isConnected ->
                        runOnUiThread {
                            events?.success(mapOf(
                                "type" to "connectionState",
                                "isConnected" to isConnected
                            ))
                        }
                    }

                    WebSocketService.onMessageReceived = { message ->
                        runOnUiThread {
                            events?.success(mapOf(
                                "type" to "message",
                                "data" to message
                            ))
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    webSocketEventSink = null
                    WebSocketService.onConnectionStateChanged = null
                    WebSocketService.onMessageReceived = null
                }
            })

        // Wake lock method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKELOCK_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquirePartialWakeLock" -> {
                    result.success(acquirePartialWakeLock())
                }
                "releasePartialWakeLock" -> {
                    releasePartialWakeLock()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Audio method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSpeakerOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    setSpeakerOn(enabled)
                    result.success(true)
                }
                "setAudioModeForVoiceChat" -> {
                    setAudioModeForVoiceChat()
                    result.success(true)
                }
                "setAudioModeForBroadcasting" -> {
                    result.success(setAudioModeForBroadcasting())
                }
                "getAudioState" -> {
                    result.success(getAudioState())
                }
                "playTestTone" -> {
                    playTestTone()
                    result.success(true)
                }
                "resetAudioMode" -> {
                    resetAudioMode()
                    result.success(true)
                }
                "isBatteryOptimizationDisabled" -> {
                    result.success(isBatteryOptimizationDisabled())
                }
                "requestDisableBatteryOptimization" -> {
                    requestDisableBatteryOptimization()
                    result.success(true)
                }
                "enableNoiseSuppression" -> {
                    val audioSessionId = call.argument<Int>("audioSessionId") ?: 0
                    result.success(enableNoiseSuppression(audioSessionId))
                }
                "disableNoiseSuppression" -> {
                    disableNoiseSuppression()
                    result.success(true)
                }
                "isNoiseSuppressionAvailable" -> {
                    result.success(isNoiseSuppressionAvailable())
                }
                "isBluetoothAudioConnected" -> {
                    result.success(isBluetoothAudioConnected())
                }
                "routeAudioToAppropriateDevice" -> {
                    routeAudioToAppropriateDevice()
                    result.success(true)
                }
                "startBluetoothScoForMic" -> {
                    result.success(startBluetoothScoForMicrophone())
                }
                "stopBluetoothSco" -> {
                    stopBluetoothScoConnection()
                    result.success(true)
                }
                "setAudioModeForPlayback" -> {
                    setAudioModeForPlayback()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // PTT hardware button method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PTT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enablePttKeyCode" -> {
                    val keyCode = call.argument<Int>("keyCode")
                    if (keyCode != null) {
                        enabledPttKeyCodes.add(keyCode)
                        android.util.Log.d("VoicelyPTT", "Enabled PTT key code: $keyCode")
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "keyCode required", null)
                    }
                }
                "disablePttKeyCode" -> {
                    val keyCode = call.argument<Int>("keyCode")
                    if (keyCode != null) {
                        enabledPttKeyCodes.remove(keyCode)
                        android.util.Log.d("VoicelyPTT", "Disabled PTT key code: $keyCode")
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "keyCode required", null)
                    }
                }
                "getEnabledPttKeyCodes" -> {
                    result.success(enabledPttKeyCodes.toList())
                }
                "resetPttKeyCodes" -> {
                    enabledPttKeyCodes = PTT_KEY_CODES.toMutableSet()
                    result.success(true)
                }
                "isPttButtonPressed" -> {
                    result.success(isPttButtonPressed)
                }
                "wakeScreen" -> {
                    result.success(wakeScreen())
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // PTT event channel for receiving hardware button events in Flutter
        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "$PTT_CHANNEL/events")
            .setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                    pttEventSink = events
                    android.util.Log.d("VoicelyPTT", "PTT event channel connected")
                }

                override fun onCancel(arguments: Any?) {
                    pttEventSink = null
                    android.util.Log.d("VoicelyPTT", "PTT event channel disconnected")
                }
            })

        // Register Inrico T310 PTT broadcast receiver
        registerPttBroadcastReceiver()
    }

    /**
     * Register broadcast receiver for Inrico T310 PTT button events.
     * The T310 sends these broadcasts:
     * - android.intent.action.PTT.down (press)
     * - android.intent.action.PTT.up (release)
     * - android.intent.action.PTT.longpress (long press)
     */
    private fun registerPttBroadcastReceiver() {
        pttBroadcastReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                try {
                    when (intent?.action) {
                        "android.intent.action.PTT.down" -> {
                            if (!isPttButtonPressed) {
                                isPttButtonPressed = true
                                android.util.Log.d("VoicelyPTT", "PTT broadcast DOWN (Inrico T310)")
                                wakeScreen() // Wake screen on PTT press
                                sendPttEventSafe("ptt_down", 141, "broadcast")
                            }
                        }
                        "android.intent.action.PTT.up" -> {
                            if (isPttButtonPressed) {
                                isPttButtonPressed = false
                                android.util.Log.d("VoicelyPTT", "PTT broadcast UP (Inrico T310)")
                                sendPttEventSafe("ptt_up", 141, "broadcast")
                            }
                        }
                        "android.intent.action.PTT.longpress" -> {
                            android.util.Log.d("VoicelyPTT", "PTT broadcast LONGPRESS (Inrico T310)")
                            sendPttEventSafe("ptt_longpress", 141, "broadcast")
                        }
                        // SOS button broadcasts
                        "android.intent.action.SOS.down" -> {
                            android.util.Log.d("VoicelyPTT", "SOS broadcast DOWN (Inrico T310)")
                            sendPttEventSafe("sos_down", 142, "broadcast")
                        }
                        "android.intent.action.SOS.up" -> {
                            android.util.Log.d("VoicelyPTT", "SOS broadcast UP (Inrico T310)")
                            sendPttEventSafe("sos_up", 142, "broadcast")
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyPTT", "Error handling PTT broadcast: ${e.message}", e)
                }
            }
        }

        val filter = IntentFilter().apply {
            // Inrico T310 PTT button broadcasts
            addAction("android.intent.action.PTT.down")
            addAction("android.intent.action.PTT.up")
            addAction("android.intent.action.PTT.longpress")
            // Inrico T310 SOS button broadcasts
            addAction("android.intent.action.SOS.down")
            addAction("android.intent.action.SOS.up")
            addAction("android.intent.action.SOS.shortpress")
            addAction("android.intent.action.SOS.longpress")
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(pttBroadcastReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(pttBroadcastReceiver, filter)
            }
            android.util.Log.d("VoicelyPTT", "Registered Inrico T310 PTT broadcast receiver")
        } catch (e: Exception) {
            android.util.Log.e("VoicelyPTT", "Failed to register PTT broadcast receiver: ${e.message}", e)
        }
    }

    /**
     * Safely send PTT event to Flutter, catching any exceptions
     */
    private fun sendPttEventSafe(type: String, keyCode: Int, source: String) {
        try {
            runOnUiThread {
                try {
                    pttEventSink?.success(mapOf(
                        "type" to type,
                        "keyCode" to keyCode,
                        "source" to source,
                        "timestamp" to System.currentTimeMillis()
                    ))
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyPTT", "Error sending PTT event to Flutter: ${e.message}", e)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyPTT", "Error in runOnUiThread for PTT event: ${e.message}", e)
        }
    }

    /**
     * Handle hardware PTT button press (key down)
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        try {
            // Check if this is a PTT button we should handle
            if (keyCode in enabledPttKeyCodes && !isPttButtonPressed) {
                isPttButtonPressed = true
                android.util.Log.d("VoicelyPTT", "PTT button DOWN: keyCode=$keyCode")

                // Wake up the screen when PTT is pressed
                wakeScreen()

                // Send event to Flutter safely
                sendPttEventSafe("ptt_down", keyCode, "keyevent")

                // Consume the event so it doesn't trigger other actions
                return true
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyPTT", "Error in onKeyDown: ${e.message}", e)
        }

        return super.onKeyDown(keyCode, event)
    }

    /**
     * Handle hardware PTT button release (key up)
     */
    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        try {
            // Check if this is a PTT button we should handle
            if (keyCode in enabledPttKeyCodes && isPttButtonPressed) {
                isPttButtonPressed = false
                android.util.Log.d("VoicelyPTT", "PTT button UP: keyCode=$keyCode")

                // Send event to Flutter safely
                sendPttEventSafe("ptt_up", keyCode, "keyevent")

                // Consume the event
                return true
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyPTT", "Error in onKeyUp: ${e.message}", e)
        }

        return super.onKeyUp(keyCode, event)
    }

    private fun setSpeakerOn(enabled: Boolean) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Set mode to communication for WebRTC
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

        // Enable/disable speakerphone
        audioManager.isSpeakerphoneOn = enabled

        // For Android 12+, also try to set communication device
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val devices = audioManager.availableCommunicationDevices
                val speaker = devices.find { it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (speaker != null && enabled) {
                    audioManager.setCommunicationDevice(speaker)
                }
            } catch (e: Exception) {
                // Fallback to legacy method
            }
        }
    }

    /**
     * Configure audio specifically for BROADCASTING (microphone input focus)
     * This ensures the microphone is properly configured before getUserMedia
     */
    private fun setAudioModeForBroadcasting(): Boolean {
        android.util.Log.d("VoicelyAudio", "========== setAudioModeForBroadcasting START ==========")

        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audioManager == null) {
                android.util.Log.e("VoicelyAudio", "AudioManager is null!")
                return false
            }

            // Step 1: Request audio focus for voice communication
            android.util.Log.d("VoicelyAudio", "Step 1: Requesting audio focus for voice communication...")
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val focusRequest = android.media.AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                        .setAudioAttributes(
                            android.media.AudioAttributes.Builder()
                                .setUsage(android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION)
                                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build()
                        )
                        .build()
                    val focusResult = audioManager.requestAudioFocus(focusRequest)
                    android.util.Log.d("VoicelyAudio", "Audio focus result: $focusResult")
                } else {
                    @Suppress("DEPRECATION")
                    val focusResult = audioManager.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                    android.util.Log.d("VoicelyAudio", "Audio focus result (legacy): $focusResult")
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to request audio focus: ${e.message}")
            }

            // Step 2: Set audio mode to MODE_IN_COMMUNICATION
            android.util.Log.d("VoicelyAudio", "Step 2: Setting MODE_IN_COMMUNICATION...")
            try {
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                android.util.Log.d("VoicelyAudio", "Audio mode set: ${audioManager.mode}")
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to set audio mode: ${e.message}")
            }

            // Step 3: Ensure microphone is not muted
            android.util.Log.d("VoicelyAudio", "Step 3: Checking microphone mute status...")
            try {
                if (audioManager.isMicrophoneMute) {
                    audioManager.isMicrophoneMute = false
                    android.util.Log.d("VoicelyAudio", "Unmuted microphone")
                } else {
                    android.util.Log.d("VoicelyAudio", "Microphone already unmuted")
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to check/unmute mic: ${e.message}")
            }

            // Step 4: For non-Bluetooth, ensure we use built-in mic with speaker output
            android.util.Log.d("VoicelyAudio", "Step 4: Configuring audio routing...")
            try {
                val bluetoothStatus = isBluetoothAudioConnected()
                val isBluetoothConnected = bluetoothStatus["isConnected"] as? Boolean ?: false

                if (isBluetoothConnected) {
                    android.util.Log.d("VoicelyAudio", "Bluetooth connected - using Bluetooth mic/speaker")
                    // Don't change routing - let Bluetooth handle it
                } else {
                    android.util.Log.d("VoicelyAudio", "No Bluetooth - using built-in mic + speaker")
                    // Enable speakerphone so we use built-in mic + speaker
                    audioManager.isSpeakerphoneOn = true
                    android.util.Log.d("VoicelyAudio", "Speakerphone enabled: ${audioManager.isSpeakerphoneOn}")
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to configure audio routing: ${e.message}")
            }

            android.util.Log.d("VoicelyAudio", "========== setAudioModeForBroadcasting COMPLETE ==========")
            return true
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "setAudioModeForBroadcasting CRITICAL ERROR: ${e.message}", e)
            return false
        }
    }

    private fun setAudioModeForVoiceChat() {
        android.util.Log.d("VoicelyAudio", "========== setAudioModeForVoiceChat START ==========")
        android.util.Log.d("VoicelyAudio", "Android version: ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})")

        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audioManager == null) {
                android.util.Log.e("VoicelyAudio", "AudioManager is null!")
                return
            }

            android.util.Log.d("VoicelyAudio", "Step 1: Requesting audio focus...")
            // Request audio focus
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val focusRequest = android.media.AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                        .setAudioAttributes(
                            android.media.AudioAttributes.Builder()
                                .setUsage(android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION)
                                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build()
                        )
                        .build()
                    val focusResult = audioManager.requestAudioFocus(focusRequest)
                    android.util.Log.d("VoicelyAudio", "Audio focus result: $focusResult")
                } else {
                    @Suppress("DEPRECATION")
                    val focusResult = audioManager.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    android.util.Log.d("VoicelyAudio", "Audio focus result (legacy): $focusResult")
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to request audio focus: ${e.message}", e)
            }

            android.util.Log.d("VoicelyAudio", "Step 2: Setting audio mode to MODE_IN_COMMUNICATION...")
            // Set mode for voice communication
            try {
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                android.util.Log.d("VoicelyAudio", "Audio mode set to: ${audioManager.mode}")
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to set audio mode: ${e.message}", e)
            }

            android.util.Log.d("VoicelyAudio", "Step 3: Enabling speakerphone...")
            // CRITICAL: Force speaker ON immediately after setting mode
            // MODE_IN_COMMUNICATION defaults to earpiece, we want speaker
            try {
                audioManager.isSpeakerphoneOn = true
                android.util.Log.d("VoicelyAudio", "Speakerphone ON: ${audioManager.isSpeakerphoneOn}")
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to set speakerphone: ${e.message}", e)
            }

            // Log current volume levels (respect user's device volume setting)
            android.util.Log.d("VoicelyAudio", "Step 4: Checking volume levels (respecting user settings)...")
            try {
                val voiceVolume = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
                val maxVoiceVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
                val musicVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                val maxMusicVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                android.util.Log.d("VoicelyAudio", "Voice volume: $voiceVolume/$maxVoiceVolume, Music volume: $musicVolume/$maxMusicVolume (respecting user setting)")
                // NOTE: Volume is NOT forced - respecting user's device volume preference
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to get volume: ${e.message}", e)
            }

            android.util.Log.d("VoicelyAudio", "Step 5: Checking Bluetooth status...")
            // Check if Bluetooth is ACTUALLY connected before routing to it
            try {
                val bluetoothStatus = isBluetoothAudioConnected()
                val isBluetoothConnected = bluetoothStatus["isConnected"] as? Boolean ?: false

                if (isBluetoothConnected) {
                    // Route to Bluetooth only if truly connected
                    android.util.Log.d("VoicelyAudio", "Bluetooth device detected, routing to Bluetooth")
                    try {
                        routeAudioToAppropriateDevice()
                    } catch (e: Exception) {
                        android.util.Log.e("VoicelyAudio", "Failed to route to Bluetooth: ${e.message}", e)
                    }
                } else {
                    // No Bluetooth - ensure speaker is ON
                    android.util.Log.d("VoicelyAudio", "No Bluetooth device, ensuring speaker is ON")
                    try {
                        audioManager.isSpeakerphoneOn = true
                    } catch (e: Exception) {
                        android.util.Log.e("VoicelyAudio", "Failed to enable speaker: ${e.message}")
                    }

                    // For Android 12+, explicitly set speaker as communication device
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        android.util.Log.d("VoicelyAudio", "Step 6: Setting communication device to speaker (Android 12+)...")
                        try {
                            val devices = audioManager.availableCommunicationDevices
                            val speaker = devices.find { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                            if (speaker != null) {
                                val result = audioManager.setCommunicationDevice(speaker)
                                android.util.Log.d("VoicelyAudio", "setCommunicationDevice(speaker) = $result")
                            } else {
                                android.util.Log.w("VoicelyAudio", "Speaker device not found in availableCommunicationDevices")
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("VoicelyAudio", "Failed to set speaker as communication device: ${e.message}", e)
                        }
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to check/route Bluetooth: ${e.message}", e)
                // Fallback: just enable speaker
                try {
                    audioManager.isSpeakerphoneOn = true
                } catch (ignored: Exception) {
                    android.util.Log.e("VoicelyAudio", "Even fallback speaker enable failed")
                }
            }

            android.util.Log.d("VoicelyAudio", "========== setAudioModeForVoiceChat COMPLETE ==========")
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "setAudioModeForVoiceChat CRITICAL ERROR: ${e.message}", e)
        }
    }

    private fun getAudioState(): Map<String, Any> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        val voiceVolume = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
        val voiceMaxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
        val musicVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val musicMaxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)

        return mapOf(
            "mode" to audioManager.mode,
            "modeString" to when(audioManager.mode) {
                AudioManager.MODE_NORMAL -> "NORMAL"
                AudioManager.MODE_RINGTONE -> "RINGTONE"
                AudioManager.MODE_IN_CALL -> "IN_CALL"
                AudioManager.MODE_IN_COMMUNICATION -> "IN_COMMUNICATION"
                else -> "UNKNOWN(${audioManager.mode})"
            },
            "isSpeakerphoneOn" to audioManager.isSpeakerphoneOn,
            "isMusicActive" to audioManager.isMusicActive,
            "ringerMode" to audioManager.ringerMode,
            "voiceCallVolume" to voiceVolume,
            "voiceCallMaxVolume" to voiceMaxVolume,
            "musicVolume" to musicVolume,
            "musicMaxVolume" to musicMaxVolume
        )
    }

    private fun playTestTone() {
        try {
            // Play a short beep on the voice call stream to test audio output
            val toneGenerator = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 100)
            toneGenerator.startTone(ToneGenerator.TONE_PROP_BEEP, 500)
            android.util.Log.d("VoicelyAudio", "Playing test tone on STREAM_VOICE_CALL")

            // Also try on music stream
            Thread {
                Thread.sleep(600)
                try {
                    val toneGenerator2 = ToneGenerator(AudioManager.STREAM_MUSIC, 100)
                    toneGenerator2.startTone(ToneGenerator.TONE_PROP_BEEP2, 500)
                    android.util.Log.d("VoicelyAudio", "Playing test tone on STREAM_MUSIC")
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Failed to play tone on STREAM_MUSIC", e)
                }
            }.start()
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Failed to play test tone", e)
        }
    }

    private fun resetAudioMode() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Abandon audio focus
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val focusRequest = android.media.AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .build()
            audioManager.abandonAudioFocusRequest(focusRequest)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(null)
        }

        // Clear communication device on Android 12+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                audioManager.clearCommunicationDevice()
                android.util.Log.d("VoicelyAudio", "Cleared communication device")
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to clear communication device", e)
            }
        }

        // Reset to normal mode
        audioManager.mode = AudioManager.MODE_NORMAL
        audioManager.isSpeakerphoneOn = false

        android.util.Log.d("VoicelyAudio", "Reset audio mode to normal")
    }

    private fun isBatteryOptimizationDisabled(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            return powerManager.isIgnoringBatteryOptimizations(packageName)
        }
        return true // Pre-M devices don't have battery optimization
    }

    private fun requestDisableBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                    android.util.Log.d("VoicelyAudio", "Requested battery optimization exemption")
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Failed to request battery optimization exemption", e)
                    // Fallback: open battery optimization settings
                    try {
                        val fallbackIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        startActivity(fallbackIntent)
                    } catch (e2: Exception) {
                        android.util.Log.e("VoicelyAudio", "Failed to open battery settings", e2)
                    }
                }
            }
        }
    }

    /**
     * Check if hardware noise suppression is available on this device
     */
    private fun isNoiseSuppressionAvailable(): Map<String, Any> {
        return mapOf(
            "noiseSuppressor" to NoiseSuppressor.isAvailable(),
            "echoCanceler" to AcousticEchoCanceler.isAvailable()
        )
    }

    /**
     * Enable hardware-accelerated noise suppression (zero latency)
     * Call this when starting audio capture with the audio session ID
     */
    private fun enableNoiseSuppression(audioSessionId: Int): Map<String, Any> {
        var nsEnabled = false
        var aecEnabled = false

        try {
            // Enable NoiseSuppressor if available
            if (NoiseSuppressor.isAvailable()) {
                noiseSuppressor?.release()
                noiseSuppressor = NoiseSuppressor.create(audioSessionId)
                noiseSuppressor?.enabled = true
                nsEnabled = noiseSuppressor?.enabled == true
                android.util.Log.d("VoicelyAudio", "NoiseSuppressor enabled: $nsEnabled for session $audioSessionId")
            } else {
                android.util.Log.w("VoicelyAudio", "NoiseSuppressor not available on this device")
            }

            // Enable AcousticEchoCanceler if available
            if (AcousticEchoCanceler.isAvailable()) {
                echoCanceler?.release()
                echoCanceler = AcousticEchoCanceler.create(audioSessionId)
                echoCanceler?.enabled = true
                aecEnabled = echoCanceler?.enabled == true
                android.util.Log.d("VoicelyAudio", "AcousticEchoCanceler enabled: $aecEnabled for session $audioSessionId")
            } else {
                android.util.Log.w("VoicelyAudio", "AcousticEchoCanceler not available on this device")
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Failed to enable noise suppression", e)
        }

        return mapOf(
            "noiseSuppressorEnabled" to nsEnabled,
            "echoCancelerEnabled" to aecEnabled
        )
    }

    /**
     * Disable and release noise suppression resources
     */
    private fun disableNoiseSuppression() {
        try {
            noiseSuppressor?.enabled = false
            noiseSuppressor?.release()
            noiseSuppressor = null

            echoCanceler?.enabled = false
            echoCanceler?.release()
            echoCanceler = null

            android.util.Log.d("VoicelyAudio", "Noise suppression disabled and released")
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Error disabling noise suppression", e)
        }
    }

    /**
     * Check if any Bluetooth audio device is connected (headset, speaker, earbuds)
     * Checks both A2DP (media) and SCO (call/communication) profiles
     * Enhanced with Android 8.1 (API 27) compatibility
     */
    private fun isBluetoothAudioConnected(): Map<String, Any> {
        var isConnected = false
        var deviceName: String? = null
        var deviceType: String? = null

        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audioManager == null) {
                android.util.Log.e("VoicelyAudio", "AudioManager is null")
                return mapOf(
                    "isConnected" to false,
                    "deviceName" to "",
                    "deviceType" to ""
                )
            }

            // For Android 12+, use the modern API
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    val devices = audioManager.availableCommunicationDevices
                    for (device in devices) {
                        when (device.type) {
                            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                            AudioDeviceInfo.TYPE_BLE_HEADSET,
                            AudioDeviceInfo.TYPE_BLE_SPEAKER -> {
                                isConnected = true
                                deviceName = device.productName?.toString() ?: "Bluetooth Device"
                                deviceType = when (device.type) {
                                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "SCO"
                                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "A2DP"
                                    AudioDeviceInfo.TYPE_BLE_HEADSET -> "BLE_HEADSET"
                                    AudioDeviceInfo.TYPE_BLE_SPEAKER -> "BLE_SPEAKER"
                                    else -> "BLUETOOTH"
                                }
                                android.util.Log.d("VoicelyAudio", "Found Bluetooth device: $deviceName ($deviceType)")
                                break
                            }
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Error with availableCommunicationDevices: ${e.message}")
                }
            }

            // Also check using legacy method for broader compatibility (Android 8.1 and below)
            // Note: Only check isBluetoothScoOn (actually connected), NOT isBluetoothScoAvailableOffCall (just availability)
            if (!isConnected) {
                try {
                    // Check if Bluetooth SCO is actually ON (not just available)
                    if (audioManager.isBluetoothScoOn) {
                        isConnected = true
                        deviceType = "SCO_LEGACY"
                        android.util.Log.d("VoicelyAudio", "Bluetooth SCO is ON (legacy check)")
                    }
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Error checking isBluetoothScoOn: ${e.message}")
                }

                try {
                    // Check if Bluetooth A2DP is on (for media)
                    @Suppress("DEPRECATION")
                    if (audioManager.isBluetoothA2dpOn) {
                        isConnected = true
                        deviceType = "A2DP_LEGACY"
                        android.util.Log.d("VoicelyAudio", "Bluetooth A2DP on (legacy check)")
                    }
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Error checking isBluetoothA2dpOn: ${e.message}")
                }
            }

            // For Android 6+, check audio devices directly
            if (!isConnected && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    val outputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    for (device in outputDevices) {
                        when (device.type) {
                            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> {
                                isConnected = true
                                deviceName = device.productName?.toString() ?: "Bluetooth Device"
                                deviceType = if (device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) "SCO" else "A2DP"
                                android.util.Log.d("VoicelyAudio", "Found Bluetooth output device: $deviceName ($deviceType)")
                                break
                            }
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Error getting output devices: ${e.message}")
                }
            }

        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Error checking Bluetooth audio: ${e.message}", e)
        }

        android.util.Log.d("VoicelyAudio", "Bluetooth audio connected: $isConnected, device: $deviceName, type: $deviceType")

        return mapOf(
            "isConnected" to isConnected,
            "deviceName" to (deviceName ?: ""),
            "deviceType" to (deviceType ?: "")
        )
    }

    /**
     * Route audio to the appropriate device:
     * - If Bluetooth is connected, route to Bluetooth
     * - Otherwise, route to speaker
     * Enhanced with Android 8.1 (API 27) compatibility
     */
    private fun routeAudioToAppropriateDevice() {
        android.util.Log.d("VoicelyAudio", "routeAudioToAppropriateDevice START")

        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audioManager == null) {
                android.util.Log.e("VoicelyAudio", "AudioManager is null in routeAudioToAppropriateDevice")
                return
            }

            val bluetoothStatus = isBluetoothAudioConnected()
            val isBluetoothConnected = bluetoothStatus["isConnected"] as? Boolean ?: false

            android.util.Log.d("VoicelyAudio", "Routing audio - Bluetooth connected: $isBluetoothConnected")

            if (isBluetoothConnected) {
                // Route to Bluetooth
                routeToBluetoothAudio(audioManager)
            } else {
                // Route to speaker
                routeToSpeaker(audioManager)
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "routeAudioToAppropriateDevice ERROR: ${e.message}", e)
        }
    }

    /**
     * Route audio to Bluetooth device
     * Enhanced with Android 8.1 (API 27) compatibility
     */
    private fun routeToBluetoothAudio(audioManager: AudioManager) {
        android.util.Log.d("VoicelyAudio", "Routing audio to Bluetooth...")

        // Disable speakerphone first
        try {
            audioManager.isSpeakerphoneOn = false
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Failed to disable speakerphone: ${e.message}")
        }

        // For Android 12+, use setCommunicationDevice
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val devices = audioManager.availableCommunicationDevices
                // Find Bluetooth device (prefer BLE, then A2DP, then SCO)
                val bluetoothDevice = devices.find {
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                } ?: devices.find {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                } ?: devices.find {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                }

                if (bluetoothDevice != null) {
                    val result = audioManager.setCommunicationDevice(bluetoothDevice)
                    android.util.Log.d("VoicelyAudio", "setCommunicationDevice(Bluetooth ${bluetoothDevice.productName}) = $result")
                } else {
                    android.util.Log.w("VoicelyAudio", "No Bluetooth communication device found, using legacy method")
                    // Fallback to legacy SCO
                    startBluetoothSco(audioManager)
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to set Bluetooth communication device: ${e.message}", e)
                startBluetoothSco(audioManager)
            }
        } else {
            // Legacy: Start Bluetooth SCO for voice communication (Android 8.1 and older)
            android.util.Log.d("VoicelyAudio", "Using legacy Bluetooth SCO method for Android ${Build.VERSION.SDK_INT}")
            startBluetoothSco(audioManager)
        }
    }

    /**
     * Start Bluetooth SCO connection for voice communication (legacy method)
     * Enhanced with better error handling for Android 8.1
     */
    private fun startBluetoothSco(audioManager: AudioManager) {
        android.util.Log.d("VoicelyAudio", "startBluetoothSco (legacy) START")
        try {
            val scoAvailable = try {
                audioManager.isBluetoothScoAvailableOffCall
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Error checking SCO availability: ${e.message}")
                false
            }

            if (scoAvailable) {
                try {
                    audioManager.startBluetoothSco()
                    android.util.Log.d("VoicelyAudio", "Called startBluetoothSco()")
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "startBluetoothSco() failed: ${e.message}")
                }

                try {
                    audioManager.isBluetoothScoOn = true
                    android.util.Log.d("VoicelyAudio", "Started Bluetooth SCO")
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Failed to set isBluetoothScoOn: ${e.message}")
                }
            } else {
                android.util.Log.w("VoicelyAudio", "Bluetooth SCO not available off call")
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Failed to start Bluetooth SCO: ${e.message}", e)
        }
    }

    /**
     * Start Bluetooth SCO connection for microphone input (call this BEFORE getUserMedia)
     * Returns true if Bluetooth SCO was successfully started
     * Enhanced with Android 8.1 (API 27) compatibility
     */
    private fun startBluetoothScoForMicrophone(): Map<String, Any> {
        android.util.Log.d("VoicelyAudio", "========== startBluetoothScoForMicrophone START ==========")

        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audioManager == null) {
                android.util.Log.e("VoicelyAudio", "AudioManager is null")
                return mapOf<String, Any>(
                    "success" to false,
                    "reason" to "audio_manager_null",
                    "usingBuiltInMic" to true
                )
            }

            val bluetoothStatus = isBluetoothAudioConnected()
            val isBluetoothConnected = bluetoothStatus["isConnected"] as? Boolean ?: false

            if (!isBluetoothConnected) {
                android.util.Log.d("VoicelyAudio", "No Bluetooth device connected, using built-in mic")
                return mapOf<String, Any>(
                    "success" to false,
                    "reason" to "no_bluetooth",
                    "usingBuiltInMic" to true
                )
            }

            android.util.Log.d("VoicelyAudio", "Starting Bluetooth SCO for microphone input...")

            // Set communication mode first
            try {
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                android.util.Log.d("VoicelyAudio", "Audio mode set to MODE_IN_COMMUNICATION")
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to set audio mode: ${e.message}")
            }

            // For Android 12+, use setCommunicationDevice for both input and output
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    val devices = audioManager.availableCommunicationDevices
                    // Find Bluetooth device that supports both input and output (SCO devices)
                    val bluetoothDevice = devices.find {
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                    } ?: devices.find {
                        it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                    }

                    if (bluetoothDevice != null) {
                        // Disable speakerphone first
                        try {
                            audioManager.isSpeakerphoneOn = false
                        } catch (e: Exception) {
                            android.util.Log.e("VoicelyAudio", "Failed to disable speakerphone: ${e.message}")
                        }

                        val result = audioManager.setCommunicationDevice(bluetoothDevice)
                        android.util.Log.d("VoicelyAudio", "setCommunicationDevice for mic (${bluetoothDevice.productName}) = $result")

                        return mapOf<String, Any>(
                            "success" to result,
                            "deviceName" to (bluetoothDevice.productName?.toString() ?: "Bluetooth"),
                            "deviceType" to "SCO",
                            "usingBuiltInMic" to false
                        )
                    } else {
                        android.util.Log.w("VoicelyAudio", "No Bluetooth SCO device found, trying legacy method")
                    }
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Failed to set Bluetooth communication device for mic: ${e.message}", e)
                }
            }

            // Legacy method: Start Bluetooth SCO (for Android 8.1 and older)
            android.util.Log.d("VoicelyAudio", "Trying legacy Bluetooth SCO method...")
            return try {
                val scoAvailable = try {
                    audioManager.isBluetoothScoAvailableOffCall
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Error checking SCO availability: ${e.message}")
                    false
                }

                if (scoAvailable) {
                    // Disable speakerphone first
                    try {
                        audioManager.isSpeakerphoneOn = false
                    } catch (e: Exception) {
                        android.util.Log.e("VoicelyAudio", "Failed to disable speakerphone: ${e.message}")
                    }

                    // Start SCO connection
                    try {
                        audioManager.startBluetoothSco()
                        android.util.Log.d("VoicelyAudio", "Called startBluetoothSco()")
                    } catch (e: Exception) {
                        android.util.Log.e("VoicelyAudio", "startBluetoothSco() failed: ${e.message}")
                    }

                    try {
                        audioManager.isBluetoothScoOn = true
                        android.util.Log.d("VoicelyAudio", "Set isBluetoothScoOn = true")
                    } catch (e: Exception) {
                        android.util.Log.e("VoicelyAudio", "isBluetoothScoOn failed: ${e.message}")
                    }

                    android.util.Log.d("VoicelyAudio", "Started Bluetooth SCO for microphone (legacy)")

                    mapOf<String, Any>(
                        "success" to true,
                        "deviceName" to (bluetoothStatus["deviceName"] ?: "Bluetooth"),
                        "deviceType" to "SCO_LEGACY",
                        "usingBuiltInMic" to false
                    )
                } else {
                    android.util.Log.w("VoicelyAudio", "Bluetooth SCO not available off call")
                    mapOf<String, Any>(
                        "success" to false,
                        "reason" to "sco_not_available",
                        "usingBuiltInMic" to true
                    )
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to start Bluetooth SCO for mic: ${e.message}", e)
                mapOf<String, Any>(
                    "success" to false,
                    "reason" to (e.message ?: "unknown_error"),
                    "usingBuiltInMic" to true
                )
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "startBluetoothScoForMicrophone CRITICAL ERROR: ${e.message}", e)
            return mapOf<String, Any>(
                "success" to false,
                "reason" to "critical_error: ${e.message}",
                "usingBuiltInMic" to true
            )
        } finally {
            android.util.Log.d("VoicelyAudio", "========== startBluetoothScoForMicrophone END ==========")
        }
    }

    /**
     * Stop Bluetooth SCO connection (call this when done with microphone)
     */
    private fun stopBluetoothScoConnection() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        try {
            if (audioManager.isBluetoothScoOn) {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                android.util.Log.d("VoicelyAudio", "Stopped Bluetooth SCO")
            }

            // Clear communication device on Android 12+
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    audioManager.clearCommunicationDevice()
                    android.util.Log.d("VoicelyAudio", "Cleared communication device")
                } catch (e: Exception) {
                    android.util.Log.e("VoicelyAudio", "Failed to clear communication device", e)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Error stopping Bluetooth SCO", e)
        }
    }

    /**
     * Route audio to the built-in speaker
     */
    private fun routeToSpeaker(audioManager: AudioManager) {
        android.util.Log.d("VoicelyAudio", "Routing audio to speaker...")

        // Stop Bluetooth SCO if running
        try {
            if (audioManager.isBluetoothScoOn) {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                android.util.Log.d("VoicelyAudio", "Stopped Bluetooth SCO")
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Error stopping Bluetooth SCO", e)
        }

        // Enable speakerphone
        audioManager.isSpeakerphoneOn = true

        // For Android 12+, explicitly set speaker as communication device
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val devices = audioManager.availableCommunicationDevices
                val speaker = devices.find { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (speaker != null) {
                    val result = audioManager.setCommunicationDevice(speaker)
                    android.util.Log.d("VoicelyAudio", "setCommunicationDevice(speaker) = $result")
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to set speaker as communication device", e)
            }
        }
    }

    /**
     * Set audio mode for regular media playback (not voice communication)
     * This resets from MODE_IN_COMMUNICATION to MODE_NORMAL for louder speaker output
     */
    private fun setAudioModeForPlayback() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        android.util.Log.d("VoicelyAudio", "Setting audio mode for playback (MODE_NORMAL)")

        // Clear any communication device setting (Android 12+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                audioManager.clearCommunicationDevice()
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Error clearing communication device", e)
            }
        }

        // Stop Bluetooth SCO if active
        try {
            if (audioManager.isBluetoothScoOn) {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
            }
        } catch (e: Exception) {
            // Ignore
        }

        // Set mode to normal for regular media playback
        audioManager.mode = AudioManager.MODE_NORMAL

        // Enable speakerphone for output
        audioManager.isSpeakerphoneOn = true

        // Note: Do NOT override user's volume settings - respect device volume level
        try {
            val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            android.util.Log.d("VoicelyAudio", "Music volume: $currentVolume/$maxVolume (respecting user setting)")
        } catch (e: Exception) {
            // Ignore volume errors
        }

        android.util.Log.d("VoicelyAudio", "Audio mode set to NORMAL with speaker enabled")
    }

    /**
     * Acquire a partial wake lock to keep the CPU running even when screen is off.
     * This is critical for maintaining WebSocket connections in background.
     * Uses PARTIAL_WAKE_LOCK which only keeps CPU running, not screen.
     */
    private fun acquirePartialWakeLock(): Boolean {
        return try {
            if (partialWakeLock?.isHeld == true) {
                android.util.Log.d("VoicelyWakeLock", "Partial wake lock already held")
                return true
            }

            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            partialWakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Voicely::PTTWakeLock"
            ).apply {
                // Acquire with timeout (30 minutes) to prevent battery drain if app crashes
                acquire(30 * 60 * 1000L) // 30 minutes
            }

            android.util.Log.d("VoicelyWakeLock", "Partial wake lock acquired")
            true
        } catch (e: Exception) {
            android.util.Log.e("VoicelyWakeLock", "Failed to acquire partial wake lock", e)
            false
        }
    }

    /**
     * Release the partial wake lock
     */
    private fun releasePartialWakeLock() {
        try {
            if (partialWakeLock?.isHeld == true) {
                partialWakeLock?.release()
                android.util.Log.d("VoicelyWakeLock", "Partial wake lock released")
            }
            partialWakeLock = null
        } catch (e: Exception) {
            android.util.Log.e("VoicelyWakeLock", "Error releasing partial wake lock", e)
        }
    }

    /**
     * Wake up the screen when PTT button is pressed
     * Uses ACQUIRE_CAUSES_WAKEUP flag to turn on the display
     */
    private fun wakeScreen(): Boolean {
        return try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager

            // Check if screen is already on
            val isScreenOn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
                powerManager.isInteractive
            } else {
                @Suppress("DEPRECATION")
                powerManager.isScreenOn
            }

            if (!isScreenOn) {
                // Create a wake lock that turns on the screen
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.FULL_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                    "Voicely::ScreenWakeLock"
                )

                // Acquire briefly to wake screen, then release
                wakeLock.acquire(3000L) // 3 seconds
                android.util.Log.d("VoicelyPTT", "Screen woken up by PTT button")
            }
            true
        } catch (e: Exception) {
            android.util.Log.e("VoicelyPTT", "Failed to wake screen: ${e.message}", e)
            false
        }
    }

    override fun onDestroy() {
        // Clean up wake lock
        releasePartialWakeLock()
        // Clean up noise suppression
        disableNoiseSuppression()
        // Unregister PTT broadcast receiver
        pttBroadcastReceiver?.let {
            try {
                unregisterReceiver(it)
                android.util.Log.d("VoicelyPTT", "Unregistered PTT broadcast receiver")
            } catch (e: Exception) {
                android.util.Log.e("VoicelyPTT", "Error unregistering PTT receiver", e)
            }
        }
        pttBroadcastReceiver = null
        super.onDestroy()
    }
}
