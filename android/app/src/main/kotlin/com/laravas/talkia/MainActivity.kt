package com.laravas.talkia

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var audioTrack: AudioTrack? = null
    private val sampleRate = 16000

    private fun ensureAudioTrack() {
        if (audioTrack?.state == AudioTrack.STATE_INITIALIZED) return
        val bufferSize = maxOf(
            AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT),
            8192
        )
        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize * 4)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audioTrack?.play()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.laravas.talkia/audio"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSpeakerMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    am.mode = if (enabled) AudioManager.MODE_IN_COMMUNICATION else AudioManager.MODE_NORMAL
                    am.isSpeakerphoneOn = enabled
                    result.success(null)
                }
                "playPcmChunk" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm != null) {
                        ensureAudioTrack()
                        audioTrack?.write(pcm, 0, pcm.size)
                        result.success(null)
                    } else {
                        result.error("NO_DATA", "pcm is null", null)
                    }
                }
                "stopPlayback" -> {
                    audioTrack?.pause()
                    audioTrack?.flush()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
        super.onDestroy()
    }
}
