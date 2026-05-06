package com.livekitcallkitexample.incomingcall

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import com.facebook.react.ReactApplication
import com.facebook.react.bridge.Arguments
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.net.HttpURLConnection
import java.net.URL

class IncomingCallActionReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val action = when (intent.action) {
      IncomingCallModule.ACTION_ANSWER -> "answer"
      IncomingCallModule.ACTION_DECLINE -> "decline"
      else -> return
    }
    val uuid = intent.getStringExtra(IncomingCallModule.EXTRA_UUID) ?: return
    val requestId = intent.getIntExtra(IncomingCallModule.EXTRA_REQUEST_ID, -1)

    NotificationManagerCompat.from(context).cancel(uuid.hashCode())

    // Stop audio and screen wake lock immediately. Kotlin static fields work
    // when the receiver fires in the same process as the Firebase headless
    // handler that created the MediaPlayer. If the process differs, JS-side
    // hide() called from handleAnswer/handleDecline provides the fallback.
    IncomingCallModule.staticRingtone?.let { mp ->
      if (mp.isPlaying) mp.stop()
      mp.release()
    }
    IncomingCallModule.staticRingtone = null
    IncomingCallModule.staticWakeLock?.let { if (it.isHeld) it.release() }
    IncomingCallModule.staticWakeLock = null

    val prefs = context.getSharedPreferences(IncomingCallModule.PREFS_NAME, Context.MODE_PRIVATE)

    if (action == "decline") {
      // Primary path: call reject_handoff directly via HTTP so the app never
      // needs to open. Fresh JWT is saved by handleFcmMessage() on every push.
      val authToken = prefs.getString(IncomingCallModule.PREFS_KEY_AUTH_TOKEN, null)
      if (requestId > 0 && authToken != null) {
        val pendingResult = goAsync()
        Thread {
          try {
            rejectHandoff(requestId, authToken)
          } finally {
            pendingResult.finish()
          }
        }.start()
        // Fall through to also emit the JS event when context is available,
        // so handleDecline() in JS runs (clears pendingByUuid, calls hide()).
      } else {
        // No token or no requestId: store for JS drain when app next opens.
        storePendingAction(context, action, uuid)
        return
      }
      // Try to emit to the JS listener if the UI context is alive (app
      // backgrounded). JS handleDecline() will call hide() and rejectHandoff()
      // as well — that second rejectHandoff call will be a no-op on the server.
      emitToJs(context, action, uuid)
      return
    }

    // ANSWER path: always persist so the foreground JS drain can process it.
    storePendingAction(context, action, uuid)

    // Bring the app to the foreground so JS navigation can render InCallScreen.
    val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
    if (launchIntent != null) {
      launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
      context.startActivity(launchIntent)
    }

    // Also emit to JS if the UI context is already running (app backgrounded).
    // The listener clears SharedPreferences after processing to avoid the
    // cold-start drain double-processing the same action.
    emitToJs(context, action, uuid)
  }

  private fun storePendingAction(context: Context, action: String, uuid: String) {
    context.getSharedPreferences(IncomingCallModule.PREFS_NAME, Context.MODE_PRIVATE)
        .edit()
        .putString(
            IncomingCallModule.PREFS_KEY_PENDING_ACTION,
            """{"action":"$action","callUUID":"$uuid","timestamp":${System.currentTimeMillis()}}"""
        )
        .apply()
  }

  private fun emitToJs(context: Context, action: String, uuid: String) {
    val app = context.applicationContext as? ReactApplication ?: return
    val reactContext = app.reactHost?.currentReactContext ?: return
    val params = Arguments.createMap().apply {
      putString("action", action)
      putString("callUUID", uuid)
    }
    reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
        .emit(IncomingCallModule.EVENT_NAME, params)
  }

  private fun rejectHandoff(requestId: Int, authToken: String) {
    try {
      val url = URL("${IncomingCallModule.SUPABASE_FUNCTIONS_URL}/reject_handoff")
      val conn = url.openConnection() as HttpURLConnection
      conn.requestMethod = "POST"
      conn.setRequestProperty("Authorization", "Bearer $authToken")
      conn.setRequestProperty("Content-Type", "application/json")
      conn.connectTimeout = 8_000
      conn.readTimeout = 8_000
      conn.doOutput = true
      conn.outputStream.bufferedWriter().use { it.write("""{"request_id":$requestId}""") }
      conn.responseCode // execute request
      conn.disconnect()
    } catch (_: Exception) { /* best-effort: call will expire anyway */ }
  }
}
