import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/ble_provisioning.dart';
import '../prefs.dart';
import 'theme.dart';
import 'widgets.dart';

/// Commissions a board's Wi-Fi over BLE.
///
/// Tries to go straight to the board just flashed by matching its MAC, and
/// falls back to a picker when that match does not land — an ESP32's BLE
/// address is usually offset from the Wi-Fi MAC we read over USB, so the
/// fallback matters.
class BleSetupScreen extends StatefulWidget {
  const BleSetupScreen({super.key, this.flashedMac, this.boardLabel});

  /// MAC read over USB during flashing, used to pick the right board.
  final String? flashedMac;
  final String? boardLabel;

  @override
  State<BleSetupScreen> createState() => _BleSetupScreenState();
}

class _BleSetupScreenState extends State<BleSetupScreen> {
  final _ble = BleProvisioningService();
  final _ssidCtl = TextEditingController();
  final _passCtl = TextEditingController();

  BleStage _stage = BleStage.idle;
  List<BleCandidate> _candidates = [];
  String? _message;
  String? _advice;
  bool _obscure = true;
  List<String> _knownSsids = [];
  final _transcript = <String>[];
  StreamSubscription<String>? _respSub;

  @override
  void initState() {
    super.initState();
    _respSub = _ble.responses.listen((r) {
      if (mounted) setState(() => _transcript.add(r));
    });
    _loadSsids();
    _begin();
  }

  @override
  void dispose() {
    _respSub?.cancel();
    _ble.dispose();
    _ssidCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  Future<void> _loadSsids() async {
    final s = await Prefs.knownSsids();
    if (mounted) {
      setState(() {
        _knownSsids = s;
        if (_ssidCtl.text.isEmpty && s.isNotEmpty) _ssidCtl.text = s.first;
      });
    }
  }

  void _set(BleStage stage, {String? message, String? advice}) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      _message = message;
      _advice = advice;
    });
  }

  Future<void> _begin() async {
    // One check covers every reason BLE might be unusable — no radio, radio
    // off, permission denied, or the location requirement that Android 11 and
    // older impose on scanning.
    final blocked = await _ble.checkAvailability();
    if (blocked != null) {
      _set(BleStage.unavailable,
          message: blocked.message, advice: blocked.advice);
      return;
    }

    await _scan();
  }

  Future<void> _scan() async {
    _set(BleStage.scanning, message: 'Looking for the board...');
    try {
      final found = await _ble.scan(flashedMac: widget.flashedMac);
      if (!mounted) return;

      if (found.isEmpty) {
        _set(BleStage.notFound,
            message: 'No SyncN board is advertising over Bluetooth.',
            advice: 'The board advertises when it cannot join Wi-Fi. Power-cycle '
                'it and try again within a minute, or check whether it needs a '
                'button press to enter setup mode. On Android 11 or older, BLE '
                'scanning also needs permissions this app does not request.');
        return;
      }

      setState(() => _candidates = found);

      // One-tap path: exactly one board matching the MAC we just flashed.
      final exact = found.where((c) => c.matchesFlashedBoard).toList();
      if (exact.length == 1) {
        await _connect(exact.first);
      } else {
        _set(BleStage.idle, message: 'Select the board to configure.');
      }
    } catch (e) {
      _set(BleStage.failed,
          message: 'Bluetooth scan failed.',
          advice: 'BLE setup needs Android 12 or newer, with Bluetooth '
              'permission granted. ($e)');
    }
  }

  Future<void> _connect(BleCandidate c) async {
    _set(BleStage.connecting, message: 'Connecting to ${c.name}...');
    try {
      await _ble.connect(c);
      _set(BleStage.ready, message: 'Connected to ${c.name}.');
    } catch (e) {
      _set(BleStage.failed,
          message: 'Could not connect to ${c.name}.',
          advice: 'Move closer to the board and try again. ($e)');
    }
  }

  Future<void> _sendWifi() async {
    final ssid = _ssidCtl.text.trim();
    final pass = _passCtl.text;

    final problem = BleProvisioningService.validate(ssid, pass);
    if (problem != null) {
      _set(BleStage.ready, message: problem);
      return;
    }

    _set(BleStage.sending, message: 'Sending credentials...');
    try {
      final reply = await _ble.sendWifi(ssid, pass);
      await Prefs.rememberSsid(ssid);
      await _loadSsids();

      if (BleProvisioningService.isError(reply)) {
        _set(BleStage.failed, message: reply, advice: _adviceFor(reply));
      } else {
        _set(BleStage.success,
            message: reply,
            advice: 'Watch the serial monitor — the board prints its IP once '
                'it joins the network, and the portal button unlocks then.');
      }
    } catch (e) {
      _set(BleStage.failed,
          message: 'The board did not answer.',
          advice: 'It may have left setup mode. Power-cycle it and scan again. ($e)');
    }
  }

  String _adviceFor(String reply) {
    final r = reply.toUpperCase();
    if (r.contains('UNABLE TO CONNECT')) {
      return 'The board could not join that network. Check the password and '
          'that the network is 2.4GHz — ESP32 cannot use 5GHz.';
    }
    if (r.contains('SSID IS EMPTY')) return 'Enter a network name.';
    return 'Check the details and try again.';
  }

  Future<void> _simpleCommand(
    Future<String> Function() run,
    String label,
  ) async {
    _set(BleStage.sending, message: '$label...');
    try {
      final reply = await run();
      _set(BleStage.ready, message: reply);
    } catch (e) {
      _set(BleStage.failed, message: '$label failed.', advice: '$e');
    }
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear saved Wi-Fi?'),
        content: const Text(
          'This erases every Wi-Fi network saved on the board and restarts it. '
          'The board will need setting up again before it can reach the network.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SyncnPalette.of(context).danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear and restart'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _simpleCommand(_ble.requestReset, 'Clearing Wi-Fi');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);
    final busy = _stage == BleStage.scanning ||
        _stage == BleStage.connecting ||
        _stage == BleStage.sending;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi setup over Bluetooth'),
        actions: [
          if (!busy)
            IconButton(
              tooltip: 'Scan again',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _scan,
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_message != null) ...[
              AdviceBanner(
                tone: switch (_stage) {
                  BleStage.success || BleStage.ready => AdviceTone.success,
                  BleStage.failed ||
                  BleStage.unavailable ||
                  BleStage.notFound =>
                    AdviceTone.danger,
                  _ => AdviceTone.info,
                },
                message: _message!,
                advice: _advice,
              ),
              const SizedBox(height: 16),
            ],

            if (busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
            ],

            if (_stage == BleStage.unavailable || _stage == BleStage.notFound)
              FilledButton.icon(
                onPressed: busy ? null : _begin,
                icon: const Icon(Icons.bluetooth_searching_rounded),
                label: const Text('Check again'),
              ),

            // Picker: shown when the MAC match did not give exactly one board.
            if (!_ble.isConnected && _candidates.isNotEmpty) ...[
              const SectionHeader(title: 'Boards found'),
              GlassPanel(
                child: Column(
                  children: [
                    for (final c in _candidates)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.bluetooth_rounded,
                          color: c.matchesFlashedBoard ? p.success : p.muted,
                        ),
                        title: Text(c.name,
                            style: Theme.of(context).textTheme.titleSmall),
                        subtitle: Text(
                          '${c.id}   ${c.rssi} dBm'
                          '${c.matchesFlashedBoard ? "   · just flashed" : ""}',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: p.muted),
                        ),
                        onTap: busy ? null : () => _connect(c),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            if (_ble.isConnected) ...[
              const SectionHeader(title: 'Wi-Fi network'),
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _ssidCtl,
                      decoration: InputDecoration(
                        labelText: 'Network name (SSID)',
                        suffixIcon: _knownSsids.isEmpty
                            ? null
                            : PopupMenuButton<String>(
                                icon: const Icon(Icons.history_rounded),
                                tooltip: 'Previously used',
                                onSelected: (v) => _ssidCtl.text = v,
                                itemBuilder: (_) => _knownSsids
                                    .map((s) => PopupMenuItem(
                                        value: s, child: Text(s)))
                                    .toList(),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passCtl,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'The board only joins 2.4GHz networks.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: p.muted),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: busy ? null : _sendWifi,
                      icon: const Icon(Icons.wifi_rounded),
                      label: const Text('Send Wi-Fi credentials'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              const SectionHeader(title: 'Device actions'),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => _simpleCommand(
                              _ble.requestStatus, 'Reading status'),
                      icon: const Icon(Icons.info_outline_rounded),
                      label: const Text('Status'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                      onPressed: busy ? null : _confirmReset,
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Clear Wi-Fi'),
                    ),
                  ),
                ],
              ),
            ],

            if (_transcript.isNotEmpty) ...[
              const SizedBox(height: 20),
              const SectionHeader(title: 'Device replies'),
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in _transcript.reversed.take(12))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          r,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: BleProvisioningService.isError(r)
                                ? p.danger
                                : p.ink,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
