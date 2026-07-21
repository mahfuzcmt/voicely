package com.bitsoft.voicely

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * AccessibilityService to capture PTT hardware button presses even when screen is off.
 * This service can capture global key events and wake the screen.
 */
class PttAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "VoicelyPttService"

        // PTT key codes from various Chinese PTT devices - comprehensive list
        private val PTT_KEY_CODES = setOf(
            KeyEvent.KEYCODE_HEADSETHOOK,         // 79
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,    // 85
            KeyEvent.KEYCODE_MEDIA_PLAY,          // 126
            KeyEvent.KEYCODE_MEDIA_PAUSE,         // 127
            KeyEvent.KEYCODE_CALL,                // 5
            KeyEvent.KEYCODE_CAMERA,              // 27
            KeyEvent.KEYCODE_FOCUS,               // 80
            KeyEvent.KEYCODE_VOLUME_UP,           // 24 - some devices use this
            KeyEvent.KEYCODE_VOLUME_DOWN,         // 25
            KeyEvent.KEYCODE_F1,                  // 131
            KeyEvent.KEYCODE_F2,                  // 132
            KeyEvent.KEYCODE_F3,                  // 133
            KeyEvent.KEYCODE_F4,                  // 134
            87,   // scanCode 87 direct
            131, // QMSTAR PTT / F1
            132, 133, 134, // F2, F3, F4
            141, // Inrico T310 PTT - MT 261S main button
            142, // Inrico SOS
            143, 144, 145, // More Inrico keys
            201, 202, // UNIPRO P2/P3
            232, // Inrico F3
            289, 290, 291, 292, // Extended function keys
            293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303,
            500, 501, 502, 503, // Motorola
            // Common Android extended key codes
            1000, 1001, 1002, 1003, 1004, 1005
        )

        var instance: PttAccessibilityService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this

        val info = AccessibilityServiceInfo().apply {
            // We only want key events
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            notificationTimeout = 0
        }
        serviceInfo = info

        Log.d(TAG, "PTT Accessibility Service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // We don't need to handle accessibility events, only key events
    }

    override fun onInterrupt() {
        Log.d(TAG, "PTT Accessibility Service interrupted")
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        val action = event.action
        val scanCode = event.scanCode

        Log.d(TAG, "onKeyEvent: keyCode=$keyCode, scanCode=$scanCode, action=$action")

        // Check if this is a PTT key (by keyCode or scanCode)
        // scanCode 87 is the PTT button on MYT V960
        if (keyCode in PTT_KEY_CODES || scanCode == 87) {
            if (action == KeyEvent.ACTION_DOWN) {
                Log.d(TAG, "PTT key DOWN detected: keyCode=$keyCode, scanCode=$scanCode - waking screen")
                wakeScreenAndLaunchApp()
            }
            // Don't consume the event - let it pass through to the app
            return false
        }

        // Log all F-keys for debugging
        if (keyCode in 131..142) { // F1-F12
            Log.d(TAG, "F-key detected: keyCode=$keyCode (F${keyCode - 130}), action=$action")
            if (action == KeyEvent.ACTION_DOWN) {
                wakeScreenAndLaunchApp()
            }
        }

        return false
    }

    private fun wakeScreenAndLaunchApp() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager

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
                    "Voicely::PttAccessibilityWakeLock"
                )
                wakeLock.acquire(10000L) // 10 seconds
                Log.d(TAG, "Wake lock acquired - screen should turn on")

                // Launch the app to bring it to foreground
                try {
                    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                    if (launchIntent != null) {
                        launchIntent.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                        )
                        startActivity(launchIntent)
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

    override fun onDestroy() {
        instance = null
        Log.d(TAG, "PTT Accessibility Service destroyed")
        super.onDestroy()
    }
}
