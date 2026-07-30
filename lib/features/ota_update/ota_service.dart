import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';
import '../../core/log_service.dart';

// Margen sobre el peso real del APK (~55MB): cubre el archivo nuevo más el
// que todavía no se limpió de un build anterior.
const double kOtaRequiredFreeSpaceMb = 150;
const int kOtaMaxPreloadRetries = 3;
const String _kPrefBuild = 'ota_preload_build';
const String _kPrefSize = 'ota_preload_size';

// ---- Lógica pura — sin I/O, testeable directamente (ver test/ota_preload_test.dart) ----

String otaApkFileName(int build) => 'talkia-update-$build.apk';

/// Sin Content-Length del servidor (expectedBytes<=0) solo se puede
/// descartar el caso obvio de archivo vacío/cortado a 0.
bool isValidApkFile({required int actualBytes, required int expectedBytes}) {
  if (actualBytes <= 0) return false;
  if (expectedBytes <= 0) return true;
  return actualBytes == expectedBytes;
}

bool shouldPreloadUpdate({
  required bool isWifi,
  required bool audioActive,
  required double freeSpaceMb,
  double requiredSpaceMb = kOtaRequiredFreeSpaceMb,
}) {
  return isWifi && !audioActive && freeSpaceMb >= requiredSpaceMb;
}

/// Backoff exponencial acotado (2s, 4s, ..., tope 30s) — mismo esquema que
/// RadioService._scheduleReconnect pero determinista (sin jitter) para que
/// el test no dependa de azar.
Duration otaPreloadRetryDelay(int attempt) {
  final ms = 2000 * (1 << attempt.clamp(0, 4));
  return Duration(milliseconds: math.min(ms, 30000));
}

class OtaCheckResult {
  final int localBuild;
  final int serverBuild;
  final bool hasUpdate;
  final bool isForced;
  final String apkUrl;
  final String changelog;

  OtaCheckResult({
    required this.localBuild,
    required this.serverBuild,
    required this.hasUpdate,
    required this.isForced,
    required this.apkUrl,
    required this.changelog,
  });
}

class OtaService {
  final Dio _dio = Dio();

  /// Se llama cuando termina de precargarse y validarse el build objetivo.
  void Function(int build)? onPreloadReady;

  /// Inyectado por radio_screen: true mientras el estado sea
  /// transmitting/receiving. Sin esto OtaService no tiene forma de saber si
  /// hay audio activo sin importar RadioService directamente.
  bool Function()? isAudioActiveProvider;

  OtaCheckResult? _preloadTarget;
  int _preloadAttempt = 0;
  bool _preloadRunning = false;
  bool _preloadCancelledForAudio = false;
  CancelToken? _cancelToken;
  Timer? _preloadRetryTimer;

  static Future<String> get currentVersion async {
    final info = await PackageInfo.fromPlatform();
    final build = int.tryParse(info.buildNumber) ?? kAppBuild;
    return 'v${info.version} (build $build)';
  }

  Future<OtaCheckResult?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(info.buildNumber) ?? kAppBuild;
      log.info('OTA check — local build: $localBuild');

      final res = await _dio.get(kOtaVersionUrl);
      final serverBuild = res.data['build'] as int? ?? 0;
      final minBuild = res.data['min_build'] as int? ?? 0;
      final apkUrl = res.data['url'] as String? ?? kOtaApkUrl;
      final changelog = res.data['changelog'] as String? ?? '';
      log.info('OTA server build: $serverBuild, min_build: $minBuild');

      return OtaCheckResult(
        localBuild: localBuild,
        serverBuild: serverBuild,
        hasUpdate: serverBuild > localBuild,
        isForced: localBuild < minBuild,
        apkUrl: apkUrl,
        changelog: changelog,
      );
    } catch (e) {
      log.error('OTA check falló', e);
      return null;
    }
  }

  Future<Directory> _apkDir() => getTemporaryDirectory();

  /// Descarga a un nombre `.part` y solo la renombra al nombre final si el
  /// tamaño calza con el Content-Length reportado — así un archivo a medio
  /// nombre final nunca puede ser confundido con uno completo y validado.
  Future<File?> _downloadToValidatedFile(
    String apkUrl, {
    required int build,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await _apkDir();
    final apkPath = '${dir.path}/${otaApkFileName(build)}';
    final tmpPath = '$apkPath.part';
    int expectedTotal = 0;
    log.info('OTA descargando build $build desde $apkUrl');

    await _dio.download(
      apkUrl,
      tmpPath,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) expectedTotal = total;
        onProgress?.call(received, total);
      },
    );

    final tmpFile = File(tmpPath);
    final size = await tmpFile.length();
    if (!isValidApkFile(actualBytes: size, expectedBytes: expectedTotal)) {
      log.error('OTA APK inválido — $size/$expectedTotal bytes, descartando');
      await _safeDelete(tmpFile);
      return null;
    }

    final finalFile = await tmpFile.rename(apkPath);
    if (build > 0) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefBuild, build);
      await prefs.setInt(_kPrefSize, size);
    }
    log.info('OTA descarga OK — $size bytes (build $build)');
    return finalFile;
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      log.warn('OTA no se pudo borrar ${f.path}: $e');
    }
  }

  /// Borra APKs (y descargas `.part` truncas) de builds anteriores — 55MB
  /// cada uno, no tiene sentido conservarlos.
  Future<void> _cleanupOtherBuilds({required int keepBuild}) async {
    try {
      final dir = await _apkDir();
      final keepName = otaApkFileName(keepBuild);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('talkia-update-') && name != keepName) {
          await _safeDelete(entity);
        }
      }
    } catch (e) {
      log.warn('OTA no se pudo limpiar APKs viejos: $e');
    }
  }

  /// Archivo ya descargado y validado para `build`, o null si no existe, no
  /// calza el tamaño esperado, o getTemporaryDirectory() lo perdió (Android
  /// puede vaciarlo bajo presión de almacenamiento).
  Future<File?> preloadedApkFor(int build) async {
    if (build <= 0) return null;
    final prefs = await SharedPreferences.getInstance();
    final storedBuild = prefs.getInt(_kPrefBuild);
    final storedSize = prefs.getInt(_kPrefSize);
    if (storedBuild != build || storedSize == null) return null;

    final dir = await _apkDir();
    final file = File('${dir.path}/${otaApkFileName(build)}');
    if (!await file.exists()) return null;
    final size = await file.length();
    if (!isValidApkFile(actualBytes: size, expectedBytes: storedSize)) {
      await _safeDelete(file);
      return null;
    }
    return file;
  }

  Future<bool> isPreloaded(int build) async => (await preloadedApkFor(build)) != null;

  /// Abre el instalador directo con el APK ya cacheado. Devuelve false si el
  /// caché ya no está disponible — el llamador debe caer al flujo de
  /// descarga normal sin mostrar error.
  Future<bool> installPreloaded(int build) async {
    final file = await preloadedApkFor(build);
    if (file == null) return false;
    log.info('OTA instalando APK precargado — build $build');
    await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    return true;
  }

  /// Descarga + instala en un solo intento (flujo manual/forzado, con un
  /// humano mirando la pantalla que puede reintentar tocando de nuevo).
  Future<void> downloadAndInstall(
    String apkUrl, {
    void Function(int received, int total)? onProgress,
    int? build,
  }) async {
    try {
      final file = await _downloadToValidatedFile(
        apkUrl,
        build: build ?? 0,
        onProgress: onProgress,
      );
      if (file == null) {
        throw Exception('Descarga incompleta o corrupta');
      }
      log.info('OTA instalando…');
      await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    } catch (e) {
      log.error('OTA download/install falló', e);
      rethrow;
    }
  }

  Future<void> checkAndUpdate() async {
    final result = await checkForUpdate();
    if (result == null || !result.hasUpdate) return;
    await downloadAndInstall(result.apkUrl, build: result.serverBuild);
  }

  /// Precarga silenciosa en segundo plano. Idempotente y segura de llamar
  /// repetidamente (desde el timer de 5min o al volver a estado idle) — solo
  /// arranca una descarga si no hay una en curso y no se agotaron los
  /// reintentos para este build.
  Future<void> maybePreload(OtaCheckResult result) async {
    if (!result.hasUpdate) return;
    final build = result.serverBuild;
    if (await isPreloaded(build)) return;

    if (_preloadTarget?.serverBuild != build) {
      _preloadTarget = result;
      _preloadAttempt = 0;
      _preloadRetryTimer?.cancel();
      _preloadRetryTimer = null;
    }
    if (_preloadRunning) return;
    if (_preloadAttempt >= kOtaMaxPreloadRetries) return;
    if (isAudioActiveProvider?.call() ?? false) return;

    final connectivity = await Connectivity().checkConnectivity();
    final isWifi = connectivity.contains(ConnectivityResult.wifi);
    double freeSpaceMb;
    try {
      freeSpaceMb =
          await DiskSpacePlus().getFreeDiskSpaceForPath((await _apkDir()).path) ?? 0;
    } catch (e) {
      log.warn('OTA no se pudo leer espacio libre — se pospone preload: $e');
      return;
    }

    // Se revalida audioActive: pudo activarse mientras esperábamos las
    // llamadas async de arriba (checkConnectivity/getFreeDiskSpace).
    if (!shouldPreloadUpdate(
      isWifi: isWifi,
      audioActive: isAudioActiveProvider?.call() ?? false,
      freeSpaceMb: freeSpaceMb,
    )) {
      log.info('OTA preload pospuesto — wifi:$isWifi espacioMB:$freeSpaceMb');
      return;
    }

    await _cleanupOtherBuilds(keepBuild: build);
    _preloadRunning = true;
    _preloadCancelledForAudio = false;
    _cancelToken = CancelToken();
    try {
      final file = await _downloadToValidatedFile(
        result.apkUrl,
        build: build,
        cancelToken: _cancelToken,
      );
      if (file != null) {
        log.info('OTA preload listo — build $build');
        onPreloadReady?.call(build);
      } else {
        _scheduleRetry();
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        log.info(
          'OTA preload cancelado — ${_preloadCancelledForAudio ? "audio activo" : "reemplazado"}',
        );
      } else {
        log.warn('OTA preload falló: $e');
        _scheduleRetry();
      }
    } catch (e) {
      log.warn('OTA preload falló: $e');
      _scheduleRetry();
    } finally {
      _preloadRunning = false;
    }
  }

  void _scheduleRetry() {
    _preloadAttempt++;
    if (_preloadAttempt >= kOtaMaxPreloadRetries) {
      log.error(
        'OTA preload abandonado tras $_preloadAttempt intentos — build ${_preloadTarget?.serverBuild}',
      );
      return;
    }
    final target = _preloadTarget;
    if (target == null) return;
    _preloadRetryTimer?.cancel();
    _preloadRetryTimer = Timer(otaPreloadRetryDelay(_preloadAttempt), () {
      maybePreload(target);
    });
  }

  /// Corta la descarga en curso — se llama apenas el usuario aprieta PTT o
  /// empieza a recibir a otro hablando. Es una radio: 55MB compitiendo con
  /// el stream de audio degrada justo la función principal de la app.
  void cancelPreloadForAudio() {
    if (_preloadRunning && _cancelToken != null && !_cancelToken!.isCancelled) {
      log.info('OTA preload cortado — audio activo');
      _preloadCancelledForAudio = true;
      _cancelToken!.cancel('audio-active');
    }
    _preloadRetryTimer?.cancel();
    _preloadRetryTimer = null;
  }

  /// Se llama cuando el estado vuelve a idle (conectado, sin transmitir ni
  /// recibir) para retomar una precarga pendiente.
  void resumeIfPending() {
    final target = _preloadTarget;
    if (target == null || _preloadRunning) return;
    maybePreload(target);
  }

  void dispose() {
    _preloadRetryTimer?.cancel();
    _cancelToken?.cancel('disposed');
  }
}
