package com.laravas.talkia

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.database.ContentObserver
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var audioTrack: AudioTrack? = null
    private val sampleRate = 16000
    private var currentVolume: Float = 1.0f

    private var methodChannel: MethodChannel? = null
    private var volumeObserver: ContentObserver? = null
    private var lastReportedVolume: Float = -1f

    // Volumen de medios del sistema, normalizado 0..1
    private fun systemVolume(): Float {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return 0f
        return am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max
    }

    // Los botones físicos de volumen no pasan por la app. Sin observer, el
    // aviso de "volumen bajo" quedaría mostrando un valor viejo justo cuando
    // el usuario acaba de corregirlo.
    private fun registerVolumeObserver() {
        if (volumeObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                val vol = systemVolume()
                if (vol == lastReportedVolume) return
                lastReportedVolume = vol
                methodChannel?.invokeMethod("onSystemVolumeChanged", vol.toDouble())
            }
        }
        contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI, true, observer
        )
        volumeObserver = observer
    }

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

    @Suppress("DEPRECATION")
    private fun releaseBluetoothSco() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            // startBluetoothSco() sigue siendo lo que usa el plugin `record`
            // incluso en API 31+, así que hay que apagarlo por la misma vía.
            if (am.isBluetoothScoOn) {
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                am.clearCommunicationDevice()
            }
            if (am.mode != AudioManager.MODE_NORMAL) {
                am.mode = AudioManager.MODE_NORMAL
            }
        } catch (e: Exception) {
            android.util.Log.w("TalkIA", "releaseBluetoothSco: ${e.message}")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.laravas.talkia/audio"
        )
        methodChannel = channel
        registerVolumeObserver()

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setSpeakerMode" -> {
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    am.mode = AudioManager.MODE_NORMAL
                    am.isSpeakerphoneOn = false
                    currentVolume = 1.0f
                    result.success(null)
                }
                // Devuelve el enlace Bluetooth a A2DP. Sin esto, un SCO abierto
                // deja todo el audio del sistema en calidad de llamada (mono,
                // 8-16 kHz) mientras la app esté viva.
                "releaseBluetoothSco" -> {
                    releaseBluetoothSco()
                    result.success(null)
                }
                "getVolume" -> {
                    val vol = systemVolume()
                    lastReportedVolume = vol
                    currentVolume = vol
                    result.success(vol.toDouble())
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
                    lastReportedVolume = systemVolume()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        volumeObserver?.let { contentResolver.unregisterContentObserver(it) }
        volumeObserver = null
        methodChannel = null
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
        super.onDestroy()
    }
}
