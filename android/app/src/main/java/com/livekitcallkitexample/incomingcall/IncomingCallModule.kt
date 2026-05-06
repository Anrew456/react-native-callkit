package com.livekitcallkitexample.incomingcall

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

class IncomingCallModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

  override fun getName() = MODULE_NAME

  // Persists the user JWT so IncomingCallActionReceiver can call reject_handoff
  // without opening the app. Called from JS whenever the session changes.
  @ReactMethod
  fun saveAuthToken(token: String) {
    reactApplicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        .edit()
        .putString(PREFS_KEY_AUTH_TOKEN, token)
        .apply()
  }

  @ReactMethod
  fun show(uuid: String, callerName: String, callerHandle: String?, requestId: Int) {
    val ctx = reactApplicationContext.applicationContext
    ensureChannel(ctx)

    // Wake the screen so the notification is immediately visible.
    // Static field so it survives headless→UI context switch.
    val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
    @Suppress("DEPRECATION")
    staticWakeLock?.let { if (it.isHeld) it.release() }
    @Suppress("DEPRECATION")
    staticWakeLock = pm.newWakeLock(
        PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
        "Talky:IncomingCall"
    ).also { it.acquire(30_000L) }

    // Play a looping ringtone explicitly so hide() can stop it immediately.
    // The notification channel has setSound(null) so there's no double-play.
    // Static field so the player survives headless→UI context switch.
    staticRingtone?.let { mp ->
      if (mp.isPlaying) mp.stop()
      mp.release()
    }
    staticRingtone = null
    try {
      val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
      if (uri != null) {
        staticRingtone = MediaPlayer().apply {
          setAudioAttributes(
              AudioAttributes.Builder()
                  .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                  .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                  .build()
          )
          setDataSource(ctx, uri)
          isLooping = true
          prepare()
          start()
        }
      }
    } catch (_: Exception) { /* best-effort; vibration still works */ }

    val launchIntent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      putExtra(EXTRA_UUID, uuid)
    }
    val launchPi = PendingIntent.getActivity(
        ctx, uuid.hashCode(), launchIntent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    val notif = NotificationCompat.Builder(ctx, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.sym_call_incoming)
        .setContentTitle(callerName)
        .setContentText(callerHandle ?: "Incoming call")
        .setPriority(NotificationCompat.PRIORITY_MAX)
        .setCategory(NotificationCompat.CATEGORY_CALL)
        .setOngoing(true)
        .setAutoCancel(false)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setFullScreenIntent(launchPi, true)
        .setContentIntent(launchPi)
        .addAction(
            android.R.drawable.ic_menu_call,
            "Answer",
            actionPi(ctx, ACTION_ANSWER, uuid, requestId, 1)
        )
        .addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Decline",
            actionPi(ctx, ACTION_DECLINE, uuid, requestId, 2)
        )
        .build()

    NotificationManagerCompat.from(ctx).notify(uuid.hashCode(), notif)
  }

  @ReactMethod
  fun hide(uuid: String) {
    staticRingtone?.let { mp ->
      if (mp.isPlaying) mp.stop()
      mp.release()
    }
    staticRingtone = null
    staticWakeLock?.let { if (it.isHeld) it.release() }
    staticWakeLock = null
    NotificationManagerCompat.from(reactApplicationContext).cancel(uuid.hashCode())
  }

  // Returns and clears any action stored by IncomingCallActionReceiver when
  // the foreground JS listener was not ready. JSON: {"action","callUUID","timestamp"}.
  @ReactMethod
  fun consumePendingAction(promise: Promise) {
    val prefs = reactApplicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    val json = prefs.getString(PREFS_KEY_PENDING_ACTION, null)
    if (json != null) prefs.edit().remove(PREFS_KEY_PENDING_ACTION).apply()
    promise.resolve(json)
  }

  @ReactMethod
  fun addListener(eventName: String) { /* required for RN event emitter */ }

  @ReactMethod
  fun removeListeners(count: Int) { /* required for RN event emitter */ }

  private fun actionPi(
      ctx: Context,
      action: String,
      uuid: String,
      requestId: Int,
      code: Int
  ): PendingIntent {
    val intent = Intent(ctx, IncomingCallActionReceiver::class.java).apply {
      this.action = action
      putExtra(EXTRA_UUID, uuid)
      putExtra(EXTRA_REQUEST_ID, requestId)
    }
    return PendingIntent.getBroadcast(
        ctx, uuid.hashCode() + code, intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
  }

  private fun ensureChannel(ctx: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (nm.getNotificationChannel(CHANNEL_ID) != null) return

    val channel = NotificationChannel(
        CHANNEL_ID,
        "Incoming calls",
        NotificationManager.IMPORTANCE_HIGH
    ).apply {
      description = "Notifications for incoming calls"
      // No sound on the channel — ringtone is managed by MediaPlayer
      // so that hide() can stop it immediately on answer/decline.
      setSound(null, null)
      enableVibration(true)
      lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
    }
    nm.createNotificationChannel(channel)
  }

  companion object {
    const val MODULE_NAME = "IncomingCallUI"
    // v2 channel has no sound (MediaPlayer handles audio explicitly).
    // A new channel ID forces recreation since existing channels are immutable.
    const val CHANNEL_ID = "incoming_calls_v2"
    const val ACTION_ANSWER = "com.livekitcallkitexample.incomingcall.ANSWER"
    const val ACTION_DECLINE = "com.livekitcallkitexample.incomingcall.DECLINE"
    const val EXTRA_UUID = "incoming_call_uuid"
    const val EXTRA_REQUEST_ID = "incoming_call_request_id"
    const val EVENT_NAME = "IncomingCallAction"
    const val PREFS_NAME = "IncomingCall"
    const val PREFS_KEY_PENDING_ACTION = "pending_action"
    const val PREFS_KEY_AUTH_TOKEN = "auth_token"
    const val SUPABASE_FUNCTIONS_URL =
        "https://cmfliziflrbvoptfzhag.supabase.co/functions/v1"

    // Static so audio/wake-lock survive headless-JS → UI context switch.
    @JvmStatic var staticRingtone: MediaPlayer? = null
    @JvmStatic var staticWakeLock: PowerManager.WakeLock? = null
  }
}
