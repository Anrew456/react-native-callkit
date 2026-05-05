package com.livekitcallkitexample.incomingcall

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import com.facebook.react.ReactApplication
import com.facebook.react.bridge.Arguments
import com.facebook.react.modules.core.DeviceEventManagerModule

class IncomingCallActionReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val action = when (intent.action) {
      IncomingCallModule.ACTION_ANSWER -> "answer"
      IncomingCallModule.ACTION_DECLINE -> "decline"
      else -> return
    }
    val uuid = intent.getStringExtra(IncomingCallModule.EXTRA_UUID) ?: return

    NotificationManagerCompat.from(context).cancel(uuid.hashCode())

    // On answer, bring the app to the foreground so the JS navigation can
    // render InCallScreen. Without this, navigateToInCall() runs in the
    // background JS context and the user never sees the call screen until
    // they manually open the app.
    if (action == "answer") {
      val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
      if (launchIntent != null) {
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        context.startActivity(launchIntent)
      }
    }

    val app = context.applicationContext as? ReactApplication ?: return
    val reactContext = app.reactHost?.currentReactContext ?: return
    val params = Arguments.createMap().apply {
      putString("action", action)
      putString("callUUID", uuid)
    }
    reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
        .emit(IncomingCallModule.EVENT_NAME, params)
  }
}
