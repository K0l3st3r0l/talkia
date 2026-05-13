import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/theme/app_theme.dart';
import '../services/radio_service.dart';

class RadioScreen extends StatefulWidget {
  final String roomCode;
  const RadioScreen({super.key, required this.roomCode});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen>
    with TickerProviderStateMixin {
  final RadioService _radio = RadioService();

  RadioState _state = RadioState.disconnected;
  int _userCount = 0;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _waveCtrl;

  StreamSubscription? _stateSub;
  StreamSubscription? _countSub;

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

  Future<void> _init() async {
    await _radio.init();

    // Verificar permiso de micrófono
    final status = await Permission.microphone.request();
    _hasMicPermission = status.isGranted;

    _stateSub = _radio.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _countSub = _radio.userCountStream.listen((c) {
      if (mounted) setState(() => _userCount = c);
    });

    if (_hasMicPermission) {
      await _radio.connect(widget.roomCode);
    }
  }

  Future<void> _onPttStart() async {
    if (!_hasMicPermission) {
      _showPermissionDenied();
      return;
    }
    await _radio.startTransmitting();
  }

  Future<void> _onPttEnd() async {
    await _radio.stopTransmitting();
  }

  void _showPermissionDenied() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Permiso de micrófono requerido'),
        backgroundColor: AppTheme.transmitColor,
      ),
    );
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
        return 'RECIBIENDO';
    }
  }

  bool get _isActive =>
      _state == RadioState.transmitting || _state == RadioState.receiving;

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _stateSub?.cancel();
    _countSub?.cancel();
    _radio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppTheme.textSecondary),
          onPressed: () async {
            await _radio.disconnect();
            if (mounted) Navigator.of(context).pop();
          },
        ),
        title: Column(
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Icon(
                  Icons.people,
                  size: 14,
                  color: _userCount > 1 ? AppTheme.receiveColor : AppTheme.textSecondary,
                ),
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
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _buttonColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _statusLabel,
                    style: TextStyle(
                      color: _buttonColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 3,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Main area con botón PTT
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Ondas animadas alrededor del botón
                  if (_isActive)
                    AnimatedBuilder(
                      animation: _waveCtrl,
                      builder: (_, __) => CustomPaint(
                        size: const Size(220, 220),
                        painter: _WavePainter(_waveCtrl.value, _buttonColor),
                      ),
                    ),

                  // Botón PTT
                  GestureDetector(
                    onLongPressStart: (_) => _onPttStart(),
                    onLongPressEnd: (_) => _onPttEnd(),
                    child: AnimatedBuilder(
                      animation: _pulseAnim,
                      builder: (_, child) {
                        final scale = _state == RadioState.transmitting
                            ? _pulseAnim.value
                            : 1.0;
                        return Transform.scale(
                          scale: scale,
                          child: child,
                        );
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _buttonColor.withOpacity(0.15),
                          border: Border.all(
                            color: _buttonColor,
                            width: _isActive ? 4 : 2,
                          ),
                          boxShadow: _isActive
                              ? [
                                  BoxShadow(
                                    color: _buttonColor.withOpacity(0.4),
                                    blurRadius: 30,
                                    spreadRadius: 8,
                                  )
                                ]
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

                  // Instrucción
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 300),
                    opacity: _state == RadioState.connected ? 1.0 : 0.0,
                    child: Column(
                      children: [
                        const Icon(Icons.touch_app, color: AppTheme.textSecondary, size: 20),
                        const SizedBox(height: 8),
                        const Text(
                          'MANTÉN PRESIONADO PARA HABLAR',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (_state == RadioState.transmitting)
                    const Text(
                      'SUELTA PARA TERMINAR',
                      style: TextStyle(
                        color: AppTheme.transmitColor,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                  if (_state == RadioState.receiving)
                    const Text(
                      'ESCUCHANDO...',
                      style: TextStyle(
                        color: AppTheme.receiveColor,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Footer
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Text(
              _userCount == 1
                  ? 'Solo tú en la sala'
                  : '$_userCount usuarios conectados',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        ],
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
