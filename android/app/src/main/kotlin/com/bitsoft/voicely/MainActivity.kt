package com.bitsoft.voicely

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothA2dp
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
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

    // Hardware noise suppressor (zero latency)
    private var noiseSuppressor: NoiseSuppressor? = null
    private var echoCanceler: AcousticEchoCanceler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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

    private fun setAudioModeForVoiceChat() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Request audio focus
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val focusRequest = android.media.AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .build()
            audioManager.requestAudioFocus(focusRequest)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }

        // Set mode for voice communication
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

        // CRITICAL: Force speaker ON immediately after setting mode
        // MODE_IN_COMMUNICATION defaults to earpiece, we want speaker
        audioManager.isSpeakerphoneOn = true
        android.util.Log.d("VoicelyAudio", "Forced speakerphone ON after MODE_IN_COMMUNICATION")

        // CRITICAL: Set all relevant stream volumes to max
        try {
            // Voice call stream (used by MODE_IN_COMMUNICATION)
            val maxVoiceVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
            audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, maxVoiceVolume, 0)

            // Music stream (WebRTC might use this for playback)
            val maxMusicVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxMusicVolume, 0)
        } catch (e: Exception) {
            // Volume setting failed, continue anyway
        }

        // Check if Bluetooth is ACTUALLY connected before routing to it
        val bluetoothStatus = isBluetoothAudioConnected()
        val isBluetoothConnected = bluetoothStatus["isConnected"] as Boolean

        if (isBluetoothConnected) {
            // Route to Bluetooth only if truly connected
            android.util.Log.d("VoicelyAudio", "Bluetooth device detected, routing to Bluetooth")
            routeAudioToAppropriateDevice()
        } else {
            // No Bluetooth - ensure speaker is ON
            android.util.Log.d("VoicelyAudio", "No Bluetooth device, ensuring speaker is ON")
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
     */
    private fun isBluetoothAudioConnected(): Map<String, Any> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        var isConnected = false
        var deviceName: String? = null
        var deviceType: String? = null

        try {
            // For Android 12+, use the modern API
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
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
            }

            // Also check using legacy method for broader compatibility
            // Note: Only check isBluetoothScoOn (actually connected), NOT isBluetoothScoAvailableOffCall (just availability)
            if (!isConnected) {
                // Check if Bluetooth SCO is actually ON (not just available)
                if (audioManager.isBluetoothScoOn) {
                    isConnected = true
                    deviceType = "SCO_LEGACY"
                    android.util.Log.d("VoicelyAudio", "Bluetooth SCO is ON (legacy check)")
                }

                // Check if Bluetooth A2DP is on (for media)
                if (audioManager.isBluetoothA2dpOn) {
                    isConnected = true
                    deviceType = "A2DP_LEGACY"
                    android.util.Log.d("VoicelyAudio", "Bluetooth A2DP on (legacy check)")
                }
            }

            // For Android 6+, check audio devices directly
            if (!isConnected && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
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
            }

        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Error checking Bluetooth audio", e)
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
     */
    private fun routeAudioToAppropriateDevice() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val bluetoothStatus = isBluetoothAudioConnected()
        val isBluetoothConnected = bluetoothStatus["isConnected"] as Boolean

        android.util.Log.d("VoicelyAudio", "Routing audio - Bluetooth connected: $isBluetoothConnected")

        if (isBluetoothConnected) {
            // Route to Bluetooth
            routeToBluetoothAudio(audioManager)
        } else {
            // Route to speaker
            routeToSpeaker(audioManager)
        }
    }

    /**
     * Route audio to Bluetooth device
     */
    private fun routeToBluetoothAudio(audioManager: AudioManager) {
        android.util.Log.d("VoicelyAudio", "Routing audio to Bluetooth...")

        // Disable speakerphone first
        audioManager.isSpeakerphoneOn = false

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
                android.util.Log.e("VoicelyAudio", "Failed to set Bluetooth communication device", e)
                startBluetoothSco(audioManager)
            }
        } else {
            // Legacy: Start Bluetooth SCO for voice communication
            startBluetoothSco(audioManager)
        }
    }

    /**
     * Start Bluetooth SCO connection for voice communication (legacy method)
     */
    private fun startBluetoothSco(audioManager: AudioManager) {
        try {
            if (audioManager.isBluetoothScoAvailableOffCall) {
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
                android.util.Log.d("VoicelyAudio", "Started Bluetooth SCO")
            } else {
                android.util.Log.w("VoicelyAudio", "Bluetooth SCO not available off call")
            }
        } catch (e: Exception) {
            android.util.Log.e("VoicelyAudio", "Failed to start Bluetooth SCO", e)
        }
    }

    /**
     * Start Bluetooth SCO connection for microphone input (call this BEFORE getUserMedia)
     * Returns true if Bluetooth SCO was successfully started
     */
    private fun startBluetoothScoForMicrophone(): Map<String, Any> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val bluetoothStatus = isBluetoothAudioConnected()
        val isBluetoothConnected = bluetoothStatus["isConnected"] as Boolean

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
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

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
                    audioManager.isSpeakerphoneOn = false

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
                android.util.Log.e("VoicelyAudio", "Failed to set Bluetooth communication device for mic", e)
            }
        }

        // Legacy method: Start Bluetooth SCO
        return try {
            if (audioManager.isBluetoothScoAvailableOffCall) {
                // Disable speakerphone first
                audioManager.isSpeakerphoneOn = false

                // Start SCO connection
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true

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
            android.util.Log.e("VoicelyAudio", "Failed to start Bluetooth SCO for mic", e)
            mapOf<String, Any>(
                "success" to false,
                "reason" to (e.message ?: "unknown_error"),
                "usingBuiltInMic" to true
            )
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

        // Enable speakerphone for loud output
        audioManager.isSpeakerphoneOn = true

        // Set music stream to max volume
        try {
            val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxVolume, 0)
        } catch (e: Exception) {
            // Ignore volume errors
        }

        android.util.Log.d("VoicelyAudio", "Audio mode set to NORMAL with speaker enabled")
    }
}
