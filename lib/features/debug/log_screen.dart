import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/log_service.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Color _color(String level) => switch (level) {
    'ERROR' => Colors.red[300]!,
    'WARN'  => Colors.orange[300]!,
    _       => Colors.green[300]!,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('Talkia — Logs', style: TextStyle(fontFamily: 'monospace')),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copiar todo',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log.allText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copiados al portapapeles')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Limpiar',
            onPressed: () => setState(() => log.clear()),
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: log.count,
        builder: (_, __, ___) {
          final entries = log.logs;
          if (entries.isEmpty) {
            return const Center(
              child: Text('Sin logs aún',
                style: TextStyle(color: Colors.white38, fontFamily: 'monospace')),
            );
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
          return ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(8),
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final e = entries[i];
              return Text(
                e.formatted,
                style: TextStyle(
                  color: _color(e.level),
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.6,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
