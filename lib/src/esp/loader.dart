import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'protocol.dart';
import 'slip.dart';
import 'transport.dart';

/// eFuse register holding the factory MAC, per chip family.
const Map<String, int> _macEfuseReg = {
  'ESP32': 0x3FF5A000,
  'ESP32-S2': 0x3F41A000 + 0x044,
  'ESP32-S3': 0x60007000 + 0x044,
  'ESP32-C3': 0x60008800 + 0x044,
  'ESP32-C6': 0x600B0800 + 0x044,
  'ESP32-H2': 0x600B0800 + 0x044,
};

/// Human-readable meanings for the ROM's second status byte.
String _romErrorText(int code) => switch (code) {
      0x05 => 'the board rejected the message as invalid',
      0x06 => 'the board could not act on the message',
      0x07 => 'checksum mismatch - the USB link is corrupting data',
      0x08 => 'flash write failed',
      0x09 => 'flash read failed',
      0x0A => 'flash read length error',
      0x0B => 'decompression error',
      _ => 'ROM error 0x${code.toRadixString(16)}',
    };

/// Speaks the ESP ROM bootloader protocol over a [SerialTransport].
///
/// This implements the ROM loader only - no software stub is uploaded. That
/// covers everything needed to write and MD5-verify firmware. Commands the ROM
/// does not provide (whole-flash read-back, region erase) are stub-only and
/// are reported as unsupported rather than silently skipped.
class EspLoader {
  EspLoader(this.transport) {
    _decoder = SlipDecoder(_onFrame);
    _rxSub = transport.incoming.listen(_decoder.feed);
  }

  final SerialTransport transport;

  late final SlipDecoder _decoder;
  StreamSubscription<Uint8List>? _rxSub;

  final List<Uint8List> _frames = [];
  Completer<Uint8List?>? _waiter;

  /// Length of the trailing status field. Calibrated from the SYNC response
  /// rather than hard-coded, because it differs between chip families.
  int _statusLen = 4;

  EspChip? _chip;
  EspChip? get chip => _chip;

  String? _mac;
  String? get macAddress => _mac;

  /// Diagnostic trace of every protocol step, for the shareable failure log.
  final List<String> trace = [];

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    trace.add('[$ts] $msg');
    if (trace.length > 2000) trace.removeRange(0, 500);
  }

  void _onFrame(Uint8List frame) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(frame);
    } else {
      _frames.add(frame);
      if (_frames.length > 64) _frames.removeAt(0);
    }
  }

  Future<Uint8List?> _nextFrame(Duration timeout) async {
    if (_frames.isNotEmpty) return _frames.removeAt(0);
    if (timeout.isNegative) return null;

    final c = Completer<Uint8List?>();
    _waiter = c;
    final timer = Timer(timeout, () {
      if (!c.isCompleted) {
        _waiter = null;
        c.complete(null);
      }
    });
    final frame = await c.future;
    timer.cancel();
    return frame;
  }

  /// Sends a command and waits for the matching response frame.
  Future<(int value, Uint8List data)> command({
    required int op,
    Uint8List? data,
    int checksum = 0,
    Duration timeout = const Duration(seconds: 3),
    bool drainFirst = true,
  }) async {
    final payload = data ?? Uint8List(0);

    final header = ByteData(8)
      ..setUint8(0, 0x00) // direction: request
      ..setUint8(1, op)
      ..setUint16(2, payload.length, Endian.little)
      ..setUint32(4, checksum, Endian.little);

    final packet = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(payload);

    if (drainFirst) _frames.clear();
    await transport.write(Slip.encode(packet.toBytes()));

    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) break;

      final frame = await _nextFrame(remaining);
      if (frame == null) break;
      // Ignore frames that are not a response to this command; the ROM emits
      // extra SYNC replies that would otherwise be mistaken for results.
      if (frame.length < 8 || frame[0] != 0x01 || frame[1] != op) continue;

      final bd = ByteData.sublistView(frame);
      final size = bd.getUint16(2, Endian.little);
      final value = bd.getUint32(4, Endian.little);
      final end = math.min(8 + size, frame.length);
      return (value, frame.sublist(8, end));
    }

    throw EspException(
      'No response to command 0x${op.toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Sends a command and fails if the board reports a non-zero status.
  Future<(int value, Uint8List body)> checkCommand({
    required int op,
    Uint8List? data,
    int checksum = 0,
    Duration timeout = const Duration(seconds: 3),
    String what = 'command',
  }) async {
    final (value, resp) = await command(
      op: op,
      data: data,
      checksum: checksum,
      timeout: timeout,
    );

    if (resp.length < _statusLen) {
      throw EspException('Malformed reply while trying to $what.');
    }
    final status = resp.sublist(resp.length - _statusLen);
    if (status[0] != 0) {
      final detail = status.length > 1 ? _romErrorText(status[1]) : 'unknown';
      throw EspException('Failed to $what: $detail');
    }
    return (value, resp.sublist(0, resp.length - _statusLen));
  }

  /// Handshakes with the ROM bootloader.
  ///
  /// The board must already be in download mode. Several attempts are made
  /// because the ROM ignores traffic that arrives while it is still booting.
  Future<void> sync({int attempts = 10}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final (_, resp) = await command(
          op: EspCmd.sync,
          data: EspProto.syncPayload(),
          timeout: const Duration(milliseconds: 300),
        );

        // The status field is 4 bytes on ESP32-family ROMs and 2 on ESP8266;
        // deriving it from the reply avoids guessing per chip.
        _statusLen = resp.length >= 4 ? 4 : 2;
        _log('SYNC ok on attempt ${i + 1} (status field ${_statusLen}B)');

        // The ROM answers a single SYNC up to eight times; drain the rest so
        // they are not mistaken for replies to the next command.
        for (var j = 0; j < 8; j++) {
          if (await _nextFrame(const Duration(milliseconds: 40)) == null) break;
        }
        return;
      } on EspException {
        _log('SYNC attempt ${i + 1} failed');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw EspException('The board did not respond to the sync handshake.');
  }

  Future<int> readReg(int address) async {
    final data = ByteData(4)..setUint32(0, address, Endian.little);
    final (value, _) = await checkCommand(
      op: EspCmd.readReg,
      data: data.buffer.asUint8List(),
      what: 'read register 0x${address.toRadixString(16)}',
    );
    return value;
  }

  /// Identifies the connected chip from its magic register.
  Future<EspChip> detectChip() async {
    final magic = await readReg(EspProto.chipDetectMagicRegAddr);
    final chip = EspChip.fromMagic(magic);
    _log('chip magic 0x${magic.toRadixString(16)} -> ${chip?.name ?? "unknown"}');

    if (chip == null) {
      throw EspException(
        'Unrecognised chip (magic 0x${magic.toRadixString(16)}). '
        'This board is not supported by the flasher.',
        recoverable: false,
      );
    }
    _chip = chip;
    return chip;
  }

  /// Reads the factory MAC, used to identify the board in reports and history.
  Future<String?> readMac() async {
    final reg = _macEfuseReg[_chip?.name];
    if (reg == null) return null;
    try {
      final mac0 = await readReg(reg);
      final mac1 = await readReg(reg + 4);
      final b = ByteData(8)
        ..setUint32(0, mac1, Endian.big)
        ..setUint32(4, mac0, Endian.big);
      final bytes = b.buffer.asUint8List().sublist(2); // low 6 bytes
      _mac = bytes
          .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(':');
      _log('MAC $_mac');
      return _mac;
    } on EspException {
      return null; // informational only; never fail a flash over this
    }
  }

  /// Connects the ROM's SPI flash driver to the board's flash chip.
  Future<void> spiAttach() async {
    // The ROM loader expects eight bytes here; the stub takes four.
    await checkCommand(
      op: EspCmd.spiAttach,
      data: Uint8List(8),
      what: 'attach the SPI flash',
    );
    _log('SPI attached');
  }

  /// Tells the ROM the geometry of the flash chip.
  Future<void> spiSetParams({required int flashSize}) async {
    final d = ByteData(24)
      ..setUint32(0, 0, Endian.little) // device id
      ..setUint32(4, flashSize, Endian.little)
      ..setUint32(8, 64 * 1024, Endian.little) // block size
      ..setUint32(12, 4 * 1024, Endian.little) // sector size
      ..setUint32(16, 256, Endian.little) // page size
      ..setUint32(20, 0xFFFF, Endian.little); // status mask
    await checkCommand(
      op: EspCmd.spiSetParams,
      data: d.buffer.asUint8List(),
      what: 'set flash parameters',
    );
    _log('flash params set (${flashSize >> 20}MB)');
  }

  /// Renegotiates the link speed. The reply arrives at the old rate, so the
  /// port is switched only after it has been received.
  Future<bool> changeBaudRate(int newBaud) async {
    try {
      final d = ByteData(8)
        ..setUint32(0, newBaud, Endian.little)
        ..setUint32(4, 0, Endian.little); // 0 = currently running from ROM
      await command(
        op: EspCmd.changeBaudrate,
        data: d.buffer.asUint8List(),
        timeout: const Duration(milliseconds: 500),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await transport.setBaudRate(newBaud);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _frames.clear();
      _decoder.reset();
      _log('baud -> $newBaud');
      return true;
    } on EspException catch (e) {
      _log('baud change to $newBaud failed: ${e.message}');
      return false;
    }
  }

  /// Erases the target region and prepares the ROM to receive [size] bytes.
  Future<void> flashBegin({
    required int offset,
    required int size,
    int blockSize = EspProto.romFlashWriteSize,
  }) async {
    final numBlocks = (size + blockSize - 1) ~/ blockSize;
    final withEncryptionArg = _chip?.supportsEncryptedFlash ?? false;

    final d = ByteData(withEncryptionArg ? 20 : 16)
      ..setUint32(0, size, Endian.little) // erase size
      ..setUint32(4, numBlocks, Endian.little)
      ..setUint32(8, blockSize, Endian.little)
      ..setUint32(12, offset, Endian.little);
    if (withEncryptionArg) {
      d.setUint32(16, 0, Endian.little); // not encrypted
    }

    // Erase happens inside FLASH_BEGIN and scales with region size.
    final timeout = Duration(
      seconds: math.max(15, (size / (1 << 20)).ceil() * 30),
    );

    await checkCommand(
      op: EspCmd.flashBegin,
      data: d.buffer.asUint8List(),
      timeout: timeout,
      what: 'erase flash at 0x${offset.toRadixString(16)}',
    );
    _log('FLASH_BEGIN offset=0x${offset.toRadixString(16)} '
        'size=$size blocks=$numBlocks');
  }

  /// Writes one block. [seq] must increment from zero within a region.
  Future<void> flashBlock(Uint8List data, int seq) async {
    final header = ByteData(16)
      ..setUint32(0, data.length, Endian.little)
      ..setUint32(4, seq, Endian.little)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, 0, Endian.little);

    final payload = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(data);

    await checkCommand(
      op: EspCmd.flashData,
      data: payload.toBytes(),
      checksum: EspProto.checksum(data),
      timeout: const Duration(seconds: 5),
      what: 'write flash block $seq',
    );
  }

  /// Finishes the flash session. [reboot] false leaves the board in the
  /// bootloader so further regions can be written.
  ///
  /// Set [tolerant] once every region has been written and checksummed: a
  /// refusal at that point cannot invalidate flash that already verified, so
  /// it is recorded rather than allowed to fail an otherwise good job.
  Future<void> flashEnd({bool reboot = false, bool tolerant = false}) async {
    final d = ByteData(4)..setUint32(0, reboot ? 0 : 1, Endian.little);
    try {
      await checkCommand(
        op: EspCmd.flashEnd,
        data: d.buffer.asUint8List(),
        timeout: const Duration(seconds: 3),
        what: 'finish flashing',
      );
    } on EspException catch (e) {
      // Rebooting boards frequently stop answering mid-reply; that is success.
      if (!reboot && !tolerant) rethrow;
      _log('FLASH_END not acknowledged, continuing: ${e.message}');
      return;
    }
    _log('FLASH_END reboot=$reboot');
  }

  /// Arms the ROM with an empty transfer.
  ///
  /// esptool does exactly this immediately before FLASH_END on non-stub
  /// targets (its `soft_reset` for the ROM loader): the zero-length begin
  /// leaves nothing outstanding, which is what makes the following FLASH_END
  /// valid. Sent cold — particularly after a run of MD5 commands — the
  /// ESP32-S3 ROM rejects FLASH_END with status 0x06.
  Future<void> flashBeginEmpty() async {
    await flashBegin(offset: 0, size: 0);
  }

  /// Asks the board for the MD5 of a flash region, so a write can be verified
  /// without reading the whole region back over USB.
  Future<String> flashMd5({required int offset, required int size}) async {
    final d = ByteData(16)
      ..setUint32(0, offset, Endian.little)
      ..setUint32(4, size, Endian.little)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, 0, Endian.little);

    final timeout = Duration(
      seconds: math.max(10, (size / (1 << 20)).ceil() * 20),
    );

    final (_, body) = await checkCommand(
      op: EspCmd.spiFlashMd5,
      data: d.buffer.asUint8List(),
      timeout: timeout,
      what: 'checksum flash at 0x${offset.toRadixString(16)}',
    );

    // The ROM returns 32 ASCII hex characters; the stub would return 16 raw
    // bytes, so both shapes are accepted.
    if (body.length >= 32) {
      return String.fromCharCodes(body.sublist(0, 32)).toLowerCase();
    }
    if (body.length >= 16) {
      return body
          .sublist(0, 16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    }
    throw EspException('Board returned a malformed checksum.');
  }

  /// Reading flash back requires the software stub loader, which this version
  /// does not upload. Callers surface this as an unavailable feature.
  bool get supportsFlashRead => false;

  Future<void> dispose() async {
    await _rxSub?.cancel();
    _rxSub = null;
  }
}
