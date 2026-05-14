import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart';
import '../../../core/log_service.dart';

class AudioService {
  static const _channel = MethodChannel('com.laravas.talkia/audio');
  static const _sampleRate = 16000;
  // 20ms frame at 16kHz mono = 320 samples = 640 bytes
  static const _frameSamples = 320;
  static const _frameSizeBytes = _frameSamples * 2;

  final AudioRecorder _recorder = AudioRecorder();
  StreamController<Uint8List>? _outgoingAudio;

  SimpleOpusEncoder? _encoder;
  SimpleOpusDecoder? _decoder;
  final _encodeBuffer = <int>[];

  Stream<Uint8List>? get outgoingStream => _outgoingAudio?.stream;

  Future<void> init() async {
    log.info('AudioService init');
    final lib = await opus_flutter.load() as DynamicLibrary;
    initOpus(lib);
    _encoder = SimpleOpusEncoder(
      sampleRate: _sampleRate,
      channels: 1,
      application: Application.voip,
    );
    _decoder = SimpleOpusDecoder(sampleRate: _sampleRate, channels: 1);
    log.info('Opus encoder/decoder inicializados');
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
    _encodeBuffer.clear();

    log.info('startStream PCM 16bit 16kHz mono → encode Opus');
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
    );
    log.info('startStream OK');

    stream.listen((chunk) {
      if (chunk.isEmpty) return;
      _encodeBuffer.addAll(chunk);

      while (_encodeBuffer.length >= _frameSizeBytes) {
        final frameBytes = Uint8List.fromList(
          _encodeBuffer.sublist(0, _frameSizeBytes),
        );
        _encodeBuffer.removeRange(0, _frameSizeBytes);

        try {
          final pcmInt16 = frameBytes.buffer.asInt16List();
          final opusPacket = _encoder!.encode(input: pcmInt16);
          if (opusPacket.isNotEmpty) onChunk(opusPacket);
        } catch (e) {
          log.error('Opus encode error', e);
        }
      }
    });
  }

  Future<void> stopRecording() async {
    log.info('stopRecording');
    await _recorder.stop();
    await _outgoingAudio?.close();
    _outgoingAudio = null;
    _encodeBuffer.clear();
    log.info('stopRecording OK');
  }

  Future<void> playChunk(Uint8List opusData) async {
    try {
      final pcmInt16 = _decoder!.decode(input: opusData);
      final pcmBytes = pcmInt16.buffer.asUint8List(
        pcmInt16.offsetInBytes,
        pcmInt16.lengthInBytes,
      );
      await _channel.invokeMethod('playPcmChunk', {'pcm': pcmBytes});
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
    _encoder?.destroy();
    _decoder?.destroy();
  }
}
