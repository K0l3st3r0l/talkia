import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'core/theme/app_theme.dart';
import 'features/ota_update/ota_service.dart';
import 'features/radio/presentation/join_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  _initForegroundTask();

  runApp(const TalkIAApp());
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'talkia_channel',
      channelName: 'TalkIA',
      channelDescription: 'TalkIA activo — escuchando canal',
      channelImportance: NotificationChannelImportance.DEFAULT,
      priority: NotificationPriority.DEFAULT,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: false,
      allowWakeLock: true,
    ),
  );
}

class TalkIAApp extends StatefulWidget {
  const TalkIAApp({super.key});

  @override
  State<TalkIAApp> createState() => _TalkIAAppState();
}

class _TalkIAAppState extends State<TalkIAApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      OtaService().checkAndUpdate();
    });
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'TalkIA',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: const JoinScreen(),
      ),
    );
  }
}
