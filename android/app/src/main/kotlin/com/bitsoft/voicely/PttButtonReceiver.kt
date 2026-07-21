package com.bitsoft.voicely

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.view.KeyEvent
import android.util.Log

/**
 * BroadcastReceiver for handling PTT/Media button presses when screen is off.
 * This receiver is registered in the manifest and can wake the device.
 */
class PttButtonReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "VoicelyPttReceiver"

        // PTT key codes from various Chinese PTT devices
        private val PTT_KEY_CODES = setOf(
            KeyEvent.KEYCODE_HEADSETHOOK,         // 79
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,    // 85
            KeyEvent.KEYCODE_MEDIA_PLAY,          // 126
            KeyEvent.KEYCODE_MEDIA_PAUSE,         // 127
            KeyEvent.KEYCODE_CALL,                // 5
            79, 85, 126, 127,
            131, // QMSTAR PTT
            141, 142, // Inrico T310
            293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303,
            500, 501 // Motorola
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "Received broadcast: ${intent.action}")

        when (intent.action) {
            Intent.ACTION_MEDIA_BUTTON -> {
                handleMediaButton(context, intent)
            }
            "android.intent.action.PTT.down",
            "com.myt.action.PTT_DOWN",
            "com.freeme.action.PTT_DOWN" -> {
                Log.d(TAG, "PTT.down broadcast received: ${intent.action}")
                wakeScreenAndLaunchApp(context)
            }
            "android.intent.action.PTT.up",
            "com.myt.action.PTT_UP",
            "com.freeme.action.PTT_UP" -> {
                Log.d(TAG, "PTT.up broadcast received: ${intent.action}")
            }
            "android.intent.action.PTT.longpress" -> {
                Log.d(TAG, "PTT.longpress broadcast received")
                wakeScreenAndLaunchApp(context)
            }
            else -> {
                // Log any unknown PTT-related action
                if (intent.action?.contains("PTT", ignoreCase = true) == true ||
                    intent.action?.contains("ptt", ignoreCase = true) == true) {
                    Log.d(TAG, "Unknown PTT action received: ${intent.action}")
                    wakeScreenAndLaunchApp(context)
                }
            }
        }
    }

    private fun handleMediaButton(context: Context, intent: Intent) {
        val event = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
        }

        if (event == null) {
            Log.d(TAG, "No KeyEvent in media button intent")
            return
        }

        val keyCode = event.keyCode
        val action = event.action

        Log.d(TAG, "Media button: keyCode=$keyCode, action=$action")

        // Only handle key down events for PTT-like keys
        if (action == KeyEvent.ACTION_DOWN && keyCode in PTT_KEY_CODES) {
            Log.d(TAG, "PTT key detected: $keyCode - waking screen")
            wakeScreenAndLaunchApp(context)
        }
    }

    private fun wakeScreenAndLaunchApp(context: Context) {
        try {
            // Wake the screen
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager

            val isScreenOn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
                powerManager.isInteractive
            } else {
                @Suppress("DEPRECATION")
                powerManager.isScreenOn
            }

            Log.d(TAG, "wakeScreenAndLaunchApp: isScreenOn=$isScreenOn")

            if (!isScreenOn) {
                // Acquire wake lock to turn on screen
                @Suppress("DEPRECATION")
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                    "Voicely::PttWakeLock"
                )
                wakeLock.acquire(10000L) // 10 seconds
                Log.d(TAG, "Wake lock acquired")

                // Also launch the app to bring it to foreground
                try {
                    val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                    if (launchIntent != null) {
                        launchIntent.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                        )
                        context.startActivity(launchIntent)
                        Log.d(TAG, "App launched to foreground")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to launch app: ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "wakeScreenAndLaunchApp error: ${e.message}", e)
        }
    }
}
