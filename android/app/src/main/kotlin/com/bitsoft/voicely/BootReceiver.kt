package com.bitsoft.voicely

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Broadcast receiver to handle device boot and restart WebSocket service
 * if it was running before the device was restarted.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
        private const val PREF_NAME = "voicely_service_prefs"
        private const val KEY_SERVICE_RUNNING = "service_was_running"
        private const val KEY_SERVER_URL = "server_url"
        private const val KEY_AUTH_TOKEN = "auth_token"
        private const val KEY_DISPLAY_NAME = "display_name"
        private const val KEY_ROOM_ID = "room_id"

        /**
         * Save service state to SharedPreferences so it can be restored on boot.
         */
        fun saveServiceState(
            context: Context,
            isRunning: Boolean,
            serverUrl: String? = null,
            authToken: String? = null,
            displayName: String? = null,
            roomId: String? = null
        ) {
            val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putBoolean(KEY_SERVICE_RUNNING, isRunning)
                if (serverUrl != null) putString(KEY_SERVER_URL, serverUrl)
                if (authToken != null) putString(KEY_AUTH_TOKEN, authToken)
                if (displayName != null) putString(KEY_DISPLAY_NAME, displayName)
                if (roomId != null) putString(KEY_ROOM_ID, roomId)
                apply()
            }
            Log.d(TAG, "Service state saved: running=$isRunning")
        }

        /**
         * Clear saved service state.
         */
        fun clearServiceState(context: Context) {
            val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.edit().clear().apply()
            Log.d(TAG, "Service state cleared")
        }
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) return

        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                Log.d(TAG, "Boot/package replaced received: ${intent.action}")
                restartServiceIfNeeded(context)
            }
        }
    }

    private fun restartServiceIfNeeded(context: Context) {
        val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val wasRunning = prefs.getBoolean(KEY_SERVICE_RUNNING, false)

        if (!wasRunning) {
            Log.d(TAG, "Service was not running, not restarting")
            return
        }

        val serverUrl = prefs.getString(KEY_SERVER_URL, null)
        val authToken = prefs.getString(KEY_AUTH_TOKEN, null)
        val displayName = prefs.getString(KEY_DISPLAY_NAME, null)
        val roomId = prefs.getString(KEY_ROOM_ID, null)

        if (serverUrl == null || authToken == null) {
            Log.w(TAG, "Missing credentials, cannot restart service")
            return
        }

        Log.d(TAG, "Restarting WebSocket service after boot")
        WebSocketService.startService(context, serverUrl, authToken, displayName, roomId)
    }
}
