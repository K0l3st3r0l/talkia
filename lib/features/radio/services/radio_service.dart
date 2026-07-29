import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import '../../../core/constants.dart';
import '../../../core/device_id.dart';
import '../../../core/log_service.dart';
import 'audio_service.dart';

enum RadioState { disconnected, connecting, connected, transmitting, receiving }

class RoomUser {
  final String id;
  final String name;
  final int build;

  const RoomUser({required this.id, required this.name, this.build = 0});

  bool get isOutdated => build > 0 && build < kAppBuild;
}

class RadioService {
  static const int _reconnectBaseMs = 1000;
  static const int _reconnectMaxMs = 30000;

  final AudioService _audio = AudioService();
  final math.Random _rand = math.Random();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  StreamSubscription? _connectivitySub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _connectivityDebounce;
  bool _pendingPong = false;
  bool _connectInFlight = false;
  int _reconnectAttempt = 0;

  String _roomCode = '';
  String _password = '';
  String _userName = '';
  String _clientId = '';
  int _userCount = 0;
  bool _disposed = false;
  bool muted = false;

  RadioState _state = RadioState.disconnected;

  final _stateCtrl = StreamController<RadioState>.broadcast();
  final _userCountCtrl = StreamController<int>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _usersCtrl = StreamController<List<RoomUser>>.broadcast();
  final _speakerCtrl = StreamController<String?>.broadcast();
  final _channelBusyCtrl = StreamController<String>.broadcast();

  // Mutable list tracked locally
  final List<RoomUser> _users = [];

  Stream<RadioState> get stateStream => _stateCtrl.stream;
  Stream<int> get userCountStream => _userCountCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;
  Stream<List<RoomUser>> get usersStream => _usersCtrl.stream;
  Stream<String?> get speakerStream => _speakerCtrl.stream;
  Stream<String> get channelBusyStream => _channelBusyCtrl.stream;
  RadioState get state => _state;
  int get userCount => _userCount;
  String get clientId => _clientId;

  Future<void> init() async {
    await _audio.init();
  }

  Future<bool> hasMicPermission() => _audio.hasMicPermission();

  Future<void> connect(String roomCode, {String password = '', String userName = ''}) async {
    _roomCode = roomCode.toUpperCase().trim();
    _password = password;
    _userName = userName.isNotEmpty ? userName : 'Usuario';
    _disposed = false;
    _reconnectAttempt = 0;
    if (_clientId.isEmpty) {
      try {
        _clientId = await loadClientId();
      } catch (e) {
        log.error('No se pudo leer client_id persistido', e);
      }
    }
    _startConnectivityListener();
    await _connect();
  }

  void _startConnectivityListener() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet);
      if (!hasNetwork || _disposed || _roomCode.isEmpty) return;
      // Debounce: connectivity fires multiple rapid events; wait for the last one
      _connectivityDebounce?.cancel();
      _connectivityDebounce = Timer(const Duration(milliseconds: 600), () {
        if (_disposed || _connectInFlight) return;
        log.info('Red cambiada — reconectando WebSocket');
        _pingTimer?.cancel();
        _wsSub?.cancel();
        try { _channel?.sink.close(); } catch (_) {}
        _channel = null;
        _setState(RadioState.disconnected);
        _scheduleReconnect(immediate: true);
      });
    });
  }

  Future<void> _connect() async {
    if (_connectInFlight || _disposed) return;
    _connectInFlight = true;
    _setState(RadioState.connecting);
    try {
      final params = <String, String>{
        'name': Uri.encodeComponent(_userName),
        'codec': 'opus',
        'build': kAppBuild.toString(),
      };
      if (_clientId.isNotEmpty) params['client_id'] = _clientId;
      if (_password.isNotEmpty) params['password'] = Uri.encodeComponent(_password);
      final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');
      final uri = Uri.parse('$kServerWsUrl/$_roomCode?$query');

      log.info('WS connecting → $uri');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready.timeout(const Duration(seconds: 10));

      _wsSub = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (e) {
          log.error('WS stream error', e);
          _onDisconnected();
        },
        cancelOnError: false,
      );

      log.info('WS connected');
      _reconnectAttempt = 0;
      _setState(RadioState.connected);
      _startPing();
    } catch (e) {
      log.error('WS connect failed', e);
      _setState(RadioState.disconnected);
      _scheduleReconnect();
    } finally {
      _connectInFlight = false;
    }
  }

  void _onMessage(dynamic data) {
    if (data is List<int> || data is Uint8List) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      log.info('audio bytes: ${bytes.length} state=$_state muted=$muted');
      if (_state != RadioState.transmitting) {
        _setState(RadioState.receiving);
        if (!muted) _audio.playChunk(bytes);
        Future.delayed(const Duration(milliseconds: 150), () {
          if (_state == RadioState.receiving) _setState(RadioState.connected);
        });
      }
    } else if (data is String) {
      try {
        final msg = jsonDecode(data) as Map<String, dynamic>;
        final type = msg['type'] as String? ?? '';
        switch (type) {
          case 'welcome':
            final you = msg['you'] as String?;
            if (you != null && you.isNotEmpty) _clientId = you;
            _applyRoster(msg);
            log.info('welcome: ${_users.map((u) => "${u.name}(b${u.build})").join(", ")}');

          case 'user_joined':
            _applyRoster(msg, fallbackJoined: msg['name'] as String?);
            log.info('user_joined: ${msg['name']}');

          case 'user_left':
            _applyRoster(msg, fallbackLeft: msg['name'] as String?);
            _speakerCtrl.add(null);
            log.info('user_left: ${msg['name']}');

          case 'ptt_start':
            if (_state != RadioState.transmitting) _setState(RadioState.receiving);
            final speaker = msg['name'] as String? ?? '';
            _speakerCtrl.add(speaker);
            log.info('ptt_start: $speaker');

          case 'ptt_end':
            if (_state == RadioState.receiving) _setState(RadioState.connected);
            _speakerCtrl.add(null);

          case 'channel_busy':
            final busyName = msg['name'] as String? ?? '';
            _channelBusyCtrl.add(busyName);
            log.warn('Canal ocupado — $busyName está hablando');

          case 'pong':
            _pendingPong = false;
            break;

          case 'error':
            final code = msg['code'] as String? ?? 'unknown';
            log.warn('WS error del servidor: $code');
            _disposed = true;
            _setState(RadioState.disconnected);
            _errorCtrl.add(code);
        }
      } catch (e) {
        log.error('WS msg parse error', e);
      }
    }
  }

  /// Aplica la foto completa del roster. Si el servidor no la manda (versión
  /// antigua), cae al modo incremental con el nombre del evento.
  void _applyRoster(Map<String, dynamic> msg, {String? fallbackJoined, String? fallbackLeft}) {
    final snapshot = _parseRoster(msg);
    if (snapshot != null) {
      _users
        ..clear()
        ..addAll(snapshot);
    } else if (fallbackJoined != null && fallbackJoined.isNotEmpty) {
      if (!_users.any((u) => u.name == fallbackJoined)) {
        _users.add(RoomUser(id: '', name: fallbackJoined));
      }
    } else if (fallbackLeft != null && fallbackLeft.isNotEmpty) {
      _users.removeWhere((u) => u.name == fallbackLeft);
    }

    _userCount = snapshot != null
        ? _users.length
        : ((msg['count'] as int?) ?? _users.length);
    _userCountCtrl.add(_userCount);
    _usersCtrl.add(List.unmodifiable(_users));
  }

  List<RoomUser>? _parseRoster(Map<String, dynamic> msg) {
    final roster = msg['roster'];
    if (roster is List) {
      return roster.whereType<Map>().map((e) => RoomUser(
            id: (e['id'] as String?) ?? '',
            name: (e['name'] as String?) ?? 'Usuario',
            build: (e['build'] as num?)?.toInt() ?? 0,
          )).toList();
    }
    final legacy = msg['users'];
    if (legacy is List) {
      return legacy.map((e) => RoomUser(id: '', name: e.toString())).toList();
    }
    return null;
  }

  void _onDisconnected() {
    log.warn('WS desconectado');
    _pingTimer?.cancel();
    _wsSub?.cancel();
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    _users.clear();
    _usersCtrl.add([]);
    _speakerCtrl.add(null);
    if (!_disposed) {
      _setState(RadioState.disconnected);
      _scheduleReconnect();
    }
  }

  /// Backoff exponencial con jitter (1s→30s). Un solo timer vivo a la vez: las
  /// llamadas concurrentes (stream onDone + onError + pong timeout) colapsan.
  void _scheduleReconnect({bool immediate = false}) {
    if (_disposed || _roomCode.isEmpty) return;
    if (immediate) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempt = 0;
    } else if (_reconnectTimer?.isActive ?? false) {
      return;
    }

    final base = math.min(_reconnectMaxMs, _reconnectBaseMs << math.min(_reconnectAttempt, 5));
    final delayMs = base ~/ 2 + _rand.nextInt(base ~/ 2 + 1);
    _reconnectAttempt++;
    log.info('Reconexión en ${delayMs}ms (intento $_reconnectAttempt)');

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (!_disposed && _roomCode.isNotEmpty) _connect();
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pendingPong = false;
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_pendingPong) {
        log.warn('Pong timeout — reconectando');
        _pingTimer?.cancel();
        _pendingPong = false;
        _onDisconnected();
        return;
      }
      _pendingPong = true;
      _sendText({'type': 'ping'});
    });
  }

  Future<void> startTransmitting() async {
    if (_state != RadioState.connected) {
      log.warn('startTransmitting ignorado — estado: $_state');
      return;
    }
    log.info('PTT start');
    _setState(RadioState.transmitting);
    _sendText({'type': 'ptt_start'});
    try {
      await _audio.startRecording((chunk) => _channel?.sink.add(chunk));
    } catch (e) {
      log.error('startRecording falló', e);
      _setState(RadioState.connected);
    }
  }

  Future<void> stopTransmitting() async {
    if (_state != RadioState.transmitting) {
      log.warn('stopTransmitting ignorado — estado: $_state');
      return;
    }
    log.info('PTT stop');
    try {
      await _audio.stopRecording();
    } catch (e) {
      log.error('stopRecording falló', e);
    }
    _sendText({'type': 'ptt_end'});
    _setState(RadioState.connected);
  }

  Future<void> setVolume(double level) async {
    await _audio.setVolume(level);
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
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _connectivityDebounce?.cancel();
    _connectivitySub?.cancel();
    _connectivitySub = null;
    try { await _audio.stopRecording(); } catch (_) {}
    try { await _wsSub?.cancel(); } catch (_) {}
    try {
      await _channel?.sink.close(ws_status.normalClosure)
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    _channel = null;
    _setState(RadioState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _stateCtrl.close();
    await _userCountCtrl.close();
    await _errorCtrl.close();
    await _usersCtrl.close();
    await _speakerCtrl.close();
    await _channelBusyCtrl.close();
    await _audio.dispose();
  }
}
