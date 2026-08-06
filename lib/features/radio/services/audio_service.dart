import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/log_service.dart';

class AudioService {
  static const _channel = MethodChannel('com.laravas.talkia/audio');
  static const _sampleRate = 16000;
  // 20ms frame at 16kHz mono = 320 samples = 640 bytes
  static const _frameSamples = 320;
  static const _frameSizeBytes = _frameSamples * 2;

  static const prefUseBluetoothMic = 'use_bluetooth_mic';

  // El plugin `record` trae manageBluetooth=true por defecto: al crear el
  // recorder nativo levanta Bluetooth SCO (HFP) y saca el enlace de A2DP,
  // dejando *todo* el audio del teléfono en calidad de llamada mientras la
  // app viva. Por defecto lo apagamos; quien quiera hablar por el micrófono
  // del manos libres lo activa y acepta el costo.
  bool _useBluetoothMic = false;
  bool get useBluetoothMic => _useBluetoothMic;

  AudioRecorder _recorder = AudioRecorder();
  StreamController<Uint8List>? _outgoingAudio;
  StreamSubscription? _recordSub;

  // El volumen de medios lo puede cambiar cualquiera desde los botones
  // físicos, así que la UI se entera por acá y no por lo último que ella misma
  // haya seteado.
  final _systemVolumeCtrl = StreamController<double>.broadcast();
  Stream<double> get systemVolumeStream => _systemVolumeCtrl.stream;

  SimpleOpusEncoder? _encoder;
  SimpleOpusDecoder? _decoder;
  final _encodeBuffer = <int>[];

  Stream<Uint8List>? get outgoingStream => _outgoingAudio?.stream;

  Future<void> init() async {
    log.info('AudioService init');
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSystemVolumeChanged') {
        final level = (call.arguments as num).toDouble();
        if (!_systemVolumeCtrl.isClosed) _systemVolumeCtrl.add(level);
      }
    });
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

    final prefs = await SharedPreferences.getInstance();
    _useBluetoothMic = prefs.getBool(prefUseBluetoothMic) ?? false;
    log.info('mic bluetooth: $_useBluetoothMic');
    // Limpia un SCO que haya quedado colgado de una sesión anterior.
    if (!_useBluetoothMic) await _releaseBluetoothSco();
  }

  /// Cambia el origen del micrófono. El plugin decide si maneja SCO al crear
  /// el recorder nativo, y eso ocurre una sola vez por instancia — hay que
  /// rehacerla para que el cambio tome efecto sin reiniciar la app.
  Future<void> setUseBluetoothMic(bool enabled) async {
    if (_useBluetoothMic == enabled) return;
    _useBluetoothMic = enabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefUseBluetoothMic, enabled);

    await _recordSub?.cancel();
    _recordSub = null;
    try {
      await _recorder.dispose();
    } catch (e) {
      log.warn('dispose del recorder falló al cambiar mic: $e');
    }
    _recorder = AudioRecorder();

    if (!enabled) await _releaseBluetoothSco();
    log.info('mic bluetooth: $enabled');
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
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(
          manageBluetooth: _useBluetoothMic,
        ),
      ),
    );
    log.info('startStream OK');

    _recordSub = stream.listen((chunk) {
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
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.stop();
    await _outgoingAudio?.close();
    _outgoingAudio = null;
    _encodeBuffer.clear();
    // El plugin solo apaga SCO en dispose()/cancel(), nunca en stop(). Red de
    // seguridad para equipos donde algo más lo dejó activo.
    if (!_useBluetoothMic) await _releaseBluetoothSco();
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

  /// Volumen de medios del sistema, 0..1. Ya no lo forzamos al máximo al
  /// abrir, así que hay que leerlo para saber si el usuario va a escuchar.
  Future<double> getVolume() async {
    try {
      final level = await _channel.invokeMethod<double>('getVolume');
      return (level ?? 1.0).clamp(0.0, 1.0);
    } catch (e) {
      log.warn('getVolume falló: $e');
      return 1.0;
    }
  }

  Future<void> setVolume(double level) async {
    try {
      await _channel.invokeMethod('setVolume', {'level': level.clamp(0.0, 1.0)});
    } catch (e) {
      log.warn('setVolume falló: $e');
    }
  }

  Future<void> _releaseBluetoothSco() async {
    try {
      await _channel.invokeMethod('releaseBluetoothSco');
    } catch (e) {
      log.warn('releaseBluetoothSco falló: $e');
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
    _channel.setMethodCallHandler(null);
    await _systemVolumeCtrl.close();
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.dispose();
    await _outgoingAudio?.close();
    await stopPlayback();
    _encoder?.destroy();
    _decoder?.destroy();
  }
}
