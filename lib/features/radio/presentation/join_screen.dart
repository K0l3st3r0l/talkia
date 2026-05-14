import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
  final _nameCtrl = TextEditingController();
  final _roomCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _checkingOta = false;
  bool _downloadingForced = false;
  double? _downloadProgress;
  String _version = '';
  int _logoTaps = 0;

  static const _defaultRoom = '76961';

  bool get _needsPassword =>
      _roomCtrl.text.trim().toUpperCase() != _defaultRoom &&
      _roomCtrl.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _roomCtrl.addListener(() => setState(() {}));
    _loadPrefs();
    _loadVersion();
    _autoCheckForced();
    _checkBatteryOptimization();
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

  Future<void> _checkBatteryOptimization() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('battery_opt_asked') == true) return;
      final isIgnoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (isIgnoring) return;
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Row(
            children: [
              Icon(Icons.battery_saver, color: AppTheme.accent),
              SizedBox(width: 10),
              Text('Mantener activo', style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
            ],
          ),
          content: const Text(
            'Android puede cerrar TalkIA en segundo plano y desconectarte de la sala.\n\n'
            'Para evitarlo, desactiva la optimización de batería para esta app.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Ahora no', style: TextStyle(color: AppTheme.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Configurar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      await prefs.setBool('battery_opt_asked', true);
      if (confirm == true) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e) {
      log.warn('battery opt check falló: $e');
    }
  }

  Future<void> _autoCheckForced() async {
    try {
      final result = await OtaService().checkForUpdate();
      if (!mounted || result == null || !result.isForced) return;
      _showForcedUpdateDialog(result);
    } catch (_) {}
  }

  void _showForcedUpdateDialog(OtaCheckResult result) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: AppTheme.surface,
            title: const Row(
              children: [
                Icon(Icons.system_update, color: AppTheme.accent),
                SizedBox(width: 10),
                Text(
                  'Actualización requerida',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 18),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Esta versión ya no es compatible. Debes actualizar para continuar.',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                ),
                if (result.changelog.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    result.changelog,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                if (_downloadingForced) ...[
                  LinearProgressIndicator(
                    value: _downloadProgress,
                    color: AppTheme.accent,
                    backgroundColor: AppTheme.background,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _downloadProgress != null
                        ? '${(_downloadProgress! * 100).toStringAsFixed(0)}%'
                        : 'Descargando…',
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ],
              ],
            ),
            actions: [
              if (!_downloadingForced)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      setDialogState(() {
                        _downloadingForced = true;
                        _downloadProgress = null;
                      });
                      try {
                        await OtaService().downloadAndInstall(
                          result.apkUrl,
                          onProgress: (received, total) {
                            if (total > 0) {
                              setDialogState(() {
                                _downloadProgress = received / total;
                              });
                            }
                          },
                        );
                      } catch (e) {
                        setDialogState(() {
                          _downloadingForced = false;
                          _downloadProgress = null;
                        });
                        if (mounted) _showSnack('Error al descargar: $e', isError: true);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text(
                      'ACTUALIZAR AHORA',
                      style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _nameCtrl.text = prefs.getString('user_name') ?? '';
    _roomCtrl.text = prefs.getString('last_room') ?? _defaultRoom;
  }

  Future<void> _join() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Ingresa tu nombre para continuar', isError: true);
      return;
    }

    final code = _roomCtrl.text.trim().toUpperCase();
    if (code.isEmpty) return;

    final password = _needsPassword ? _passwordCtrl.text.trim() : '';

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', name);
    await prefs.setString('last_room', code);

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RadioScreen(roomCode: code, password: password, userName: name),
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _roomCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 40),
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
                const SizedBox(height: 40),

                // Campo nombre
                TextField(
                  controller: _nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 24,
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Tu nombre',
                    hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                    counterText: '',
                    prefixIcon: const Icon(Icons.person_outline, color: AppTheme.textSecondary, size: 20),
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
                  onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                ),

                const SizedBox(height: 12),

                // Campo código de sala
                TextField(
                  controller: _roomCtrl,
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
                  onSubmitted: (_) => _needsPassword
                      ? FocusScope.of(context).nextFocus()
                      : _join(),
                ),

                // Campo contraseña de admin — solo para salas distintas de 76961
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 250),
                  crossFadeState: _needsPassword
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: const SizedBox(height: 12),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: _passwordCtrl,
                      obscureText: _obscurePassword,
                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'Contraseña de admin (solo para crear sala)',
                        hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
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
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword ? Icons.visibility_off : Icons.visibility,
                            color: AppTheme.textSecondary,
                            size: 20,
                          ),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      onSubmitted: (_) => _join(),
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _join,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'CONECTAR',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 3),
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
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textSecondary),
                        )
                      : const Icon(Icons.system_update_alt, size: 16, color: AppTheme.textSecondary),
                  label: const Text(
                    'BUSCAR ACTUALIZACIÓN',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, letterSpacing: 1.5),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
