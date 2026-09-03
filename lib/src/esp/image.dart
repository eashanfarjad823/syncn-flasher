import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';

/// Decoded header of an ESP application/bootloader image (`.bin`).
///
/// Reading this before flashing is what lets the app refuse to write, say, an
/// ESP32-S3 image onto an ESP32 — a mistake that produces a board which will
/// not boot and cannot be recovered without a hardware programmer.
class EspImageHeader {
  const EspImageHeader({
    required this.segmentCount,
    required this.flashMode,
    required this.flashSizeBytes,
    required this.flashFreq,
    required this.entryAddress,
    required this.chipId,
    required this.chip,
  });

  static const int magic = 0xE9;

  final int segmentCount;
  final String flashMode;
  final int flashSizeBytes;
  final String flashFreq;
  final int entryAddress;
  final int chipId;
  final EspChip? chip;

  static const _flashModes = ['qio', 'qout', 'dio', 'dout'];
  static const _flashSizes = <int, int>{
    0x0: 1 << 20,
    0x1: 2 << 20,
    0x2: 4 << 20,
    0x3: 8 << 20,
    0x4: 16 << 20,
    0x5: 32 << 20,
    0x6: 64 << 20,
    0x7: 128 << 20,
  };
  static const _flashFreqs = <int, String>{
    0x0: '40MHz',
    0x1: '26MHz',
    0x2: '20MHz',
    0xF: '80MHz',
  };

  /// Parses the 24-byte image header. Returns null if [data] is not an ESP
  /// image (wrong magic or too short).
  static EspImageHeader? parse(Uint8List data) {
    if (data.length < 24 || data[0] != magic) return null;

    final bd = ByteData.sublistView(data);
    final sizeFreq = data[3];
    final chipId = bd.getUint16(12, Endian.little);

    return EspImageHeader(
      segmentCount: data[1],
      flashMode: data[2] < _flashModes.length ? _flashModes[data[2]] : 'unknown',
      flashSizeBytes: _flashSizes[(sizeFreq >> 4) & 0xF] ?? 0,
      flashFreq: _flashFreqs[sizeFreq & 0xF] ?? 'unknown',
      entryAddress: bd.getUint32(4, Endian.little),
      chipId: chipId,
      chip: EspChip.fromImageChipId(chipId),
    );
  }

  String get flashSizeLabel => flashSizeBytes >= (1 << 20)
      ? '${flashSizeBytes >> 20}MB'
      : '$flashSizeBytes B';

  @override
  String toString() =>
      '${chip?.name ?? "chip#$chipId"} $flashSizeLabel $flashMode $flashFreq';
}

/// The `esp_app_desc_t` struct ESP-IDF places at offset 0x20 of an app image.
///
/// Present in application images only — bootloaders and partition tables have
/// no descriptor, so [parse] returning null is normal and not an error.
class EspAppDescriptor {
  const EspAppDescriptor({
    required this.version,
    required this.projectName,
    required this.time,
    required this.date,
    required this.idfVersion,
  });

  static const int magicWord = 0xABCD5432;
  static const int offset = 0x20;

  final String version;
  final String projectName;
  final String time;
  final String date;
  final String idfVersion;

  static EspAppDescriptor? parse(Uint8List data) {
    if (data.length < offset + 0xB0) return null;
    final bd = ByteData.sublistView(data);
    if (bd.getUint32(offset, Endian.little) != magicWord) return null;

    return EspAppDescriptor(
      version: _str(data, offset + 0x10, 32),
      projectName: _str(data, offset + 0x30, 32),
      time: _str(data, offset + 0x50, 16),
      date: _str(data, offset + 0x60, 16),
      idfVersion: _str(data, offset + 0x70, 32),
    );
  }

  /// Reads a fixed-width, NUL-padded C string.
  static String _str(Uint8List d, int start, int len) {
    final end = (start + len).clamp(0, d.length);
    if (start >= end) return '';
    final slice = d.sublist(start, end);
    final nul = slice.indexOf(0);
    final bytes = nul == -1 ? slice : slice.sublist(0, nul);
    try {
      return utf8.decode(bytes, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  String get buildStamp => '$date $time'.trim();

  @override
  String toString() => '$projectName $version (IDF $idfVersion)';
}

/// One entry in an ESP-IDF partition table.
class EspPartition {
  const EspPartition({
    required this.type,
    required this.subtype,
    required this.offset,
    required this.size,
    required this.label,
  });

  static const int entryMagic = 0x50AA;
  static const int entrySize = 32;

  final int type;
  final int subtype;
  final int offset;
  final int size;
  final String label;

  bool get isApp => type == 0x00;
  bool get isData => type == 0x01;

  /// True for regions holding device state we must not clobber during an
  /// ordinary update — Wi-Fi credentials, OTA state, user filesystems.
  bool get isUserState =>
      isData && (subtype == 0x02 || subtype == 0x00 || subtype == 0x82 || subtype == 0x81);

  String get typeLabel {
    if (isApp) {
      return switch (subtype) {
        0x00 => 'app/factory',
        0x10 => 'app/ota_0',
        0x11 => 'app/ota_1',
        0x20 => 'app/test',
        _ => 'app/0x${subtype.toRadixString(16)}',
      };
    }
    if (isData) {
      return switch (subtype) {
        0x00 => 'data/otadata',
        0x01 => 'data/phy',
        0x02 => 'data/nvs',
        0x03 => 'data/coredump',
        0x04 => 'data/nvs_keys',
        0x81 => 'data/fat',
        0x82 => 'data/spiffs',
        _ => 'data/0x${subtype.toRadixString(16)}',
      };
    }
    return '0x${type.toRadixString(16)}/0x${subtype.toRadixString(16)}';
  }

  String get sizeLabel {
    if (size >= (1 << 20)) {
      final mb = size / (1 << 20);
      return '${mb == mb.roundToDouble() ? mb.toStringAsFixed(0) : mb.toStringAsFixed(2)} MB';
    }
    return '${size ~/ 1024} KB';
  }

  String get offsetLabel =>
      '0x${offset.toRadixString(16).toUpperCase().padLeft(6, '0')}';

  /// Parses a partition-table binary, stopping at the first non-entry.
  static List<EspPartition> parseTable(Uint8List data) {
    final out = <EspPartition>[];
    for (var i = 0; i + entrySize <= data.length; i += entrySize) {
      final bd = ByteData.sublistView(data, i, i + entrySize);
      if (bd.getUint16(0, Endian.little) != entryMagic) break;
      out.add(EspPartition(
        type: data[i + 2],
        subtype: data[i + 3],
        offset: bd.getUint32(4, Endian.little),
        size: bd.getUint32(8, Endian.little),
        label: EspAppDescriptor._str(data, i + 12, 16),
      ));
    }
    return out;
  }

  @override
  String toString() => '$label @ $offsetLabel ($sizeLabel, $typeLabel)';
}
