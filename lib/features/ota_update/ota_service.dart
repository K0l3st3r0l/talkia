import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/constants.dart';
import '../../core/log_service.dart';

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

  Future<void> downloadAndInstall(
    String apkUrl, {
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final apkPath = '${dir.path}/talkia-update.apk';
      log.info('OTA descargando desde $apkUrl');

      await _dio.download(
        apkUrl,
        apkPath,
        onReceiveProgress: onProgress,
      );

      final f = File(apkPath);
      final size = await f.length();
      if (size == 0) {
        log.error('OTA APK descargado vacío');
        return;
      }
      log.info('OTA descarga OK — $size bytes, instalando…');
      await OpenFilex.open(apkPath, type: 'application/vnd.android.package-archive');
    } catch (e) {
      log.error('OTA download/install falló', e);
      rethrow;
    }
  }

  Future<void> checkAndUpdate() async {
    final result = await checkForUpdate();
    if (result == null || !result.hasUpdate) return;
    await downloadAndInstall(result.apkUrl);
  }
}
