import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';

class AudioService {
  static const _channel = MethodChannel('com.laravas.talkia/audio');

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<RecordState>? _stateSub;
  StreamController<Uint8List>? _outgoingAudio;

  Stream<Uint8List>? get outgoingStream => _outgoingAudio?.stream;

  Future<void> init() async {
    await _setSpeakerMode(true);
  }

  Future<bool> hasMicPermission() async {
    return await _recorder.hasPermission();
  }

  Future<void> startRecording(void Function(Uint8List chunk) onChunk) async {
    _outgoingAudio?.close();
    _outgoingAudio = StreamController<Uint8List>.broadcast();

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );

    stream.listen((chunk) {
      if (chunk.isNotEmpty) {
        onChunk(Uint8List.fromList(chunk));
      }
    });
  }

  Future<void> stopRecording() async {
    await _recorder.stop();
    await _outgoingAudio?.close();
    _outgoingAudio = null;
  }

  Future<void> playChunk(Uint8List pcmData) async {
    // Reproducir PCM raw a través de just_audio usando StreamAudioSource
    // Para simplicidad en v1, usamos un buffer en memoria
    try {
      final source = _PcmStreamSource(pcmData);
      await _player.setAudioSource(source);
      await _player.play();
    } catch (_) {}
  }

  Future<void> _setSpeakerMode(bool speaker) async {
    try {
      await _channel.invokeMethod('setSpeakerMode', {'enabled': speaker});
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _stateSub?.cancel();
    await _recorder.dispose();
    await _player.dispose();
    await _outgoingAudio?.close();
  }
}

// AudioSource que sirve PCM raw envuelto en WAV para just_audio
class _PcmStreamSource extends StreamAudioSource {
  final Uint8List _pcm;

  _PcmStreamSource(this._pcm);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final wav = _buildWav(_pcm, 16000, 1, 16);
    start ??= 0;
    end ??= wav.length;
    return StreamAudioResponse(
      sourceLength: wav.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(wav.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }

  Uint8List _buildWav(Uint8List pcm, int sampleRate, int channels, int bitsPerSample) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = pcm.length;
    final header = ByteData(44);

    // RIFF header
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    // fmt chunk
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // (space)
    header.setUint32(16, 16, Endian.little); // PCM chunk size
    header.setUint16(20, 1, Endian.little);  // PCM format
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data chunk
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataSize, Endian.little);

    final wav = Uint8List(44 + dataSize);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, 44 + dataSize, pcm);
    return wav;
  }
}
