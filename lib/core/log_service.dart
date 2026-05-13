import 'package:flutter/foundation.dart';

class LogEntry {
  final DateTime time;
  final String level;
  final String message;

  LogEntry(this.level, this.message) : time = DateTime.now();

  String get formatted {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '[$h:$m:$s] [$level] $message';
  }
}

class LogService {
  LogService._();
  static final LogService instance = LogService._();

  final List<LogEntry> _logs = [];
  final ValueNotifier<int> count = ValueNotifier(0);

  static const int _maxLogs = 300;

  void _add(String level, String message) {
    _logs.add(LogEntry(level, message));
    if (_logs.length > _maxLogs) _logs.removeAt(0);
    count.value = _logs.length;
    debugPrint('[Talkia][$level] $message');
  }

  void info(String msg) => _add('INFO', msg);
  void warn(String msg) => _add('WARN', msg);
  void error(String msg, [Object? err]) =>
      _add('ERROR', err != null ? '$msg — $err' : msg);

  List<LogEntry> get logs => List.unmodifiable(_logs);

  void clear() {
    _logs.clear();
    count.value = 0;
  }

  String get allText => _logs.map((e) => e.formatted).join('\n');
}

final log = LogService.instance;
