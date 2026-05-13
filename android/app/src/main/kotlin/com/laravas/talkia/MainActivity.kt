package com.laravas.talkia

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.laravas.talkia/audio"
        ).setMethodCallHandler { call, result ->
            if (call.method == "setSpeakerMode") {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.mode = if (enabled) AudioManager.MODE_IN_COMMUNICATION else AudioManager.MODE_NORMAL
                am.isSpeakerphoneOn = enabled
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
