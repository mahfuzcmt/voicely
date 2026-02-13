package com.bitsoft.voicely

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.bitsoft.voicely/audio"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            when (call.method) {
                "setAudioModeForVoiceChat" -> {
                    try {
                        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                        audioManager.requestAudioFocus(
                            null,
                            AudioManager.STREAM_VOICE_CALL,
                            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", "Failed to set audio mode: ${e.message}", null)
                    }
                }

                "setSpeakerOn" -> {
                    try {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        audioManager.isSpeakerphoneOn = enabled
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", "Failed to set speaker: ${e.message}", null)
                    }
                }

                "getAudioState" -> {
                    try {
                        val state = HashMap<String, Any>()
                        state["mode"] = audioManager.mode
                        state["modeString"] = when (audioManager.mode) {
                            AudioManager.MODE_NORMAL -> "MODE_NORMAL"
                            AudioManager.MODE_IN_COMMUNICATION -> "MODE_IN_COMMUNICATION"
                            AudioManager.MODE_IN_CALL -> "MODE_IN_CALL"
                            AudioManager.MODE_RINGTONE -> "MODE_RINGTONE"
                            else -> "UNKNOWN(${audioManager.mode})"
                        }
                        state["isSpeakerphoneOn"] = audioManager.isSpeakerphoneOn
                        state["isMusicActive"] = audioManager.isMusicActive
                        state["voiceCallVolume"] = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
                        state["voiceCallMaxVolume"] = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
                        state["musicVolume"] = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        state["musicMaxVolume"] = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        result.success(state)
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", "Failed to get audio state: ${e.message}", null)
                    }
                }

                "resetAudioMode" -> {
                    try {
                        audioManager.mode = AudioManager.MODE_NORMAL
                        audioManager.isSpeakerphoneOn = false
                        audioManager.abandonAudioFocus(null)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", "Failed to reset audio mode: ${e.message}", null)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
