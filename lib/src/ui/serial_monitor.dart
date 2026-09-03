import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../esp/protocol.dart';
import '../esp/transport.dart';
import 'theme.dart';
import 'widgets.dart';

/// Live serial console.
///
/// No baud rate is assumed. The firmware's rate is a property of the firmware,
/// not something the app can know, so the user picks it before the stream
/// starts rather than being shown plausible-looking garbage.
class SerialMonitorScreen extends StatefulWidget {
  const SerialMonitorScreen({super.key, required this.device});

  final SerialDeviceInfo device;

  @override
  State<SerialMonitorScreen> createState() => _SerialMonitorScreenState();
}

class _SerialMonitorScreenState extends State<SerialMonitorScreen> {
  static const _bauds = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600];

  SerialTransport? _transport;
  StreamSubscription<Uint8List>? _sub;
  final _scroll = ScrollController();
  final _lines = <String>[];
  String _partial = '';

  int? _baud;
  bool _running = false;
  bool _autoScroll = true;
  String? _error;

  @override
  void dispose() {
    _sub?.cancel();
    _transport?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start(int baud) async {
    setState(() {
      _error = null;
      _baud = baud;
      _lines.clear();
      _partial = '';
    });

    try {
      final t = SerialTransport(widget.device);
      await t.open(baudRate: baud);
      // Release the board from reset so it runs normally while we watch.
      await t.setDtr(false);
      await t.setRts(false);

      _sub = t.incoming.listen(_onData);
      setState(() {
        _transport = t;
        _running = true;
      });
    } on EspException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    await _transport?.dispose();
    setState(() {
      _transport = null;
      _running = false;
    });
  }

  void _onData(Uint8List data) {
    // Decode leniently: a board mid-boot emits partial UTF-8 and framing noise.
    final text = const Utf8Decoder(allowMalformed: true).convert(data);
    _partial += text.replaceAll('\r', '');

    final parts = _partial.split('\n');
    _partial = parts.removeLast();

    if (parts.isEmpty) return;
    setState(() {
      _lines.addAll(parts);
      if (_lines.length > 3000) _lines.removeRange(0, _lines.length - 3000);
    });

    if (_autoScroll && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  String get _fullText => _lines.join('\n');

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Serial monitor'),
        actions: [
          if (_running)
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_all_rounded),
              onPressed: _lines.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: _fullText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Log copied')),
                      );
                    },
            ),
          if (_running)
            IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: _lines.isEmpty
                  ? null
                  : () => SharePlus.instance.share(
                        ShareParams(
                          text: _fullText,
                          subject: 'SyncN serial log',
                        ),
                      ),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_running) ...[
                const SectionHeader(title: 'Choose the log speed'),
                Text(
                  'The rate is set by your firmware, not by the board. If the '
                  'output looks like random characters, stop and try another.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: p.muted),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _bauds
                      .map((b) => OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 44),
                              side: BorderSide(
                                color: _baud == b ? p.accent : p.line,
                              ),
                              foregroundColor: _baud == b ? p.accent : p.ink,
                            ),
                            onPressed: () => _start(b),
                            child: Text('$b'),
                          ))
                      .toList(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  AdviceBanner(
                    message: _error!,
                    advice: 'Check the cable is seated and no other app holds '
                        'the port, then pick a speed again.',
                    tone: AdviceTone.danger,
                  ),
                ],
                const Spacer(),
              ] else ...[
                Row(
                  children: [
                    SyncnChip(
                      label: '$_baud baud',
                      icon: Icons.speed_rounded,
                      color: p.success,
                    ),
                    const SizedBox(width: 8),
                    SyncnChip(
                      label: '${_lines.length} lines',
                      color: p.muted,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: _autoScroll ? 'Autoscroll on' : 'Autoscroll off',
                      icon: Icon(
                        _autoScroll
                            ? Icons.vertical_align_bottom_rounded
                            : Icons.pause_rounded,
                        color: _autoScroll ? p.accent : p.muted,
                      ),
                      onPressed: () =>
                          setState(() => _autoScroll = !_autoScroll),
                    ),
                    IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => setState(_lines.clear),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: GlassPanel(
                    padding: const EdgeInsets.all(10),
                    child: _lines.isEmpty
                        ? Center(
                            child: Text(
                              'Waiting for output...\n'
                              'Press the board’s RST button if nothing appears.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: p.muted),
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            itemCount: _lines.length,
                            itemBuilder: (_, i) => Text(
                              _lines[i],
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                height: 1.45,
                                color: p.ink,
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Stop and change speed'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
