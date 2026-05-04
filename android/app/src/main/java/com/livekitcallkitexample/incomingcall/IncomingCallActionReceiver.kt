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
