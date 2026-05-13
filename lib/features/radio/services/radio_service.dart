import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import '../../../core/constants.dart';
import 'audio_service.dart';

enum RadioState { disconnected, connecting, connected, transmitting, receiving }

class RadioService {
  final AudioService _audio = AudioService();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;

  String _roomCode = '';
  int _userCount = 0;
  bool _disposed = false;

  RadioState _state = RadioState.disconnected;

  final _stateCtrl = StreamController<RadioState>.broadcast();
  final _userCountCtrl = StreamController<int>.broadcast();

  Stream<RadioState> get stateStream => _stateCtrl.stream;
  Stream<int> get userCountStream => _userCountCtrl.stream;
  RadioState get state => _state;
  int get userCount => _userCount;

  Future<void> init() async {
    await _audio.init();
  }

  Future<bool> hasMicPermission() => _audio.hasMicPermission();

  Future<void> connect(String roomCode) async {
    _roomCode = roomCode.toUpperCase().trim();
    _disposed = false;
    await _connect();
  }

  Future<void> _connect() async {
    _setState(RadioState.connecting);
    try {
      final uri = Uri.parse('$kServerWsUrl/${_roomCode}');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _wsSub = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: false,
      );

      _setState(RadioState.connected);
      _startPing();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    if (data is List<int> || data is Uint8List) {
      // Audio recibido → reproducir
      if (_state != RadioState.transmitting) {
        _setState(RadioState.receiving);
        _audio.playChunk(Uint8List.fromList(data as List<int>));
        // Volver a "connected" después de un breve tiempo
        Future.delayed(const Duration(milliseconds: 150), () {
          if (_state == RadioState.receiving) {
            _setState(RadioState.connected);
          }
        });
      }
    } else if (data is String) {
      try {
        final msg = jsonDecode(data) as Map<String, dynamic>;
        final type = msg['type'] as String? ?? '';
        switch (type) {
          case 'welcome':
          case 'user_joined':
          case 'user_left':
            _userCount = (msg['count'] as int?) ?? _userCount;
            _userCountCtrl.add(_userCount);
          case 'ptt_start':
            if (_state != RadioState.transmitting) {
              _setState(RadioState.receiving);
            }
          case 'ptt_end':
            if (_state == RadioState.receiving) {
              _setState(RadioState.connected);
            }
          case 'pong':
            break;
        }
      } catch (_) {}
    }
  }

  void _onDisconnected() {
    _pingTimer?.cancel();
    _wsSub?.cancel();
    if (!_disposed) {
      _setState(RadioState.disconnected);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_disposed && _roomCode.isNotEmpty) {
        _connect();
      }
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _sendText({'type': 'ping'});
    });
  }

  Future<void> startTransmitting() async {
    if (_state != RadioState.connected) return;
    _setState(RadioState.transmitting);
    _sendText({'type': 'ptt_start'});
    await _audio.startRecording((chunk) {
      _channel?.sink.add(chunk);
    });
  }

  Future<void> stopTransmitting() async {
    if (_state != RadioState.transmitting) return;
    await _audio.stopRecording();
    _sendText({'type': 'ptt_end'});
    _setState(RadioState.connected);
  }

  void _sendText(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void _setState(RadioState newState) {
    _state = newState;
    _stateCtrl.add(newState);
  }

  Future<void> disconnect() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    await _audio.stopRecording();
    await _wsSub?.cancel();
    await _channel?.sink.close(ws_status.normalClosure);
    _setState(RadioState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _stateCtrl.close();
    await _userCountCtrl.close();
    await _audio.dispose();
  }
}
