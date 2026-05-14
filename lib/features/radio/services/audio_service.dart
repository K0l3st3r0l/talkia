import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import '../../../core/log_service.dart';

class AudioService {
  static const _channel = MethodChannel('com.laravas.talkia/audio');

  final AudioRecorder _recorder = AudioRecorder();
  StreamController<Uint8List>? _outgoingAudio;

  Stream<Uint8List>? get outgoingStream => _outgoingAudio?.stream;

  Future<void> init() async {
    log.info('AudioService init');
    await _setSpeakerMode(true);
  }

  Future<bool> hasMicPermission() async {
    final ok = await _recorder.hasPermission();
    log.info('mic permission: $ok');
    return ok;
  }

  Future<void> startRecording(void Function(Uint8List chunk) onChunk) async {
    _outgoingAudio?.close();
    _outgoingAudio = StreamController<Uint8List>.broadcast();

    log.info('startStream PCM 16bit 16kHz mono');
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    log.info('startStream OK');

    stream.listen((chunk) {
      if (chunk.isNotEmpty) {
        onChunk(Uint8List.fromList(chunk));
      }
    });
  }

  Future<void> stopRecording() async {
    log.info('stopRecording');
    await _recorder.stop();
    await _outgoingAudio?.close();
    _outgoingAudio = null;
    log.info('stopRecording OK');
  }

  // Reproduce un chunk PCM via AudioTrack nativo — sin overhead de just_audio
  Future<void> playChunk(Uint8List pcmData) async {
    try {
      await _channel.invokeMethod('playPcmChunk', {'pcm': pcmData});
    } catch (e) {
      log.error('playChunk falló', e);
    }
  }

  Future<void> stopPlayback() async {
    try {
      await _channel.invokeMethod('stopPlayback');
    } catch (_) {}
  }

  Future<void> setVolume(double level) async {
    try {
      await _channel.invokeMethod('setVolume', {'level': level.clamp(0.0, 1.0)});
    } catch (e) {
      log.warn('setVolume falló: $e');
    }
  }

  Future<void> _setSpeakerMode(bool speaker) async {
    try {
      await _channel.invokeMethod('setSpeakerMode', {'enabled': speaker});
      log.info('speaker mode: $speaker');
    } catch (e) {
      log.warn('setSpeakerMode falló: $e');
    }
  }

  Future<void> dispose() async {
    await _recorder.dispose();
    await _outgoingAudio?.close();
    await stopPlayback();
  }
}
