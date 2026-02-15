package com.bitsoft.voicely

import android.content.Context
import android.content.Intent
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
        audioManager.isSpeakerphoneOn = true

        // CRITICAL: Set all relevant stream volumes to max
        try {
            // Voice call stream (used by MODE_IN_COMMUNICATION)
            val maxVoiceVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
            audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, maxVoiceVolume, 0)

            // Music stream (WebRTC might use this for playback)
            val maxMusicVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxMusicVolume, 0)

            // Communication stream (alternate stream for VoIP)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                // No direct STREAM_COMMUNICATION, but ensure volume is up
            }
        } catch (e: Exception) {
            // Volume setting failed, continue anyway
        }

        // For Android 12+, explicitly set speaker as communication device
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val devices = audioManager.availableCommunicationDevices
                val speaker = devices.find { it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (speaker != null) {
                    val result = audioManager.setCommunicationDevice(speaker)
                    android.util.Log.d("VoicelyAudio", "setCommunicationDevice(speaker) = $result")
                }
            } catch (e: Exception) {
                android.util.Log.e("VoicelyAudio", "Failed to set communication device", e)
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
}
