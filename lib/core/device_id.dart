import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

const String _kClientIdKey = 'talkia_client_id';

/// Identidad estable de la instalación. El servidor indexa el roster por este
/// valor, así una reconexión reemplaza la sesión anterior en vez de duplicarla.
Future<String> loadClientId() async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getString(_kClientIdKey);
  if (stored != null && stored.isNotEmpty) return stored;

  final rnd = Random.secure();
  final id = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  await prefs.setString(_kClientIdKey, id);
  return id;
}
