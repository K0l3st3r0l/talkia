import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/constants.dart';

class OtaService {
  final Dio _dio = Dio();

  Future<void> checkAndUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(info.buildNumber) ?? kAppBuild;

      final res = await _dio.get(kOtaVersionUrl);
      final serverBuild = res.data['build'] as int? ?? 0;
      final apkUrl = res.data['url'] as String? ?? kOtaApkUrl;

      if (serverBuild <= localBuild) return;

      final dir = await getTemporaryDirectory();
      final apkPath = '${dir.path}/talkia-update.apk';

      await _dio.download(apkUrl, apkPath);

      final f = File(apkPath);
      if (await f.length() == 0) return;

      await OpenFilex.open(apkPath, type: 'application/vnd.android.package-archive');
    } catch (_) {}
  }
}
