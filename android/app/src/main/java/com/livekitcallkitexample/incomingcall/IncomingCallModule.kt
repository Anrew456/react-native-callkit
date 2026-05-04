package com.livekitcallkitexample.incomingcall

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

class IncomingCallModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

  override fun getName() = MODULE_NAME

  @ReactMethod
  fun show(uuid: String, callerName: String, callerHandle: String?) {
    val ctx = reactApplicationContext.applicationContext
    ensureChannel(ctx)

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
            actionPi(ctx, ACTION_ANSWER, uuid, 1)
        )
        .addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Decline",
            actionPi(ctx, ACTION_DECLINE, uuid, 2)
        )
        .build()

    NotificationManagerCompat.from(ctx).notify(uuid.hashCode(), notif)
  }

  @ReactMethod
  fun hide(uuid: String) {
    NotificationManagerCompat.from(reactApplicationContext).cancel(uuid.hashCode())
  }

  @ReactMethod
  fun addListener(eventName: String) { /* required for RN event emitter */ }

  @ReactMethod
  fun removeListeners(count: Int) { /* required for RN event emitter */ }

  private fun actionPi(ctx: Context, action: String, uuid: String, code: Int): PendingIntent {
    val intent = Intent(ctx, IncomingCallActionReceiver::class.java).apply {
      this.action = action
      putExtra(EXTRA_UUID, uuid)
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

    val ringtoneAttrs = AudioAttributes.Builder()
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
        .build()

    val channel = NotificationChannel(
        CHANNEL_ID,
        "Incoming calls",
        NotificationManager.IMPORTANCE_HIGH
    ).apply {
      description = "Notifications for incoming calls"
      setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), ringtoneAttrs)
      enableVibration(true)
      lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
    }
    nm.createNotificationChannel(channel)
  }

  companion object {
    const val MODULE_NAME = "IncomingCallUI"
    const val CHANNEL_ID = "incoming_calls"
    const val ACTION_ANSWER = "com.livekitcallkitexample.incomingcall.ANSWER"
    const val ACTION_DECLINE = "com.livekitcallkitexample.incomingcall.DECLINE"
    const val EXTRA_UUID = "incoming_call_uuid"
    const val EVENT_NAME = "IncomingCallAction"
  }
}
