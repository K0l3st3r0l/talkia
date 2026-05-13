import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/log_service.dart';
import '../../debug/log_screen.dart';
import '../../ota_update/ota_service.dart';
import 'radio_screen.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  bool _checkingOta = false;
  String _version = '';
  int _logoTaps = 0;

  @override
  void initState() {
    super.initState();
    _loadLastRoom();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final v = await OtaService.currentVersion;
    if (mounted) setState(() => _version = v);
  }

  void _onLogoTap() {
    _logoTaps++;
    if (_logoTaps >= 3) {
      _logoTaps = 0;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LogScreen()));
    }
  }

  Future<void> _checkOta() async {
    if (_checkingOta) return;
    setState(() => _checkingOta = true);
    log.info('verificación OTA manual');
    try {
      final result = await OtaService().checkForUpdate();
      if (!mounted) return;
      if (result == null) {
        _showSnack('No se pudo verificar actualizaciones', isError: true);
        return;
      }
      if (!result.hasUpdate) {
        _showSnack('Ya tienes la versión más reciente (build ${result.localBuild})');
        return;
      }
      _showSnack('Nueva versión disponible (build ${result.serverBuild}), descargando…');
      await OtaService().downloadAndInstall(result.apkUrl);
    } catch (e) {
      if (mounted) _showSnack('Error al actualizar: $e', isError: true);
    } finally {
      if (mounted) setState(() => _checkingOta = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? AppTheme.transmitColor : null,
    ));
  }

  Future<void> _loadLastRoom() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('last_room') ?? '';
    if (last.isNotEmpty) {
      _ctrl.text = last;
    }
  }

  Future<void> _join() async {
    final code = _ctrl.text.trim().toUpperCase();
    if (code.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_room', code);

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RadioScreen(roomCode: code)),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo / icono — triple-tap abre consola de logs
                GestureDetector(
                  onTap: _onLogoTap,
                  child: Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.surface,
                      border: Border.all(color: AppTheme.accent, width: 2),
                    ),
                    child: const Icon(Icons.radio, color: AppTheme.accent, size: 44),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'TalkIA',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Walkie-talkie digital',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  _version,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                const SizedBox(height: 56),
                TextField(
                  controller: _ctrl,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(12),
                  ],
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    letterSpacing: 6,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'CÓDIGO DE SALA',
                    hintStyle: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                      letterSpacing: 3,
                    ),
                    filled: true,
                    fillColor: AppTheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.idleColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.accent, width: 2),
                    ),
                  ),
                  onSubmitted: (_) => _join(),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _join,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'CONECTAR',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 3,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Todos los dispositivos en el mismo código\npueden escucharse entre sí',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: _checkingOta ? null : _checkOta,
                  icon: _checkingOta
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textSecondary),
                        )
                      : const Icon(Icons.system_update_alt, size: 16, color: AppTheme.textSecondary),
                  label: const Text(
                    'BUSCAR ACTUALIZACIÓN',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, letterSpacing: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
