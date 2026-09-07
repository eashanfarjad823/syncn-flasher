import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../esp/transport.dart';
import '../prefs.dart';
import '../serial/log_session.dart';
import 'ble_setup_screen.dart';
import 'theme.dart';
import 'web_portal_screen.dart';

/// The screen a technician lands on after flashing.
///
/// Everything the post-flash workflow needs lives here at once: the serial log
/// keeps streaming while Wi-Fi is set up over BLE, which matters because the
/// board announces its IP in that log and that is how the portal button
/// unlocks.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({
    super.key,
    required this.device,
    this.macAddress,
    this.title,
  });

  final SerialDeviceInfo device;

  /// MAC read over USB while flashing; used to pick this board out over BLE.
  final String? macAddress;
  final String? title;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final SerialLogSession _session;
  StreamSubscription<void>? _changeSub;
  StreamSubscription<dynamic>? _usbSub;
  final _scroll = ScrollController();
  bool _autoScroll = true;
  String? _rememberedIp;

  @override
  void initState() {
    super.initState();
    _session = SerialLogSession(widget.device);

    _changeSub = _session.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      _persistIp();
      if (_autoScroll) _scrollToEnd();
    });

    // A board reset drops the USB device; nudge the session to re-attach.
    _usbSub = SerialTransport.usbEvents.listen((_) => _session.onUsbEvent());

    _session.start();
    _loadRememberedIp();
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _usbSub?.cancel();
    _session.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadRememberedIp() async {
    final mac = widget.macAddress;
    if (mac == null) return;
    final ip = await Prefs.lastIpFor(mac);
    if (mounted) setState(() => _rememberedIp = ip);
  }

  Future<void> _persistIp() async {
    final ip = _session.detectedIp;
    final mac = widget.macAddress;
    if (ip == null || mac == null) return;
    await Prefs.setLastIp(mac, ip);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// Only an address seen in THIS session unlocks the portal, so a technician
  /// is never sent to an address that DHCP may have reassigned.
  String? get _liveIp => _session.detectedIp;

  Future<void> _openPortal() async {
    final ip = _liveIp;
    if (ip == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => WebPortalScreen(ip: ip)),
    );
  }

  Future<void> _openBleSetup() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => BleSetupScreen(
          flashedMac: widget.macAddress,
          boardLabel: widget.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);
    final ip = _liveIp;
    final lines = _session.lines;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Device'),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: lines.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _session.fullText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Log copied')),
                    );
                  },
          ),
          IconButton(
            tooltip: 'Share log',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: lines.isEmpty
                ? null
                : () => SharePlus.instance.share(
                      ShareParams(
                        text: _session.fullText,
                        subject: 'SyncN serial log',
                      ),
                    ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _chip(
                    p,
                    _session.isRunning ? 'live' : 'disconnected',
                    _session.isRunning ? p.success : p.danger,
                    _session.isRunning
                        ? Icons.circle
                        : Icons.link_off_rounded,
                  ),
                  if (_session.baud != null)
                    _chip(p, '${_session.baud} baud', p.muted, Icons.speed_rounded),
                  if (ip != null)
                    _chip(p, ip, p.accent, Icons.lan_rounded)
                  else if (_rememberedIp != null)
                    _chip(p, 'last: $_rememberedIp', p.muted, Icons.history_rounded),
                  _chip(p, '${lines.length} lines', p.muted, null),
                ],
              ),
            ),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GlassPanel(
                  padding: const EdgeInsets.all(10),
                  child: lines.isEmpty
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
                          itemCount: lines.length,
                          itemBuilder: (_, i) {
                            final l = lines[i];
                            return Text(
                              l.isNote ? '— ${l.text}' : l.text,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                height: 1.45,
                                color: l.isNote ? p.warning : p.ink,
                                fontWeight:
                                    l.isNote ? FontWeight.w600 : FontWeight.w400,
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _autoScroll ? 'Autoscroll on' : 'Autoscroll off',
                    icon: Icon(
                      _autoScroll
                          ? Icons.vertical_align_bottom_rounded
                          : Icons.pause_rounded,
                      color: _autoScroll ? p.accent : p.muted,
                    ),
                    onPressed: () => setState(() => _autoScroll = !_autoScroll),
                  ),
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _session.clear,
                  ),
                  if (!_session.isRunning)
                    TextButton.icon(
                      onPressed: _session.reconnect,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Reconnect'),
                    ),
                  const Spacer(),
                  PopupMenuButton<int>(
                    tooltip: 'Log speed',
                    icon: Icon(Icons.tune_rounded, color: p.muted),
                    onSelected: _session.setBaud,
                    itemBuilder: (_) => const [
                      9600, 19200, 38400, 57600,
                      115200, 230400, 460800, 921600,
                    ]
                        .map((b) =>
                            PopupMenuItem(value: b, child: Text('$b baud')))
                        .toList(),
                  ),
                ],
              ),
            ),

            // The two workflow actions, always visible so the log stays in
            // view while Wi-Fi is being set up.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _openBleSetup,
                      icon: const Icon(Icons.bluetooth_rounded),
                      label: const Text('Wi-Fi setup'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: ip == null ? null : _openPortal,
                      icon: const Icon(Icons.language_rounded),
                      label: Text(ip == null ? 'No IP yet' : 'Open portal'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(SyncnPalette p, String label, Color c, IconData? icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: c.withValues(alpha: p.isDark ? 0.18 : 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 11, color: c),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      );
}
