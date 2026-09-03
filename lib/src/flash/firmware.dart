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

  /// Reports offsets that would land inside a partition holding device state
  /// (Wi-Fi credentials, filesystems). Used to warn before an unusual write.
  List<String> userStateCollisions() {
    final table = partitionTable;
    if (table.isEmpty) return const [];

    final warnings = <String>[];
    for (final part in parts) {
      for (final region in table) {
        if (!region.isUserState) continue;
        final overlaps = part.offset < region.offset + region.size &&
            region.offset < part.offset + part.size;
        if (overlaps) {
          warnings.add('${part.fileName} overwrites "${region.label}" '
              '(${region.typeLabel})');
        }
      }
    }
    return warnings;
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
      parts.add(FlashPart(
        label: (p['label'] as String?) ?? labelFor(file),
        offset: p['offset'] as int,
        bytes: data.buffer.asUint8List(),
        fileName: file,
      ));
    }
    parts.sort((a, b) => a.offset.compareTo(b.offset));

    final chipName = (manifest['chip'] as String?)?.toLowerCase();
    return FirmwareBundle(
      id: manifest['id'] as String? ?? id,
      name: manifest['name'] as String? ?? id,
      version: manifest['version'] as String? ?? '',
      parts: parts,
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

    final parts = loaded.entries
        .map((e) => FlashPart(
              label: labelFor(e.key),
              offset: defaultOffsetFor(e.key, chip),
              bytes: e.value,
              fileName: e.key,
            ))
        .toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));

    final app = parts.firstWhere(
      (p) => p.label == 'application',
      orElse: () => parts.first,
    );

    return FirmwareBundle(
      id: 'picked',
      name: parts.length == 1 ? app.fileName : 'Selected files',
      version: app.appDescriptor?.version ?? '',
      parts: parts,
      declaredChip: chip,
      flashSize: app.header?.flashSizeBytes ?? 0,
      flashMode: app.header?.flashMode ?? '',
      flashFreq: app.header?.flashFreq ?? '',
    );
  }
}
