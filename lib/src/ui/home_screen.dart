import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../esp/protocol.dart';
import '../esp/transport.dart';
import '../flash/firmware.dart';
import '../flash/flash_service.dart';
import 'serial_monitor.dart';
import 'theme.dart';
import 'widgets.dart';

enum _View { setup, flashing, report }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = FlashService();

  List<SerialDeviceInfo> _devices = [];
  SerialDeviceInfo? _selected;
  FirmwareBundle? _bundle;

  _View _view = _View.setup;
  bool _busy = false;
  String? _error;
  String? _errorAdvice;

  FlashProgress? _progress;
  FlashReport? _report;

  StreamSubscription<dynamic>? _usbSub;
  StreamSubscription<FlashProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _loadBundledFirmware();
    _refreshDevices();

    // Re-scan when a board is plugged in or pulled out.
    _usbSub = SerialTransport.usbEvents.listen((_) {
      if (mounted) _refreshDevices();
    });

    _progressSub = _service.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
  }

  @override
  void dispose() {
    _usbSub?.cancel();
    _progressSub?.cancel();
    _service.dispose();
    super.dispose();
  }

  Future<void> _loadBundledFirmware() async {
    try {
      final b = await FirmwareBundle.loadBundled();
      if (mounted) setState(() => _bundle = b);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not read the built-in firmware: $e');
      }
    }
  }

  Future<void> _refreshDevices() async {
    final devices = await SerialTransport.listDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      // Keep the current pick if it is still attached, else take the first.
      if (_selected != null &&
          !devices.any((d) => d.deviceId == _selected!.deviceId)) {
        _selected = null;
      }
      _selected ??= devices.isNotEmpty ? devices.first : null;
    });
  }

  void _setError(String message, [String? advice]) {
    setState(() {
      _error = message;
      _errorAdvice = advice;
    });
  }

  /// Maps a protocol failure onto something a technician can act on.
  ({String message, String advice}) _explain(Object e) {
    final msg = e is EspException ? e.message : e.toString();
    final lower = msg.toLowerCase();

    if (lower.contains('permission')) {
      return (
        message: 'Android did not grant access to the USB device.',
        advice: 'Unplug and replug the board, then tap Allow on the prompt. '
            'Tick "always open" so it stops asking.',
      );
    }
    if (lower.contains('sync handshake') || lower.contains('no response')) {
      return (
        message: 'The board is not answering the bootloader handshake.',
        advice: 'Hold BOOT, tap RST, then release BOOT and try again. Check the '
            'board has its own 12V supply — USB-C alone may not power it.',
      );
    }
    if (lower.contains('checksum') || lower.contains('corrupt')) {
      return (
        message: 'Data is being corrupted between the phone and the board.',
        advice: 'Try a different USB-C cable, or retry — the app will drop to a '
            'slower, more tolerant speed.',
      );
    }
    if (lower.contains('could not act')) {
      return (
        message: 'The board rejected a command part-way through the sequence.',
        advice: 'Disconnect, reconnect, and flash again. If this happened '
            'during a full chip erase, the flash may now be blank — reflash '
            'with "Only what is being written" to restore the board.',
      );
    }
    if (lower.contains('unbootable') || lower.contains('targets')) {
      return (
        message: msg,
        advice: 'Pick firmware built for this exact chip before flashing.',
      );
    }
    return (
      message: msg,
      advice: 'Unplug the board, plug it back in, and try again.',
    );
  }

  Future<void> _connect({bool manual = false}) async {
    final device = _selected;
    if (device == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _errorAdvice = null;
    });

    try {
      await _service.connect(device, manualMode: manual);
      if (mounted) setState(() {});
    } on ManualBootRequired {
      if (!mounted) return;
      final retry = await _showManualBootDialog();
      if (retry == true) {
        setState(() => _busy = false);
        return _connect(manual: true);
      }
      _setError(
        'Could not put the board into download mode automatically.',
        'This board may not wire the auto-reset transistors. Use the manual '
            'BOOT/RST steps and try again.',
      );
    } catch (e) {
      final x = _explain(e);
      _setError(x.message, x.advice);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _showManualBootDialog() {
    final p = SyncnPalette.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Put the board in download mode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Auto-reset did not work on this board, so do it by hand:',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            _step(ctx, '1', 'Press and hold the BOOT button.'),
            _step(ctx, '2', 'While holding BOOT, tap RST once.'),
            _step(ctx, '3', 'Release BOOT.'),
            const SizedBox(height: 12),
            Text(
              'The board is now waiting for firmware and will stay that way '
              'until it is reset again.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: p.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Done - connect'),
          ),
        ],
      ),
    );
  }

  Widget _step(BuildContext ctx, String n, String text) {
    final p = SyncnPalette.of(ctx);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: p.accent.withValues(alpha: 0.5)),
            ),
            child: Text(
              n,
              style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                    color: p.accent,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(ctx).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFirmware() async {
    try {
      final b = await FirmwareBundle.pickFromDevice();
      if (b != null && mounted) setState(() => _bundle = b);
    } catch (e) {
      _setError('Could not read the selected files.', '$e');
    }
  }

  Future<void> _useBundled() async {
    await _loadBundledFirmware();
  }

  Future<void> _identify() async {
    setState(() => _busy = true);
    try {
      final info = await _service.identify();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Board details'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in info.entries)
                DetailRow(label: e.key, value: e.value, mono: true),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      final x = _explain(e);
      _setError(x.message, x.advice);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startFlash() async {
    final bundle = _bundle;
    if (bundle == null) return;

    final options = await _showConfirmSheet(bundle);
    if (options == null) return;

    setState(() {
      _view = _View.flashing;
      _error = null;
      _progress = null;
    });

    final report = await _service.flash(bundle, options: options);

    if (!mounted) return;
    setState(() {
      _report = report;
      _view = _View.report;
    });
  }

  /// The confirmation gate. Nothing is written until this returns options.
  Future<FlashOptions?> _showConfirmSheet(FirmwareBundle bundle) {
    final p = SyncnPalette.of(context);
    final chip = _service.chip;
    final imageChip = bundle.effectiveChip;
    final mismatch =
        chip != null && imageChip != null && chip.name != imageChip.name;

    var erase = EraseMode.writtenRegions;
    var backup = false;

    return showModalBottomSheet<FlashOptions>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(SyncnRadius.xl)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: p.line,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text('Confirm flash',
                    style: Theme.of(ctx).textTheme.headlineSmall),
                const SizedBox(height: 14),

                if (mismatch)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: AdviceBanner(
                      tone: AdviceTone.danger,
                      message:
                          'This firmware targets ${imageChip.name}, but the '
                          'connected board is ${chip.name}.',
                      advice:
                          'Writing it will leave the board unable to boot. '
                          'Flashing is blocked.',
                    ),
                  ),

                DetailRow(label: 'Firmware', value: bundle.name),
                if (bundle.version.isNotEmpty)
                  DetailRow(label: 'Version', value: bundle.version),
                DetailRow(
                    label: 'Target', value: imageChip?.name ?? 'unknown'),
                DetailRow(label: 'Board', value: chip?.name ?? 'not connected'),
                if (_service.macAddress != null)
                  DetailRow(
                      label: 'MAC', value: _service.macAddress!, mono: true),
                DetailRow(label: 'Total', value: bundle.totalLabel),

                const SizedBox(height: 14),
                const SectionHeader(title: 'Regions to write'),
                ...bundle.parts.map(
                  (part) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 82,
                          child: Text(
                            part.offsetLabel,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: p.accent,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(part.fileName,
                              style: Theme.of(ctx).textTheme.bodyMedium),
                        ),
                        Text(
                          part.sizeLabel,
                          style: Theme.of(ctx)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: p.muted),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 14),
                const SectionHeader(title: 'Erase'),
                RadioGroup<EraseMode>(
                  groupValue: erase,
                  onChanged: (v) => setSheet(() => erase = v!),
                  child: Column(
                    children: [
                      RadioListTile<EraseMode>(
                        value: EraseMode.writtenRegions,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Only what is being written'),
                        subtitle: const Text(
                            'Keeps Wi-Fi credentials and stored settings.'),
                      ),
                      RadioListTile<EraseMode>(
                        value: EraseMode.fullChip,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Erase the whole chip'),
                        subtitle: const Text(
                            'Wipes settings. The board needs setting up again.'),
                      ),
                    ],
                  ),
                ),

                SwitchListTile(
                  value: backup,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setSheet(() => backup = v),
                  title: const Text('Back up current firmware first'),
                  subtitle: const Text(
                    'Not available yet - needs the stub loader.',
                  ),
                ),

                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: mismatch
                            ? null
                            : () => Navigator.pop(
                                  ctx,
                                  FlashOptions(
                                    eraseMode: erase,
                                    backupFirst: backup,
                                  ),
                                ),
                        child: const Text('Flash now'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              p.isDark
                  ? 'assets/brand/syncn-logo-dark.png'
                  : 'assets/brand/syncn-logo-light.png',
              height: 22,
            ),
            const SizedBox(width: 10),
            const Text('Flasher'),
          ],
        ),
        actions: [
          if (_view == _View.setup)
            IconButton(
              tooltip: 'Rescan',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _busy ? null : _refreshDevices,
            ),
        ],
      ),
      body: SafeArea(
        child: switch (_view) {
          _View.setup => _buildSetup(p),
          _View.flashing => _buildFlashing(p),
          _View.report => _buildReport(p),
        },
      ),
    );
  }

  Widget _buildSetup(SyncnPalette p) {
    final connected = _service.isConnected && _service.chip != null;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_error != null) ...[
          AdviceBanner(
            message: _error!,
            advice: _errorAdvice,
            tone: AdviceTone.danger,
          ),
          const SizedBox(height: 16),
        ],

        const SectionHeader(title: 'Board'),
        GlassPanel(
          child: _devices.isEmpty
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.usb_off_rounded, color: p.muted, size: 18),
                        const SizedBox(width: 10),
                        Text('No board detected',
                            style: Theme.of(context).textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Connect the KinCony board to this phone with a USB-C to '
                      'USB-C cable. Power the board from its own 12V supply.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: p.muted),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final d in _devices)
                      InkWell(
                        onTap: connected
                            ? null
                            : () => setState(() => _selected = d),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                d.deviceId == _selected?.deviceId
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                size: 18,
                                color: d.deviceId == _selected?.deviceId
                                    ? p.accent
                                    : p.muted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(d.bridgeName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall),
                                    Text(d.vidPid,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          color: p.muted,
                                        )),
                                  ],
                                ),
                              ),
                              if (d.isNativeUsb)
                                const SyncnChip(label: 'native USB'),
                            ],
                          ),
                        ),
                      ),
                    if (connected) ...[
                      Divider(height: 20, color: p.lineSoft),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          SyncnChip(
                            label: _service.chip!.name,
                            icon: Icons.memory_rounded,
                            color: p.success,
                          ),
                          if (_service.macAddress != null)
                            SyncnChip(label: _service.macAddress!),
                        ],
                      ),
                    ],
                  ],
                ),
        ),

        const SizedBox(height: 12),
        if (!connected)
          FilledButton.icon(
            onPressed: (_busy || _selected == null) ? null : () => _connect(),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link_rounded),
            label: Text(_busy ? 'Connecting...' : 'Connect'),
          )
        else
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _identify,
                  icon: const Icon(Icons.info_outline_rounded),
                  label: const Text('Details'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await _service.disconnect();
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.link_off_rounded),
                  label: const Text('Disconnect'),
                ),
              ),
            ],
          ),

        const SizedBox(height: 24),
        SectionHeader(
          title: 'Firmware',
          trailing: TextButton.icon(
            onPressed: _pickFirmware,
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('Choose files'),
          ),
        ),
        GlassPanel(child: _buildFirmwareCard(p)),

        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed:
              (!connected || _bundle == null || _busy) ? null : _startFlash,
          icon: const Icon(Icons.bolt_rounded),
          label: const Text('Flash firmware'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _selected == null
              ? null
              : () async {
                  await _service.disconnect();
                  if (!mounted) return;
                  setState(() {});
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SerialMonitorScreen(device: _selected!),
                    ),
                  );
                },
          icon: const Icon(Icons.terminal_rounded),
          label: const Text('Serial monitor'),
        ),
      ],
    );
  }

  Widget _buildFirmwareCard(SyncnPalette p) {
    final b = _bundle;
    if (b == null) {
      return Text(
        'No firmware loaded.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted),
      );
    }

    final app = b.parts.where((x) => x.label == 'application').firstOrNull;
    final desc = app?.appDescriptor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(b.name,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (b.isBundled)
              const SyncnChip(label: 'built in')
            else
              SyncnChip(label: 'picked', color: p.warning),
          ],
        ),
        const SizedBox(height: 10),
        if (b.version.isNotEmpty)
          DetailRow(label: 'Version', value: b.version),
        DetailRow(
          label: 'Target',
          value: b.effectiveChip?.name ?? 'unknown',
        ),
        if (b.flashSize > 0)
          DetailRow(
            label: 'Flash',
            value: '${b.flashSize >> 20} MB, ${b.flashMode.toUpperCase()} '
                '@ ${b.flashFreq}',
          ),
        DetailRow(label: 'Files', value: '${b.parts.length}  (${b.totalLabel})'),
        if (desc != null)
          DetailRow(label: 'Built', value: desc.buildStamp),
        if (!b.isBundled)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TextButton.icon(
              onPressed: _useBundled,
              icon: const Icon(Icons.undo_rounded, size: 16),
              label: const Text('Back to built-in firmware'),
            ),
          ),
      ],
    );
  }

  Widget _buildFlashing(SyncnPalette p) {
    final prog = _progress;
    final pct = ((prog?.overall ?? 0) * 100).clamp(0, 100).toStringAsFixed(0);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Text('$pct%',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displayMedium),
          const SizedBox(height: 8),
          Text(
            prog?.message ?? 'Starting...',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: prog?.overall,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 14),
          if (prog != null && prog.totalBytes > 0)
            Text(
              '${(prog.bytesWritten / 1024).toStringAsFixed(0)} of '
              '${(prog.totalBytes / 1024).toStringAsFixed(0)} KB'
              '${prog.partLabel != null ? "   ·   ${prog.partLabel}" : ""}'
              '${prog.partIndex != null ? " (${prog.partIndex}/${prog.partCount})" : ""}',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: p.muted),
            ),
          const SizedBox(height: 24),
          AdviceBanner(
            tone: AdviceTone.info,
            message: 'Keep the cable connected.',
            advice: 'Unplugging now leaves the board part-written and it will '
                'not boot until flashing finishes.',
          ),
          const Spacer(),
          OutlinedButton(
            onPressed: _service.cancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildReport(SyncnPalette p) {
    final r = _report!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AdviceBanner(
          tone: r.success ? AdviceTone.success : AdviceTone.danger,
          message: r.success
              ? 'Firmware written and verified.'
              : 'Flash failed.',
          advice: r.success
              ? 'Took ${(r.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s '
                  'at ${r.baudRate} baud.'
              : _explain(EspException(r.error ?? 'Unknown error')).advice,
        ),
        const SizedBox(height: 18),

        const SectionHeader(title: 'Result'),
        GlassPanel(
          child: Column(
            children: [
              DetailRow(label: 'Firmware', value: r.bundleName),
              if (r.bundleVersion.isNotEmpty)
                DetailRow(label: 'Version', value: r.bundleVersion),
              DetailRow(label: 'Chip', value: r.chipName ?? 'unknown'),
              if (r.macAddress != null)
                DetailRow(label: 'MAC', value: r.macAddress!, mono: true),
              DetailRow(label: 'Bridge', value: r.bridge ?? 'unknown'),
              DetailRow(label: 'Speed', value: '${r.baudRate ?? "-"} baud'),
              DetailRow(
                label: 'Elapsed',
                value:
                    '${(r.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),
        const SectionHeader(title: 'Regions'),
        GlassPanel(
          child: Column(
            children: [
              for (final part in r.parts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        switch (part.verified) {
                          true => Icons.check_circle_rounded,
                          false => Icons.cancel_rounded,
                          null => Icons.remove_circle_outline_rounded,
                        },
                        size: 16,
                        color: switch (part.verified) {
                          true => p.success,
                          false => p.danger,
                          null => p.muted,
                        },
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(part.fileName,
                                style:
                                    Theme.of(context).textTheme.titleSmall),
                            Text(
                              // Never claim verification that did not happen.
                              switch (part.verified) {
                                true => '${part.offsetLabel} · verified',
                                false =>
                                  '${part.offsetLabel} · checksum mismatch',
                                null => '${part.offsetLabel} · not verified',
                              },
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: p.muted,
                              ),
                            ),
                            if (part.error != null)
                              Text(
                                part.error!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: p.warning),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        if (r.success)
          FilledButton.icon(
            onPressed: () async {
              final device = _selected;
              await _service.disconnect();
              if (!mounted || device == null) return;
              setState(() => _view = _View.setup);
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SerialMonitorScreen(device: device),
                ),
              );
            },
            icon: const Icon(Icons.terminal_rounded),
            label: const Text('Open serial monitor'),
          )
        else
          FilledButton.icon(
            onPressed: () => setState(() => _view = _View.setup),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => SharePlus.instance.share(
            ShareParams(text: r.toText(), subject: 'SyncN flash report'),
          ),
          icon: const Icon(Icons.ios_share_rounded),
          label: const Text('Share report and log'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => setState(() => _view = _View.setup),
          child: const Text('Back'),
        ),
      ],
    );
  }
}
