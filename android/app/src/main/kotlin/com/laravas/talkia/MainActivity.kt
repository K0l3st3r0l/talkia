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
    private var currentVolume: Float = 1.0f

    private fun buildAudioTrack(): AudioTrack {
        val bufferSize = maxOf(
            AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT),
            8192
        )
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
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
    }

    // Garantiza que el AudioTrack existe y está reproduciendo
    private fun ensurePlaying() {
        val track = audioTrack
        if (track != null && track.state == AudioTrack.STATE_INITIALIZED) {
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                track.play()
            }
            return
        }
        track?.release()
        audioTrack = buildAudioTrack().also {
            it.setVolume(currentVolume)
            it.play()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.laravas.talkia/audio"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSpeakerMode" -> {
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    am.mode = AudioManager.MODE_NORMAL
                    am.isSpeakerphoneOn = false
                    // Forzar volumen de medios al máximo al iniciar
                    val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, maxVol, 0)
                    currentVolume = 1.0f
                    result.success(null)
                }
                "playPcmChunk" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm != null) {
                        ensurePlaying()
                        val track = audioTrack
                        if (track != null) {
                            val written = track.write(pcm, 0, pcm.size)
                            if (written < 0) {
                                android.util.Log.e("TalkIA", "AudioTrack.write error: $written state=${track.state} playState=${track.playState}")
                            }
                        }
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
                "setVolume" -> {
                    val level = (call.argument<Double>("level") ?: 1.0).toFloat()
                    currentVolume = level.coerceIn(0f, 1f)
                    // Controlar volumen de medios del sistema para que el slider esté sincronizado
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, (currentVolume * maxVol).toInt(), 0)
                    audioTrack?.setVolume(1.0f)
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
