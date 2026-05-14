import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/log_service.dart';
import '../../debug/log_screen.dart';
import '../services/radio_service.dart';

class RadioScreen extends StatefulWidget {
  final String roomCode;
  final String password;
  final String userName;

  const RadioScreen({
    super.key,
    required this.roomCode,
    this.password = '',
    this.userName = '',
  });

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> with TickerProviderStateMixin {
  final RadioService _radio = RadioService();

  RadioState _state = RadioState.disconnected;
  int _userCount = 0;
  List<String> _users = [];
  String? _speaker;
  int _roomCodeTaps = 0;
  bool _muted = false;
  double _volume = 1.0;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _waveCtrl;

  StreamSubscription? _stateSub;
  StreamSubscription? _countSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _usersSub;
  StreamSubscription? _speakerSub;

  bool _hasMicPermission = false;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _init();
  }

  void _onRoomCodeTap() {
    _roomCodeTaps++;
    if (_roomCodeTaps >= 3) {
      _roomCodeTaps = 0;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LogScreen()));
    }
  }

  Future<void> _init() async {
    log.info('RadioScreen init — sala: ${widget.roomCode}');
    await _radio.init();

    final status = await Permission.microphone.request();
    _hasMicPermission = status.isGranted;

    _stateSub = _radio.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _countSub = _radio.userCountStream.listen((c) {
      if (mounted) setState(() => _userCount = c);
    });
    _usersSub = _radio.usersStream.listen((u) {
      if (mounted) setState(() => _users = u);
    });
    _speakerSub = _radio.speakerStream.listen((s) {
      if (mounted) setState(() => _speaker = s);
    });
    _errorSub = _radio.errorStream.listen((code) {
      if (!mounted) return;
      const msg = 'Sala nueva — se requiere contraseña de administrador para crearla';
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(msg), backgroundColor: AppTheme.transmitColor),
      );
      Navigator.of(context).pop();
    });

    await _radio.connect(
      widget.roomCode,
      password: widget.password,
      userName: widget.userName,
    );

    try {
      await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'TalkIA — Sala ${widget.roomCode}',
        notificationText: 'Conectado y escuchando',
      );
    } catch (e) {
      log.warn('foreground service no pudo iniciar: $e');
    }
  }

  Future<bool> _confirmExit() async {
    if (_state == RadioState.disconnected) return true;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('¿Salir de la sala?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Hay $_userCount ${_userCount == 1 ? 'usuario' : 'usuarios'} en la sala. ¿Confirmas que quieres salir?',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCELAR',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('SALIR',
                style: TextStyle(color: AppTheme.transmitColor)),
          ),
        ],
      ),
    );
    return confirm ?? false;
  }

  Future<void> _onPttStart() async {
    if (!_hasMicPermission) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Permiso de micrófono requerido'),
          backgroundColor: AppTheme.transmitColor,
        ),
      );
      return;
    }
    await _radio.startTransmitting();
  }

  Future<void> _onPttEnd() async {
    await _radio.stopTransmitting();
  }

  Color get _buttonColor {
    switch (_state) {
      case RadioState.transmitting:
        return AppTheme.transmitColor;
      case RadioState.receiving:
        return AppTheme.receiveColor;
      case RadioState.connected:
        return AppTheme.accent;
      default:
        return AppTheme.idleColor;
    }
  }

  String get _statusLabel {
    switch (_state) {
      case RadioState.disconnected:
        return 'DESCONECTADO';
      case RadioState.connecting:
        return 'CONECTANDO...';
      case RadioState.connected:
        return 'LISTO';
      case RadioState.transmitting:
        return 'TRANSMITIENDO';
      case RadioState.receiving:
        return _speaker != null && _speaker!.isNotEmpty
            ? _speaker!.toUpperCase()
            : 'RECIBIENDO';
    }
  }

  bool get _isActive =>
      _state == RadioState.transmitting || _state == RadioState.receiving;

  @override
  void dispose() {
    FlutterForegroundTask.stopService();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _stateSub?.cancel();
    _countSub?.cancel();
    _errorSub?.cancel();
    _usersSub?.cancel();
    _speakerSub?.cancel();
    _radio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmExit()) {
          await _radio.disconnect();
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.surface,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: AppTheme.textSecondary),
            onPressed: () async {
              if (await _confirmExit()) {
                await _radio.disconnect();
                if (mounted) Navigator.of(context).pop();
              }
            },
          ),
          title: GestureDetector(
            onTap: _onRoomCodeTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'SALA ',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, letterSpacing: 2),
                    ),
                    Text(
                      widget.roomCode,
                      style: const TextStyle(
                        color: AppTheme.accent,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 3,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              icon: Icon(
                _muted ? Icons.volume_off : Icons.volume_up,
                color: _muted ? AppTheme.transmitColor : AppTheme.textSecondary,
                size: 20,
              ),
              onPressed: () {
                setState(() => _muted = !_muted);
                _radio.muted = _muted;
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(
                children: [
                  Icon(Icons.people, size: 14,
                    color: _userCount > 1 ? AppTheme.receiveColor : AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    '$_userCount',
                    style: TextStyle(
                      color: _userCount > 1 ? AppTheme.receiveColor : AppTheme.textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // Status bar
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: AppTheme.surface,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 8, height: 8,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: _buttonColor),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _state == RadioState.receiving && _speaker != null
                          ? 'HABLANDO: $_statusLabel'
                          : _statusLabel,
                      style: TextStyle(
                        color: _buttonColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Lista de usuarios conectados
            if (_users.isNotEmpty)
              Container(
                width: double.infinity,
                color: AppTheme.background,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _users.map((name) {
                      final isSpeaker = name == _speaker;
                      final isMe = name == widget.userName;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSpeaker
                                ? AppTheme.receiveColor.withOpacity(0.2)
                                : AppTheme.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSpeaker
                                  ? AppTheme.receiveColor
                                  : isMe
                                      ? AppTheme.accent.withOpacity(0.5)
                                      : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isSpeaker) ...[
                                const Icon(Icons.mic, size: 12, color: AppTheme.receiveColor),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                isMe ? '$name (tú)' : name,
                                style: TextStyle(
                                  color: isSpeaker
                                      ? AppTheme.receiveColor
                                      : isMe
                                          ? AppTheme.accent
                                          : AppTheme.textSecondary,
                                  fontSize: 12,
                                  fontWeight: isSpeaker ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),

            // Main area con botón PTT
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isActive)
                      AnimatedBuilder(
                        animation: _waveCtrl,
                        builder: (_, __) => CustomPaint(
                          size: const Size(220, 220),
                          painter: _WavePainter(_waveCtrl.value, _buttonColor),
                        ),
                      ),

                    Listener(
                      onPointerDown: (_) => _onPttStart(),
                      onPointerUp: (_) => _onPttEnd(),
                      onPointerCancel: (_) => _onPttEnd(),
                      child: AnimatedBuilder(
                        animation: _pulseAnim,
                        builder: (_, child) => Transform.scale(
                          scale: _state == RadioState.transmitting ? _pulseAnim.value : 1.0,
                          child: child,
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 160, height: 160,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _buttonColor.withOpacity(0.15),
                            border: Border.all(color: _buttonColor, width: _isActive ? 4 : 2),
                            boxShadow: _isActive
                                ? [BoxShadow(color: _buttonColor.withOpacity(0.4), blurRadius: 30, spreadRadius: 8)]
                                : [],
                          ),
                          child: Icon(
                            _state == RadioState.transmitting
                                ? Icons.mic
                                : _state == RadioState.receiving
                                    ? Icons.volume_up
                                    : Icons.mic_none,
                            color: _buttonColor,
                            size: 72,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 40),

                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _state == RadioState.connected ? 1.0 : 0.0,
                      child: const Column(
                        children: [
                          Icon(Icons.touch_app, color: AppTheme.textSecondary, size: 20),
                          SizedBox(height: 8),
                          Text(
                            'PRESIONA PARA HABLAR',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, letterSpacing: 2),
                          ),
                        ],
                      ),
                    ),

                    if (_state == RadioState.transmitting)
                      const Text(
                        'SUELTA PARA TERMINAR',
                        style: TextStyle(color: AppTheme.transmitColor, fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.bold),
                      ),

                    if (_state == RadioState.receiving && _speaker != null)
                      Text(
                        '${_speaker!.toUpperCase()} ESTÁ HABLANDO',
                        style: const TextStyle(color: AppTheme.receiveColor, fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.bold),
                      )
                    else if (_state == RadioState.receiving)
                      const Text(
                        'ESCUCHANDO...',
                        style: TextStyle(color: AppTheme.receiveColor, fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.bold),
                      ),
                  ],
                ),
              ),
            ),

            // Control de volumen
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  const Icon(Icons.volume_down, color: AppTheme.textSecondary, size: 18),
                  Expanded(
                    child: Slider(
                      value: _volume,
                      min: 0.0,
                      max: 1.0,
                      onChanged: (v) {
                        setState(() => _volume = v);
                        _radio.setVolume(v);
                      },
                      activeColor: AppTheme.accent,
                      inactiveColor: AppTheme.surface,
                    ),
                  ),
                  const Icon(Icons.volume_up, color: AppTheme.textSecondary, size: 18),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${(_volume * 100).round()}%',
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),

            // Footer
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _userCount == 1 ? 'Solo tú en la sala' : '$_userCount usuarios conectados',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double progress;
  final Color color;
  _WavePainter(this.progress, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    for (int i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1.0;
      final radius = 80.0 + phase * 60;
      final opacity = (1 - phase) * 0.5;
      if (opacity <= 0) continue;
      final paint = Paint()
        ..color = color.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.progress != progress;
}
