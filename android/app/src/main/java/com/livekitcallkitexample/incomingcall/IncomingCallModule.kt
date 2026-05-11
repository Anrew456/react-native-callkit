package com.livekitcallkitexample.incomingcall

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.livekitcallkitexample.KeepAliveService

class IncomingCallModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

  override fun getName() = MODULE_NAME

  @ReactMethod
  fun show(uuid: String, callerName: String, callerHandle: String?, requestId: Int) {
    val ctx = reactApplicationContext.applicationContext
    ensureChannel(ctx)

    // Cancel any existing notification before showing a new one so there is
    // never more than one incoming-call notification visible at a time.
    // This also handles the case where the FCM headless handler already called
    // show() and then WaitingScreen calls it again after being relaunched.
    val nm = NotificationManagerCompat.from(ctx)
    if (lastNotificationId != -1) nm.cancel(lastNotificationId)

    val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
    @Suppress("DEPRECATION")
    staticWakeLock?.let { if (it.isHeld) it.release() }
    @Suppress("DEPRECATION")
    staticWakeLock = pm.newWakeLock(
        PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
        "Talky:IncomingCall"
    ).also { it.acquire(30_000L) }

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
        .setContentText(callerHandle ?: "Chiamata in arrivo")
        .setPriority(NotificationCompat.PRIORITY_MAX)
        .setCategory(NotificationCompat.CATEGORY_CALL)
        .setOngoing(true)
        .setAutoCancel(false)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setFullScreenIntent(launchPi, true)
        .setContentIntent(launchPi)
        .build()

    lastNotificationId = uuid.hashCode()
    nm.notify(lastNotificationId, notif)
  }

  @ReactMethod
  fun hide(uuid: String) {
    stopAudioAndWakeLock()
    NotificationManagerCompat.from(reactApplicationContext).cancel(uuid.hashCode())
  }

  @ReactMethod
  fun hideAll() {
    stopAudioAndWakeLock()
    val id = lastNotificationId
    if (id != -1) {
      NotificationManagerCompat.from(reactApplicationContext).cancel(id)
      lastNotificationId = -1
    }
  }

  // Android 14+ (API 34) requires USE_FULL_SCREEN_INTENT to be explicitly granted
  // by the user. If not granted, the incoming call notification won't appear over
  // the lock screen — it will only show in the notification shade.
  @ReactMethod
  fun checkFullScreenIntentPermission(promise: Promise) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      promise.resolve(true)
      return
    }
    val notifManager = reactApplicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (notifManager.canUseFullScreenIntent()) {
      promise.resolve(true)
      return
    }
    val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
      data = Uri.parse("package:${reactApplicationContext.packageName}")
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    reactApplicationContext.startActivity(intent)
    promise.resolve(false)
  }

  // Requests exemption from battery optimization so FCM messages are delivered
  // reliably on OEM devices (Samsung, Xiaomi, Oppo, etc.) with aggressive
  // background-process killing. Shows a direct system dialog for this app only.
  @ReactMethod
  fun requestBatteryOptimizationExemption(promise: Promise) {
    val pm = reactApplicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
    if (pm.isIgnoringBatteryOptimizations(reactApplicationContext.packageName)) {
      promise.resolve(true)
      return
    }
    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
      data = Uri.parse("package:${reactApplicationContext.packageName}")
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    reactApplicationContext.startActivity(intent)
    promise.resolve(false)
  }

  @ReactMethod
  fun startKeepAlive() {
    val intent = Intent(reactApplicationContext.applicationContext, KeepAliveService::class.java)
    reactApplicationContext.applicationContext.startForegroundService(intent)
  }

  @ReactMethod
  fun stopKeepAlive() {
    val intent = Intent(reactApplicationContext.applicationContext, KeepAliveService::class.java)
    reactApplicationContext.applicationContext.stopService(intent)
  }

  @ReactMethod
  fun addListener(eventName: String) { /* required for RN event emitter */ }

  @ReactMethod
  fun removeListeners(count: Int) { /* required for RN event emitter */ }

  private fun stopAudioAndWakeLock() {
    staticRingtone?.let { mp ->
      if (mp.isPlaying) mp.stop()
      mp.release()
    }
    staticRingtone = null
    staticWakeLock?.let { if (it.isHeld) it.release() }
    staticWakeLock = null
  }

  private fun ensureChannel(ctx: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val notifManager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (notifManager.getNotificationChannel(CHANNEL_ID) != null) return

    val channel = NotificationChannel(
        CHANNEL_ID,
        "Chiamate in arrivo",
        NotificationManager.IMPORTANCE_HIGH
    ).apply {
      description = "Notifiche per chiamate in arrivo"
      setSound(null, null)
      enableVibration(true)
      lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
    }
    notifManager.createNotificationChannel(channel)
  }

  companion object {
    const val MODULE_NAME = "IncomingCallUI"
    const val CHANNEL_ID = "incoming_calls_v2"
    const val EXTRA_UUID = "incoming_call_uuid"
    const val EVENT_NAME = "IncomingCallAction"

    @JvmStatic var staticRingtone: MediaPlayer? = null
    @JvmStatic var staticWakeLock: PowerManager.WakeLock? = null
    @JvmStatic var lastNotificationId: Int = -1
  }
}
