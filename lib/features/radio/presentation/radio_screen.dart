import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/log_service.dart';
import '../../debug/log_screen.dart';
import '../../ota_update/ota_service.dart';
import '../services/radio_service.dart';

// Funciones puras de presencia y orden, sin estado de widget — testeables
// directamente (ver test/radio_presence_test.dart) sin emulador ni servicio.

String presenceKeyFor(RoomUser u) => u.id.isNotEmpty ? u.id : 'name:${u.name}';

/// Nombres que representan ingresos genuinos (no reconexiones), comparando
/// el roster nuevo contra las claves ya conocidas y cuándo se vio cada una
/// por última vez. Ver protocolo-presencia.md: una reconexión dispara un
/// user_joined real pero el client_id nunca deja de estar "recién visto",
/// así que la ventana de 60s la filtra sin necesitar distinguir el tipo de
/// mensaje que originó el snapshot.
List<String> newArrivals({
  required List<RoomUser> newUsers,
  required Set<String> previousKeys,
  required Map<String, DateTime> lastSeenAt,
  required DateTime now,
  Duration reconnectWindow = const Duration(seconds: 60),
}) {
  final arrivals = <String>[];
  for (final u in newUsers) {
    final key = presenceKeyFor(u);
    if (previousKeys.contains(key)) continue;
    final lastSeen = lastSeenAt[key];
    final isReconnect =
        lastSeen != null && now.difference(lastSeen) < reconnectWindow;
    if (!isReconnect) arrivals.add(u.name);
  }
  return arrivals;
}

String formatJoinBanner(List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) return '${names.first} se conectó';
  if (names.length == 2) return '${names[0]} y ${names[1]} se conectaron';
  return '${names[0]} y ${names.length - 1} más se conectaron';
}

/// Orden para la hoja inferior: quien habla, luego tú, luego el resto en el
/// orden que manda el servidor (orden de llegada). Nunca alfabético.
List<RoomUser> orderUsersForSheet({
  required List<RoomUser> users,
  String? speakerName,
  required bool Function(RoomUser) isMe,
}) {
  RoomUser? speakerUser;
  RoomUser? meUser;
  final rest = <RoomUser>[];
  for (final u in users) {
    final isSpeaker =
        speakerName != null && speakerName.isNotEmpty && u.name == speakerName;
    if (isSpeaker && speakerUser == null) {
      speakerUser = u;
      continue;
    }
    if (isMe(u) && meUser == null) {
      meUser = u;
      continue;
    }
    rest.add(u);
  }
  return [
    if (speakerUser != null) speakerUser,
    if (meUser != null) meUser,
    ...rest,
  ];
}

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

class _RadioScreenState extends State<RadioScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final RadioService _radio = RadioService();

  RadioState _state = RadioState.disconnected;
  List<RoomUser> _users = [];
  String? _speaker;
  String? _lastSpeaker;
  int _roomCodeTaps = 0;
  bool _muted = false;
  double _volume = 1.0;

  // Distingue "primera conexión" de "se cayó y está reintentando" para no
  // mostrar un DESCONECTADO que sugiere inacción cuando el backoff ya está
  // corriendo solo (ver RadioService._scheduleReconnect).
  bool _hasConnectedOnce = false;
  bool _hasNetwork = true;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _waveCtrl;

  StreamSubscription? _stateSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _usersSub;
  StreamSubscription? _speakerSub;
  StreamSubscription? _channelBusySub;
  StreamSubscription? _connectivitySub;

  final OtaService _ota = OtaService();
  Timer? _otaTimer;
  bool _hasUpdate = false;
  bool _updateReady = false;
  OtaCheckResult? _pendingUpdate;

  bool _hasMicPermission = false;

  // Presencia: detecta ingresos genuinos vs. reconexiones (ver
  // wiki/projects/talkia/decisions/protocolo-presencia.md). Un client_id que
  // ya estaba en el roster hace menos de 60s no es un ingreso nuevo.
  final Map<String, DateTime> _lastSeenAt = {};
  Set<String> _previousKeys = {};
  bool _firstRosterSnapshot = true;
  bool _appInForeground = true;

  final List<String> _pendingJoinNames = [];
  Timer? _joinCoalesceTimer;
  Timer? _joinDismissTimer;
  Timer? _joinCleanupTimer;
  String? _joinBannerText;
  bool _joinBannerVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(
      begin: 1.0,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _init();
  }

  bool _hasAnyNetwork(List<ConnectivityResult> results) => results.any(
    (r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet,
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
  }

  void _onRoomCodeTap() {
    _roomCodeTaps++;
    if (_roomCodeTaps >= 3) {
      _roomCodeTaps = 0;
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const LogScreen()));
    }
  }

  Future<void> _init() async {
    log.info('RadioScreen init — sala: ${widget.roomCode}');
    await _radio.init();

    _ota.isAudioActiveProvider = () => _isActive;
    _ota.onPreloadReady = (build) {
      if (!mounted || _pendingUpdate?.serverBuild != build) return;
      setState(() => _updateReady = true);
    };

    final status = await Permission.microphone.request();
    _hasMicPermission = status.isGranted;

    _stateSub = _radio.stateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _state = s;
        if (s == RadioState.connected ||
            s == RadioState.transmitting ||
            s == RadioState.receiving) {
          _hasConnectedOnce = true;
        }
      });
      // Es una radio: 55MB de precarga compitiendo con el stream de audio
      // degrada justo la función principal de la app — cortar apenas hay
      // audio activo (propio o de otro hablando) y retomar al quedar idle.
      if (s == RadioState.transmitting || s == RadioState.receiving) {
        _ota.cancelPreloadForAudio();
      } else if (s == RadioState.connected) {
        _ota.resumeIfPending();
      }
    });
    _usersSub = _radio.usersStream.listen((u) {
      if (!mounted) return;
      _trackPresence(u);
      setState(() => _users = u);
    });
    _speakerSub = _radio.speakerStream.listen((s) {
      if (mounted)
        setState(() {
          if (s != null) _lastSpeaker = s;
          _speaker = s;
        });
    });
    _errorSub = _radio.errorStream.listen((code) {
      if (!mounted) return;
      if (code == 'update_required') {
        _showUpdateRequiredDialog();
        return;
      }
      const msg =
          'Sala nueva — se requiere contraseña de administrador para crearla';
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(msg),
          backgroundColor: AppTheme.transmitColor,
        ),
      );
      Navigator.of(context).pop();
    });
    _channelBusySub = _radio.channelBusyStream.listen((busyName) {
      if (!mounted) return;
      final msg = busyName.isNotEmpty
          ? 'Canal ocupado — $busyName está hablando'
          : 'Canal ocupado';
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: AppTheme.receiveColor,
            duration: const Duration(seconds: 2),
          ),
        );
    });

    final initialConnectivity = await Connectivity().checkConnectivity();
    _hasNetwork = _hasAnyNetwork(initialConnectivity);
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      setState(() => _hasNetwork = _hasAnyNetwork(results));
    });

    await _radio.connect(
      widget.roomCode,
      password: widget.password,
      userName: widget.userName,
    );

    _checkOta();
    _otaTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkOta());

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

  Future<void> _checkOta() async {
    final result = await _ota.checkForUpdate();
    if (result == null || !result.hasUpdate || !mounted) return;
    if (_hasUpdate && result.serverBuild == _pendingUpdate?.serverBuild) return;
    final ready = await _ota.isPreloaded(result.serverBuild);
    if (!mounted) return;
    setState(() {
      _hasUpdate = true;
      _pendingUpdate = result;
      _updateReady = ready;
    });
    log.info('OTA update disponible en sala: build ${result.serverBuild}');
    if (!ready) _ota.maybePreload(result);
  }

  Future<void> _installUpdate() async {
    final update = _pendingUpdate;
    if (update == null) return;
    if (_updateReady) {
      final installed = await _ota.installPreloaded(update.serverBuild);
      if (installed) {
        setState(() => _hasUpdate = false);
        return;
      }
      // getTemporaryDirectory() pudo vaciarse bajo presión de
      // almacenamiento — cae al flujo de descarga normal sin error visible.
      setState(() => _updateReady = false);
    }
    setState(() => _hasUpdate = false);
    await _ota.downloadAndInstall(update.apkUrl, build: update.serverBuild);
  }

  void _showUpdateRequiredDialog() {
    double? progress;
    bool downloading = false;

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
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 17),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Esta versión ya no es compatible con el servidor. Descarga la nueva versión para continuar.',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                if (downloading) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: progress,
                    color: AppTheme.accent,
                    backgroundColor: AppTheme.background,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    progress != null
                        ? 'Descargando… ${(progress! * 100).toStringAsFixed(0)}%'
                        : 'Descargando…',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (!downloading)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      setDialogState(() => downloading = true);
                      try {
                        final result = await _ota.checkForUpdate();
                        final url = result?.apkUrl ?? kOtaApkUrl;
                        await _ota.downloadAndInstall(
                          url,
                          build: result?.serverBuild,
                          onProgress: (received, total) {
                            if (total > 0) {
                              setDialogState(() => progress = received / total);
                            }
                          },
                        );
                      } catch (e) {
                        setDialogState(() {
                          downloading = false;
                          progress = null;
                        });
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error al descargar: $e'),
                              backgroundColor: AppTheme.transmitColor,
                            ),
                          );
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text(
                      'DESCARGAR ACTUALIZACIÓN',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmExit() async {
    if (_state == RadioState.disconnected) return true;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text(
          '¿Salir de la sala?',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Hay ${_users.length} ${_users.length == 1 ? 'usuario' : 'usuarios'} en la sala. ¿Confirmas que quieres salir?',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'CANCELAR',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'SALIR',
              style: TextStyle(color: AppTheme.transmitColor),
            ),
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
    if (_state == RadioState.receiving) {
      final speaker = _speaker;
      final msg = speaker != null && speaker.isNotEmpty
          ? 'Canal ocupado — $speaker está hablando'
          : 'Canal ocupado';
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: AppTheme.receiveColor,
            duration: const Duration(seconds: 2),
          ),
        );
      return;
    }
    await _radio.startTransmitting();
  }

  Future<void> _onPttEnd() async {
    await _radio.stopTransmitting();
  }

  // El backoff de RadioService reintenta solo (ver protocolo-presencia en la
  // wiki): mientras hubo conexión antes, "disconnected"/"connecting" es en
  // los hechos una reconexión en curso, no un estado terminal.
  bool get _isReconnecting =>
      _hasConnectedOnce &&
      (_state == RadioState.disconnected || _state == RadioState.connecting);

  // El único camino que deja usuarios "viejos" en pantalla mientras no hay
  // conexión activa es el reconnect por cambio de red (no limpia el roster
  // para evitar parpadeo en cortes cortos) — ver
  // RadioService._startConnectivityListener.
  // La fórmula de RoomUser.isOutdated compara contra kAppBuild propio, así
  // que nunca puede marcarme a mí mismo — se deriva acá comparando contra el
  // build más alto visto en la sala.
  bool get _selfBuildBehind => _users.any((u) => u.build > kAppBuild);

  bool get _rosterMaybeStale =>
      _users.isNotEmpty &&
      _state != RadioState.connected &&
      _state != RadioState.transmitting &&
      _state != RadioState.receiving;

  Color get _buttonColor {
    if (!_hasNetwork) return AppTheme.transmitColor;
    if (_isReconnecting) return AppTheme.warnColor;
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
    if (!_hasNetwork) return 'SIN CONEXIÓN A INTERNET';
    if (_isReconnecting) return 'RECONECTANDO...';
    switch (_state) {
      case RadioState.disconnected:
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

  String get _pttSemanticLabel {
    if (!_hasNetwork)
      return 'Sin conexión a internet. Botón de hablar no disponible.';
    if (_isReconnecting)
      return 'Reconectando a la sala. Botón de hablar no disponible.';
    switch (_state) {
      case RadioState.transmitting:
        return 'Transmitiendo. Suelta para terminar.';
      case RadioState.receiving:
        final speaker = _speaker;
        return speaker != null && speaker.isNotEmpty
            ? '$speaker está hablando. Canal ocupado, botón de hablar no disponible.'
            : 'Recibiendo audio. Canal ocupado, botón de hablar no disponible.';
      case RadioState.connected:
        return 'Botón de hablar. Mantén presionado para transmitir.';
      case RadioState.disconnected:
      case RadioState.connecting:
        return 'Conectando a la sala. Botón de hablar no disponible.';
    }
  }

  bool get _isActive =>
      _state == RadioState.transmitting || _state == RadioState.receiving;

  Color get _counterColor {
    if (_rosterMaybeStale) return AppTheme.warnColor;
    if (_users.length > 1) return AppTheme.receiveColor;
    return AppTheme.textSecondary;
  }

  bool _isMe(RoomUser u) =>
      u.id.isNotEmpty ? u.id == _radio.clientId : u.name == widget.userName;

  // Alimenta el roster de "vistos por última vez" y detecta ingresos
  // genuinos. Debe correr en cada snapshot (welcome/user_joined/user_left)
  // para que la ventana de 60s tenga datos frescos de todos, no solo de
  // quienes generaron un aviso.
  void _trackPresence(List<RoomUser> newUsers) {
    final now = DateTime.now();
    if (!_firstRosterSnapshot) {
      final arrivals = newArrivals(
        newUsers: newUsers,
        previousKeys: _previousKeys,
        lastSeenAt: _lastSeenAt,
        now: now,
      );
      if (_appInForeground) {
        for (final name in arrivals) {
          _queueJoinBanner(name);
        }
      }
    }
    for (final u in newUsers) {
      _lastSeenAt[presenceKeyFor(u)] = now;
    }
    _previousKeys = newUsers.map(presenceKeyFor).toSet();
    _firstRosterSnapshot = false;
  }

  void _queueJoinBanner(String name) {
    _pendingJoinNames.add(name);
    _joinCoalesceTimer ??= Timer(const Duration(seconds: 3), _flushJoinBanner);
  }

  void _flushJoinBanner() {
    _joinCoalesceTimer = null;
    if (_pendingJoinNames.isEmpty) return;
    final names = List<String>.from(_pendingJoinNames);
    _pendingJoinNames.clear();
    if (!mounted || !_appInForeground) return;
    _showJoinBanner(formatJoinBanner(names));
  }

  void _showJoinBanner(String text) {
    _joinDismissTimer?.cancel();
    _joinCleanupTimer?.cancel();
    setState(() {
      _joinBannerText = text;
      _joinBannerVisible = true;
    });
    _joinDismissTimer = Timer(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      setState(() => _joinBannerVisible = false);
      _joinCleanupTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _joinBannerText = null);
      });
    });
  }

  void _openUsersSheet() {
    final ordered = orderUsersForSheet(
      users: _users,
      speakerName: _speaker,
      isMe: _isMe,
    );
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.45,
        minChildSize: 0.25,
        maxChildSize: 0.6,
        expand: false,
        builder: (ctx, scrollController) => Container(
          decoration: const BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textSecondary.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Text(
                      ordered.length == 1
                          ? '1 conectado'
                          : '${ordered.length} conectados',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
              if (_rosterMaybeStale)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.sync_problem,
                        size: 12,
                        color: AppTheme.warnColor,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'LISTA PUEDE ESTAR DESACTUALIZADA',
                        style: TextStyle(
                          color: AppTheme.warnColor,
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ordered.isEmpty
                    ? const Center(
                        child: Text(
                          'Nadie conectado',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        itemCount: ordered.length,
                        separatorBuilder: (_, __) => const Divider(
                          color: AppTheme.background,
                          height: 1,
                        ),
                        itemBuilder: (ctx, i) => _buildUserRow(ordered[i]),
                      ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserRow(RoomUser user) {
    final isSpeaker =
        _speaker != null && _speaker!.isNotEmpty && user.name == _speaker;
    final isMe = _isMe(user);
    final outdated = user.isOutdated || (isMe && _selfBuildBehind);
    final displayName = isMe ? '${user.name} (tú)' : user.name;
    final nameColor = isSpeaker
        ? AppTheme.receiveColor
        : isMe
        ? AppTheme.accent
        : AppTheme.textPrimary;
    final semanticLabel = [
      displayName,
      if (isSpeaker) 'hablando',
      if (outdated) 'versión desactualizada',
      user.build > 0 ? 'build ${user.build}' : 'build desconocido',
    ].join(', ');
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              if (isSpeaker) ...[
                const Icon(Icons.mic, size: 14, color: AppTheme.receiveColor),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  displayName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: nameColor,
                    fontSize: 14,
                    fontWeight: isSpeaker || isMe
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                user.build > 0 ? 'b${user.build}' : 'b?',
                style: TextStyle(
                  color: outdated ? AppTheme.warnColor : AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: outdated ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.stopService();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _otaTimer?.cancel();
    _joinCoalesceTimer?.cancel();
    _joinDismissTimer?.cancel();
    _joinCleanupTimer?.cancel();
    _stateSub?.cancel();
    _errorSub?.cancel();
    _usersSub?.cancel();
    _speakerSub?.cancel();
    _channelBusySub?.cancel();
    _connectivitySub?.cancel();
    _radio.dispose();
    _ota.dispose();
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
            icon: const Icon(
              Icons.arrow_back_ios,
              color: AppTheme.textSecondary,
            ),
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
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        letterSpacing: 2,
                      ),
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
              padding: const EdgeInsets.only(right: 4),
              child: Semantics(
                button: true,
                label: _users.length == 1
                    ? '1 usuario conectado en la sala. Toca para ver la lista.'
                    : '${_users.length} usuarios conectados en la sala. Toca para ver la lista.',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: _openUsersSheet,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      child: ExcludeSemantics(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.people, size: 14, color: _counterColor),
                            const SizedBox(width: 4),
                            Text(
                              '${_users.length}',
                              style: TextStyle(
                                color: _counterColor,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.keyboard_arrow_down,
                              size: 14,
                              color: _counterColor,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                // Status bar
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  color: AppTheme.surface,
                  child: Center(
                    child: Semantics(
                      liveRegion: true,
                      excludeSemantics: true,
                      label: _state == RadioState.receiving && _speaker != null
                          ? 'HABLANDO: $_statusLabel'
                          : _statusLabel,
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
                ),

                // Banner de actualización disponible
                if (_hasUpdate)
                  GestureDetector(
                    onTap: _installUpdate,
                    child: Container(
                      width: double.infinity,
                      color: AppTheme.accent.withOpacity(0.12),
                      padding: const EdgeInsets.symmetric(
                        vertical: 7,
                        horizontal: 16,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _updateReady
                                ? Icons.install_mobile
                                : Icons.system_update_alt,
                            color: AppTheme.accent,
                            size: 14,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _updateReady
                                ? 'Nueva versión lista (build ${_pendingUpdate?.serverBuild}) — toca para instalar'
                                : 'Nueva versión disponible (build ${_pendingUpdate?.serverBuild}) — toca para actualizar',
                            style: const TextStyle(
                              color: AppTheme.accent,
                              fontSize: 11,
                              letterSpacing: 1,
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
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            if (_isActive)
                              AnimatedBuilder(
                                animation: _waveCtrl,
                                builder: (_, __) => CustomPaint(
                                  size: const Size(280, 280),
                                  painter: _WavePainter(
                                    _waveCtrl.value,
                                    _buttonColor,
                                  ),
                                ),
                              ),
                            Semantics(
                              button: true,
                              enabled: _state == RadioState.connected,
                              label: _pttSemanticLabel,
                              child: ExcludeSemantics(
                                child: Listener(
                                  onPointerDown: (_) => _onPttStart(),
                                  onPointerUp: (_) => _onPttEnd(),
                                  onPointerCancel: (_) => _onPttEnd(),
                                  child: AnimatedBuilder(
                                    animation: _pulseAnim,
                                    builder: (_, child) => Transform.scale(
                                      scale: _state == RadioState.transmitting
                                          ? _pulseAnim.value
                                          : 1.0,
                                      child: child,
                                    ),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
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
                                                  color: _buttonColor
                                                      .withOpacity(0.4),
                                                  blurRadius: 30,
                                                  spreadRadius: 8,
                                                ),
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
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 40),

                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 300),
                          opacity: _state == RadioState.connected ? 1.0 : 0.0,
                          child: const Column(
                            children: [
                              Icon(
                                Icons.touch_app,
                                color: AppTheme.textSecondary,
                                size: 20,
                              ),
                              SizedBox(height: 8),
                              Text(
                                'PRESIONA PARA HABLAR',
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

                        if (_state == RadioState.receiving && _speaker != null)
                          Text(
                            '${_speaker!.toUpperCase()} ESTÁ HABLANDO',
                            style: const TextStyle(
                              color: AppTheme.receiveColor,
                              fontSize: 11,
                              letterSpacing: 2,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        else if (_state == RadioState.receiving)
                          const Text(
                            'ESCUCHANDO...',
                            style: TextStyle(
                              color: AppTheme.receiveColor,
                              fontSize: 11,
                              letterSpacing: 2,
                              fontWeight: FontWeight.bold,
                            ),
                          ),

                        if (_lastSpeaker != null && _speaker == null) ...[
                          const SizedBox(height: 20),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.history,
                                size: 12,
                                color: AppTheme.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'ÚLTIMO: ${_lastSpeaker!.toUpperCase()}',
                                style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 11,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // Control de volumen
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.volume_down,
                        color: AppTheme.textSecondary,
                        size: 18,
                      ),
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
                      const Icon(
                        Icons.volume_up,
                        color: AppTheme.textSecondary,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${(_volume * 100).round()}%',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
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
                    _users.length == 1
                        ? 'Solo tú en la sala'
                        : '${_users.length} usuarios conectados',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),

            // Aviso transitorio de ingreso — desliza desde arriba, se va
            // solo. No es SnackBar: eso aparece abajo y tapa el botón PTT.
            if (_joinBannerText != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  offset: _joinBannerVisible
                      ? Offset.zero
                      : const Offset(0, -1),
                  child: Material(
                    color: AppTheme.accent.withOpacity(0.14),
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        child: Semantics(
                          liveRegion: true,
                          label: _joinBannerText,
                          child: ExcludeSemantics(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.person_add_alt_1,
                                  color: AppTheme.accent,
                                  size: 14,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    _joinBannerText!,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.accent,
                                      fontSize: 12,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
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
