import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../esp/image.dart';
import '../esp/protocol.dart';

/// One binary destined for a specific flash offset.
class FlashPart {
  FlashPart({
    required this.label,
    required this.offset,
    required this.bytes,
    required this.fileName,
  });

  final String label;
  final int offset;
  final Uint8List bytes;
  final String fileName;

  int get size => bytes.length;

  String get offsetLabel =>
      '0x${offset.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  String get sizeLabel => size >= 1024
      ? '${(size / 1024).toStringAsFixed(size >= 102400 ? 0 : 1)} KB'
      : '$size B';

  /// MD5 of the local file, compared against the board's own checksum of the
  /// same region after writing.
  late final String md5Hex = md5.convert(bytes).toString();

  /// Header of this image, when it is one. Partition tables and otadata blobs
  /// legitimately have none.
  late final EspImageHeader? header = EspImageHeader.parse(bytes);

  /// IDF application descriptor, present on app images only.
  late final EspAppDescriptor? appDescriptor = EspAppDescriptor.parse(bytes);

  /// Partition entries, when this part is a partition table.
  late final List<EspPartition> partitions =
      label.contains('partition') ? EspPartition.parseTable(bytes) : const [];
}

/// A complete set of images to write, in order.
class FirmwareBundle {
  FirmwareBundle({
    required this.id,
    required this.name,
    required this.version,
    required this.parts,
    this.declaredChip,
    this.flashSize = 0,
    this.flashMode = '',
    this.flashFreq = '',
    this.isBundled = false,
  });

  final String id;
  final String name;
  final String version;
  final List<FlashPart> parts;

  /// Chip the manifest claims this build targets.
  final EspChip? declaredChip;

  final int flashSize;
  final String flashMode;
  final String flashFreq;

  /// True when the images ship inside the app rather than being user-picked.
  final bool isBundled;

  int get totalBytes => parts.fold(0, (sum, p) => sum + p.size);

  String get totalLabel => '${(totalBytes / (1024 * 1024)).toStringAsFixed(2)} MB';

  /// The chip this bundle actually targets, preferring evidence read out of
  /// the image headers over whatever the manifest claims.
  EspChip? get effectiveChip {
    for (final p in parts) {
      final c = p.header?.chip;
      if (c != null) return c;
    }
    return declaredChip;
  }

  /// The partition table carried by this bundle, if any.
  List<EspPartition> get partitionTable {
    for (final p in parts) {
      if (p.partitions.isNotEmpty) return p.partitions;
    }
    return const [];
  }

  /// Warns that a filesystem image replaces stored device data.
  ///
  /// Unlike the app or bootloader, a filesystem partition holds whatever the
  /// board itself wrote there — web assets, logs, calibration. Overwriting it
  /// is a deliberate act and should never be silent.
  List<String> filesystemWarnings() {
    final table = partitionTable;
    final out = <String>[];

    for (final part in parts) {
      if (part.label != 'filesystem') continue;

      EspPartition? region;
      for (final r in table) {
        if (r.offset == part.offset) {
          region = r;
          break;
        }
      }

      out.add(region != null
          ? 'Replaces the "${region.label}" filesystem (${region.sizeLabel}). '
              'Anything the board stored there is lost.'
          : 'Replaces the filesystem at ${part.offsetLabel}. Anything the '
              'board stored there is lost.');
    }
    return out;
  }

  /// Reports images that do not fit the partition they are aimed at.
  ///
  /// Writing past the end of a partition corrupts whatever follows it — on
  /// this layout a filesystem image that is too large runs straight into the
  /// coredump region.
  List<String> fitWarnings() {
    final table = partitionTable;
    if (table.isEmpty) return const [];

    final out = <String>[];
    for (final part in parts) {
      for (final region in table) {
        final startsInside = part.offset >= region.offset &&
            part.offset < region.offset + region.size;
        if (!startsInside) continue;

        final overshoot =
            (part.offset + part.size) - (region.offset + region.size);
        if (overshoot > 0) {
          out.add('${part.fileName} is ${part.sizeLabel}, which is '
              '${(overshoot / 1024).toStringAsFixed(0)} KB too big for '
              '"${region.label}" (${region.sizeLabel}).');
        }
        break;
      }
    }
    return out;
  }

  /// Re-points a filesystem image at the offset the supplied partition table
  /// actually declares.
  ///
  /// [defaultOffsetFor] can only guess from the file name; when the flash set
  /// includes a partition table, that table is authoritative and a board with
  /// a different layout is handled correctly instead of being written blind.
  static List<FlashPart> _alignToPartitionTable(List<FlashPart> parts) {
    var table = const <EspPartition>[];
    for (final p in parts) {
      if (p.partitions.isNotEmpty) {
        table = p.partitions;
        break;
      }
    }
    if (table.isEmpty) return parts;

    // SPIFFS (0x82) or FAT (0x81) — whichever this build actually declares.
    EspPartition? fs;
    for (final r in table) {
      if (r.isData && (r.subtype == 0x82 || r.subtype == 0x81)) {
        fs = r;
        break;
      }
    }
    if (fs == null) return parts;

    return parts
        .map((p) => (p.label == 'filesystem' && p.offset != fs!.offset)
            ? FlashPart(
                label: p.label,
                offset: fs.offset,
                bytes: p.bytes,
                fileName: p.fileName,
              )
            : p)
        .toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));
  }

  /// Standard Arduino/IDF offsets, chosen from the chip family because the
  /// bootloader lives at a different address on ESP32 than on S3/C3.
  static int defaultOffsetFor(String fileName, EspChip? chip) {
    final n = fileName.toLowerCase();
    if (n.contains('bootloader')) return chip?.bootloaderOffset ?? 0x0;
    if (n.contains('partition')) return 0x8000;
    if (n.contains('boot_app0') || n.contains('otadata')) return 0xE000;
    if (n.contains('spiffs') || n.contains('littlefs')) return 0x610000;
    return 0x10000; // application
  }

  static String labelFor(String fileName) {
    final n = fileName.toLowerCase();
    if (n.contains('bootloader')) return 'bootloader';
    if (n.contains('partition')) return 'partition table';
    if (n.contains('boot_app0') || n.contains('otadata')) return 'otadata';
    if (n.contains('spiffs') || n.contains('littlefs')) return 'filesystem';
    return 'application';
  }

  /// Loads the firmware shipped inside the app.
  static Future<FirmwareBundle> loadBundled([String id = 'syncn-v1']) async {
    final dir = 'assets/firmware/$id';
    final manifest =
        jsonDecode(await rootBundle.loadString('$dir/manifest.json'))
            as Map<String, dynamic>;

    final parts = <FlashPart>[];
    for (final raw in (manifest['parts'] as List<dynamic>)) {
      final p = raw as Map<String, dynamic>;
      final file = p['file'] as String;
      final data = await rootBundle.load('$dir/$file');
      final label = (p['label'] as String?) ?? labelFor(file);
      var bytes = data.buffer.asUint8List();

      // Correct the bootloader's flash parameters, exactly as esptool does.
      // A bootloader built for QIO written unchanged onto a DIO board cannot
      // read flash and watchdog-resets in a loop.
      if (label.contains('bootloader')) {
        bytes = EspImageHeader.applyFlashParams(
          bytes,
          mode: manifest['flashMode'] as String?,
          sizeBytes: manifest['flashSize'] as int?,
          freq: manifest['flashFreq'] as String?,
        );
      }

      parts.add(FlashPart(
        label: label,
        offset: p['offset'] as int,
        bytes: bytes,
        fileName: file,
      ));
    }
    parts.sort((a, b) => a.offset.compareTo(b.offset));
    final aligned = _alignToPartitionTable(parts);

    final chipName = (manifest['chip'] as String?)?.toLowerCase();
    return FirmwareBundle(
      id: manifest['id'] as String? ?? id,
      name: manifest['name'] as String? ?? id,
      version: manifest['version'] as String? ?? '',
      parts: aligned,
      declaredChip: EspChip.all.cast<EspChip?>().firstWhere(
            (c) => c!.name.toLowerCase().replaceAll('-', '') == chipName,
            orElse: () => null,
          ),
      flashSize: manifest['flashSize'] as int? ?? 0,
      flashMode: manifest['flashMode'] as String? ?? '',
      flashFreq: manifest['flashFreq'] as String? ?? '',
      isBundled: true,
    );
  }

  /// Builds a bundle from files the user picked, inferring each offset from
  /// the file name and the chip the images themselves declare.
  static Future<FirmwareBundle?> pickFromDevice() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return null;

    // Read every file first so header-derived chip detection can inform the
    // offsets assigned below.
    final loaded = <String, Uint8List>{};
    for (final f in files) {
      loaded[f.name] = await f.readAsBytes();
    }
    if (loaded.isEmpty) return null;

    EspChip? chip;
    for (final bytes in loaded.values) {
      final c = EspImageHeader.parse(bytes)?.chip;
      if (c != null) {
        chip = c;
        break;
      }
    }

    // The application image carries the flash parameters the board actually
    // needs; the bootloader is then corrected to match, as esptool does.
    EspImageHeader? appHeader;
    for (final e in loaded.entries) {
      if (labelFor(e.key) == 'application') {
        appHeader = EspImageHeader.parse(e.value);
        break;
      }
    }

    final parts = loaded.entries.map((e) {
      final label = labelFor(e.key);
      var bytes = e.value;
      if (label.contains('bootloader') && appHeader != null) {
        bytes = EspImageHeader.applyFlashParams(
          bytes,
          mode: appHeader.flashMode,
          sizeBytes: appHeader.flashSizeBytes,
          freq: appHeader.flashFreq,
        );
      }
      return FlashPart(
        label: label,
        offset: defaultOffsetFor(e.key, chip),
        bytes: bytes,
        fileName: e.key,
      );
    }).toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));

    // A supplied partition table outranks the filename guess.
    final aligned = _alignToPartitionTable(parts);

    final app = aligned.firstWhere(
      (p) => p.label == 'application',
      orElse: () => aligned.first,
    );

    return FirmwareBundle(
      id: 'picked',
      name: aligned.length == 1 ? app.fileName : 'Selected files',
      version: app.appDescriptor?.version ?? '',
      parts: aligned,
      declaredChip: chip,
      flashSize: app.header?.flashSizeBytes ?? 0,
      flashMode: app.header?.flashMode ?? '',
      flashFreq: app.header?.flashFreq ?? '',
    );
  }
}
