import 'dart:async';
import 'dart:typed_data';

import 'package:wakelock_plus/wakelock_plus.dart';

import '../esp/loader.dart';
import '../esp/protocol.dart';
import '../esp/transport.dart';
import 'firmware.dart';

/// What the flasher is doing right now.
enum FlashStage {
  idle,
  connecting,
  syncing,
  identifying,
  erasing,
  writing,
  verifying,
  rebooting,
  done,
  failed,
}

/// How much of the chip to erase before writing.
enum EraseMode {
  /// Erase only the sectors being written, preserving NVS (Wi-Fi credentials)
  /// and any filesystem.
  writtenRegions,

  /// Blank the entire chip. Wipes stored settings; the board needs
  /// re-provisioning afterwards.
  fullChip,
}

class FlashOptions {
  const FlashOptions({
    this.eraseMode = EraseMode.writtenRegions,
    this.backupFirst = false,
    this.verifyMd5 = true,
    this.rebootAfter = true,
    this.baudCandidates = const [921600, 460800, 115200],
  });

  final EraseMode eraseMode;

  /// Requires the software stub loader, which this version does not upload.
  final bool backupFirst;

  final bool verifyMd5;
  final bool rebootAfter;

  /// Tried fastest-first; the first rate the link sustains is used.
  final List<int> baudCandidates;
}

/// Snapshot of flashing progress, emitted continuously during a run.
class FlashProgress {
  const FlashProgress({
    required this.stage,
    required this.message,
    this.overall = 0,
    this.partLabel,
    this.partIndex,
    this.partCount,
    this.bytesWritten = 0,
    this.totalBytes = 0,
    this.elapsed = Duration.zero,
  });

  final FlashStage stage;
  final String message;

  /// 0..1 across the whole job.
  final double overall;

  final String? partLabel;
  final int? partIndex;
  final int? partCount;
  final int bytesWritten;
  final int totalBytes;
  final Duration elapsed;

  bool get isTerminal => stage == FlashStage.done || stage == FlashStage.failed;
}

/// Outcome of writing a single image.
class PartResult {
  PartResult({
    required this.label,
    required this.fileName,
    required this.offset,
    required this.size,
    required this.localMd5,
    this.boardMd5,
    this.verified,
    this.error,
  });

  final String label;
  final String fileName;
  final int offset;
  final int size;
  final String localMd5;
  String? boardMd5;
  bool? verified;
  String? error;

  String get offsetLabel =>
      '0x${offset.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}

/// Everything worth recording about one flash attempt.
class FlashReport {
  FlashReport({
    required this.startedAt,
    required this.bundleName,
    required this.bundleVersion,
  });

  final DateTime startedAt;
  final String bundleName;
  final String bundleVersion;

  String? chipName;
  String? macAddress;
  String? bridge;
  int? baudRate;
  Duration elapsed = Duration.zero;
  bool success = false;
  String? error;
  final List<PartResult> parts = [];
  List<String> trace = const [];

  int get bytesWritten => parts.fold(0, (s, p) => s + p.size);

  /// Plain-text report for sharing into a support ticket.
  String toText() {
    final b = StringBuffer()
      ..writeln('SyncN Flasher report')
      ..writeln('====================')
      ..writeln('When      : ${startedAt.toLocal()}')
      ..writeln('Result    : ${success ? "SUCCESS" : "FAILED"}')
      ..writeln('Firmware  : $bundleName $bundleVersion')
      ..writeln('Chip      : ${chipName ?? "unknown"}')
      ..writeln('MAC       : ${macAddress ?? "unknown"}')
      ..writeln('Bridge    : ${bridge ?? "unknown"}')
      ..writeln('Baud      : ${baudRate ?? "-"}')
      ..writeln('Elapsed   : ${elapsed.inMilliseconds / 1000}s')
      ..writeln('Written   : $bytesWritten bytes');
    if (error != null) b.writeln('Error     : $error');
    b.writeln('');
    b.writeln('Regions:');
    for (final p in parts) {
      final v = switch (p.verified) {
        true => 'verified',
        false => 'MISMATCH',
        null => 'not verified',
      };
      b.writeln('  ${p.offsetLabel}  ${p.fileName}  ${p.size} B  $v');
      if (p.boardMd5 != null) {
        b.writeln('       local md5 ${p.localMd5}');
        b.writeln('       board md5 ${p.boardMd5}');
      }
      if (p.error != null) b.writeln('       error: ${p.error}');
    }
    if (trace.isNotEmpty) {
      b..writeln('')..writeln('Protocol trace:');
      for (final line in trace) {
        b.writeln('  $line');
      }
    }
    return b.toString();
  }
}

/// Raised when auto-reset could not put the board into download mode and the
/// user must press BOOT/RST by hand.
class ManualBootRequired implements Exception {
  const ManualBootRequired();
}

/// Drives a complete flash: connect, identify, write, verify, reboot.
class FlashService {
  FlashService();

  SerialTransport? _transport;
  EspLoader? _loader;
  bool _cancelled = false;

  final _progress = StreamController<FlashProgress>.broadcast();
  Stream<FlashProgress> get progress => _progress.stream;

  EspChip? get chip => _loader?.chip;
  String? get macAddress => _loader?.macAddress;
  SerialDeviceInfo? get device => _transport?.info;
  bool get isConnected => _transport?.isOpen ?? false;

  void _emit(
    FlashStage stage,
    String message, {
    double overall = 0,
    String? partLabel,
    int? partIndex,
    int? partCount,
    int bytesWritten = 0,
    int totalBytes = 0,
    Duration elapsed = Duration.zero,
  }) {
    if (_progress.isClosed) return;
    _progress.add(FlashProgress(
      stage: stage,
      message: message,
      overall: overall.clamp(0, 1),
      partLabel: partLabel,
      partIndex: partIndex,
      partCount: partCount,
      bytesWritten: bytesWritten,
      totalBytes: totalBytes,
      elapsed: elapsed,
    ));
  }

  void cancel() => _cancelled = true;

  void _checkCancelled() {
    if (_cancelled) throw EspException('Cancelled by user.');
  }

  /// Opens the port and gets the board into its ROM download mode.
  ///
  /// Escalates through the two automatic reset sequences; if neither works the
  /// caller is told to walk the user through the manual BOOT/RST procedure and
  /// then call again with [manualMode] set.
  Future<void> connect(
    SerialDeviceInfo info, {
    bool manualMode = false,
  }) async {
    _cancelled = false;
    _emit(FlashStage.connecting, 'Opening ${info.bridgeName}...');

    await disconnect();
    final transport = SerialTransport(info);
    await transport.open(baudRate: 115200);
    _transport = transport;

    final loader = EspLoader(transport);
    _loader = loader;

    if (manualMode) {
      // The user has already held BOOT and tapped RST; just handshake.
      _emit(FlashStage.syncing, 'Listening for the bootloader...');
      await loader.sync(attempts: 20);
    } else {
      var synced = false;

      _emit(FlashStage.syncing, 'Resetting the board into download mode...');
      try {
        await transport.enterDownloadModeClassic();
        await loader.sync(attempts: 8);
        synced = true;
      } on EspException {
        _checkCancelled();
      }

      // Parts driven through their own USB peripheral need a different
      // sequence, since DTR/RTS are handled on-die rather than by transistors.
      if (!synced && info.isNativeUsb) {
        _emit(FlashStage.syncing, 'Trying the native-USB reset sequence...');
        try {
          await transport.enterDownloadModeUsbJtag();
          await loader.sync(attempts: 8);
          synced = true;
        } on EspException {
          _checkCancelled();
        }
      }

      if (!synced) throw const ManualBootRequired();
    }

    _emit(FlashStage.identifying, 'Identifying the chip...');
    await loader.detectChip();
    await loader.readMac();
    _emit(
      FlashStage.identifying,
      'Found ${loader.chip?.name}${loader.macAddress != null ? " (${loader.macAddress})" : ""}',
    );
  }

  /// Read-only inspection: chip, MAC and link details, with nothing written.
  Future<Map<String, String>> identify() async {
    final loader = _requireLoader();
    final info = _transport!.info;
    return {
      'Chip': loader.chip?.name ?? 'unknown',
      'MAC address': loader.macAddress ?? 'unavailable',
      'USB bridge': info.bridgeName,
      'USB ID': info.vidPid,
      'Link speed': '${_transport!.baudRate} baud',
      'Native USB': info.isNativeUsb ? 'yes' : 'no',
    };
  }

  /// Writes [bundle] to the connected board.
  Future<FlashReport> flash(
    FirmwareBundle bundle, {
    FlashOptions options = const FlashOptions(),
  }) async {
    final loader = _requireLoader();
    final transport = _transport!;
    final stopwatch = Stopwatch()..start();

    final report = FlashReport(
      startedAt: DateTime.now(),
      bundleName: bundle.name,
      bundleVersion: bundle.version,
    )
      ..chipName = loader.chip?.name
      ..macAddress = loader.macAddress
      ..bridge = transport.info.bridgeName;

    // Keep the display on so a 30-60s write is not cut short by the screen
    // sleeping mid-transfer.
    try {
      await WakelockPlus.enable();
    } catch (_) {
      // Not fatal: a phone that refuses the wakelock can still flash.
    }

    try {
      _cancelled = false;

      final chip = loader.chip;
      final imageChip = bundle.effectiveChip;
      if (chip != null && imageChip != null && chip.name != imageChip.name) {
        throw EspException(
          'This firmware targets ${imageChip.name} but the connected board is '
          '${chip.name}. Writing it would leave the board unbootable.',
          recoverable: false,
        );
      }

      final flashSize =
          bundle.flashSize > 0 ? bundle.flashSize : 4 * 1024 * 1024;

      _emit(FlashStage.connecting, 'Preparing the flash controller...');
      await loader.spiAttach();
      await loader.spiSetParams(flashSize: flashSize);

      report.baudRate = await _negotiateBaud(loader, options.baudCandidates);
      _emit(FlashStage.connecting, 'Link running at ${report.baudRate} baud');

      if (options.backupFirst && !loader.supportsFlashRead) {
        // Surfaced rather than silently skipped: the user asked for a backup
        // and must know it did not happen.
        report.parts.add(PartResult(
          label: 'backup',
          fileName: '-',
          offset: 0,
          size: 0,
          localMd5: '',
          error: 'Backup needs the stub loader, which this version does not '
              'upload. No backup was taken.',
        ));
      }

      if (options.eraseMode == EraseMode.fullChip) {
        _emit(FlashStage.erasing, 'Erasing the whole chip (this takes a while)...');
        await _eraseWholeChip(loader, flashSize);
      }

      final total = bundle.totalBytes;
      var written = 0;

      for (var i = 0; i < bundle.parts.length; i++) {
        _checkCancelled();
        final part = bundle.parts[i];
        final result = PartResult(
          label: part.label,
          fileName: part.fileName,
          offset: part.offset,
          size: part.size,
          localMd5: part.md5Hex,
        );
        report.parts.add(result);

        _emit(
          FlashStage.erasing,
          'Erasing ${part.label} at ${part.offsetLabel}...',
          overall: total == 0 ? 0 : written / total,
          partLabel: part.label,
          partIndex: i + 1,
          partCount: bundle.parts.length,
          bytesWritten: written,
          totalBytes: total,
          elapsed: stopwatch.elapsed,
        );

        await loader.flashBegin(offset: part.offset, size: part.size);

        const blockSize = EspProto.romFlashWriteSize;
        var seq = 0;
        for (var pos = 0; pos < part.size; pos += blockSize) {
          _checkCancelled();
          final end =
              (pos + blockSize) > part.size ? part.size : pos + blockSize;
          var block = Uint8List.sublistView(part.bytes, pos, end);

          // The ROM requires full-length blocks; pad the tail with 0xFF, the
          // erased state of NOR flash.
          if (block.length < blockSize) {
            final padded = Uint8List(blockSize)..fillRange(0, blockSize, 0xFF);
            padded.setRange(0, block.length, block);
            block = padded;
          }

          await loader.flashBlock(block, seq++);
          written += end - pos;

          _emit(
            FlashStage.writing,
            'Writing ${part.label}...',
            overall: total == 0 ? 0 : written / total,
            partLabel: part.label,
            partIndex: i + 1,
            partCount: bundle.parts.length,
            bytesWritten: written,
            totalBytes: total,
            elapsed: stopwatch.elapsed,
          );
        }

        // Deliberately no FLASH_END here. The ROM allows a fresh FLASH_BEGIN to
        // re-arm the state machine for the next region, and that is the
        // sequence esptool itself uses: begin/blocks per file, with a single
        // FLASH_END once every region has been written. Ending each region
        // individually risks the ROM rejecting the command mid-transfer.

        if (options.verifyMd5) {
          _emit(
            FlashStage.verifying,
            'Verifying ${part.label}...',
            overall: total == 0 ? 0 : written / total,
            partLabel: part.label,
            partIndex: i + 1,
            partCount: bundle.parts.length,
            bytesWritten: written,
            totalBytes: total,
            elapsed: stopwatch.elapsed,
          );
          try {
            final boardMd5 =
                await loader.flashMd5(offset: part.offset, size: part.size);
            result
              ..boardMd5 = boardMd5
              ..verified = boardMd5.toLowerCase() == part.md5Hex.toLowerCase();
            if (result.verified == false) {
              throw EspException(
                'Checksum mismatch on ${part.label} at ${part.offsetLabel}. '
                'The data on the board does not match the file.',
              );
            }
          } on EspException catch (e) {
            result.error = e.message;
            rethrow;
          }
        }
      }

      // Final integrity pass: re-checksum EVERY region now that all writes are
      // finished.
      //
      // Per-region verification runs before the following regions are written,
      // so on its own it cannot prove that a later FLASH_BEGIN did not erase an
      // earlier region. Re-reading every checksum at the end closes that gap and
      // turns "each region was right when written" into "the whole flash is
      // right now".
      if (options.verifyMd5 && bundle.parts.length > 1) {
        _emit(
          FlashStage.verifying,
          'Final check of all regions...',
          overall: 1,
          bytesWritten: written,
          totalBytes: total,
          elapsed: stopwatch.elapsed,
        );
        for (var i = 0; i < bundle.parts.length; i++) {
          final part = bundle.parts[i];
          final boardMd5 =
              await loader.flashMd5(offset: part.offset, size: part.size);
          final ok = boardMd5.toLowerCase() == part.md5Hex.toLowerCase();
          report.parts[i].boardMd5 = boardMd5;
          report.parts[i].verified = ok;
          if (!ok) {
            throw EspException(
              '${part.label} at ${part.offsetLabel} no longer matches after the '
              'later regions were written. A write overlapped it.',
            );
          }
        }
      }

      // Close the session WITHOUT asking the ROM to reboot.
      //
      // FLASH_END's reboot flag is rejected by the ESP32-S3 ROM (status 0x06),
      // which used to leave a spurious failure line in the log of an otherwise
      // perfect flash. esptool does the same thing: finish the session, then
      // restart the board over DTR/RTS.
      await loader.flashEnd(reboot: false);

      if (options.rebootAfter) {
        _emit(FlashStage.rebooting, 'Restarting the board...',
            overall: 1, elapsed: stopwatch.elapsed);
        await transport.hardReset();
      }

      stopwatch.stop();
      report
        ..success = true
        ..elapsed = stopwatch.elapsed
        ..trace = List.of(loader.trace);

      _emit(FlashStage.done, 'Flash complete',
          overall: 1,
          bytesWritten: written,
          totalBytes: total,
          elapsed: stopwatch.elapsed);
      return report;
    } catch (e) {
      stopwatch.stop();
      report
        ..success = false
        ..elapsed = stopwatch.elapsed
        ..error = e is EspException ? e.message : e.toString()
        ..trace = List.of(loader.trace);
      _emit(FlashStage.failed, report.error!, elapsed: stopwatch.elapsed);
      return report;
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }
  }

  /// Erases the entire chip using FLASH_BEGIN over the full address range.
  ///
  /// The dedicated ERASE_FLASH command is stub-only, so the ROM equivalent is
  /// to declare a whole-chip erase and then close the session without writing.
  Future<void> _eraseWholeChip(EspLoader loader, int flashSize) async {
    // FLASH_BEGIN performs the erase itself, so declaring the whole chip is
    // enough to blank it.
    //
    // Crucially there is NO FLASH_END here. FLASH_BEGIN also tells the ROM to
    // expect that many blocks, and ending the session without sending any is
    // rejected with "could not act on the message". The caller goes straight
    // on to the first region's FLASH_BEGIN, which re-arms the state machine
    // and discards this pending transfer.
    await loader.flashBegin(offset: 0, size: flashSize);
  }

  /// Picks the fastest link speed the cable and phone can actually sustain.
  Future<int> _negotiateBaud(EspLoader loader, List<int> candidates) async {
    for (final baud in candidates) {
      if (baud == 115200) return 115200; // already there; nothing to negotiate
      if (!await loader.changeBaudRate(baud)) continue;

      // Prove the link still works at the new rate before committing to it.
      try {
        await loader.readReg(EspProto.chipDetectMagicRegAddr);
        return baud;
      } on EspException {
        // Drop back and try the next candidate down.
        await _transport!.setBaudRate(115200);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          await loader.sync(attempts: 5);
        } on EspException {
          rethrow;
        }
      }
    }
    return _transport?.baudRate ?? 115200;
  }

  Future<void> disconnect() async {
    await _loader?.dispose();
    _loader = null;
    await _transport?.dispose();
    _transport = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _progress.close();
  }

  EspLoader _requireLoader() {
    final l = _loader;
    if (l == null) {
      throw EspException('Not connected to a board.', recoverable: false);
    }
    return l;
  }
}
