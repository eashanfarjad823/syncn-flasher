import 'dart:typed_data';

/// ESP ROM bootloader command opcodes.
class EspCmd {
  static const int flashBegin = 0x02;
  static const int flashData = 0x03;
  static const int flashEnd = 0x04;
  static const int memBegin = 0x05;
  static const int memEnd = 0x06;
  static const int memData = 0x07;
  static const int sync = 0x08;
  static const int writeReg = 0x09;
  static const int readReg = 0x0A;

  // ESP32 and later.
  static const int spiSetParams = 0x0B;
  static const int spiAttach = 0x0D;
  static const int changeBaudrate = 0x0F;
  static const int flashDeflBegin = 0x10;
  static const int flashDeflData = 0x11;
  static const int flashDeflEnd = 0x12;
  static const int spiFlashMd5 = 0x13;
  static const int getSecurityInfo = 0x14;

  // Provided by the software stub loader only, never by the ROM.
  static const int eraseFlash = 0xD0;
  static const int eraseRegion = 0xD1;
  static const int readFlash = 0xD2;
  static const int runUserCode = 0xD3;
}

/// Sizes and magic numbers fixed by the ROM protocol.
class EspProto {
  /// Largest FLASH_DATA payload the ROM loader accepts. The software stub
  /// raises this to 0x4000, which is why stub-based flashing is faster.
  static const int romFlashWriteSize = 0x400;

  /// Seed for the FLASH_DATA/MEM_DATA payload checksum.
  static const int checksumMagic = 0xEF;

  /// Register whose value identifies the chip family.
  static const int chipDetectMagicRegAddr = 0x40001000;

  /// SYNC payload: a fixed preamble followed by 32 filler bytes.
  static Uint8List syncPayload() {
    final b = BytesBuilder(copy: false)
      ..add([0x07, 0x07, 0x12, 0x20])
      ..add(List<int>.filled(32, 0x55));
    return b.toBytes();
  }

  /// XOR checksum over a FLASH_DATA payload.
  static int checksum(Uint8List data) {
    var state = checksumMagic;
    for (final b in data) {
      state ^= b;
    }
    return state & 0xFF;
  }
}

/// A supported ESP chip family and the traits the flasher needs from it.
class EspChip {
  const EspChip({
    required this.name,
    required this.imageChipId,
    required this.magicValues,
    required this.bootloaderOffset,
    required this.supportsEncryptedFlash,
    required this.hasNativeUsb,
  });

  final String name;

  /// Value stored at offset 12 of an ESP image header.
  final int imageChipId;

  /// Possible readings of [EspProto.chipDetectMagicRegAddr]. Chips with
  /// several silicon revisions report different values.
  final List<int> magicValues;

  /// Where the second-stage bootloader lives. This differs by family and
  /// getting it wrong produces a board that will not boot.
  final int bootloaderOffset;

  /// Whether FLASH_BEGIN carries the extra ROM-only "encrypted" argument.
  final bool supportsEncryptedFlash;

  /// Whether the die exposes USB-Serial-JTAG directly, with no bridge chip.
  final bool hasNativeUsb;

  static const esp32 = EspChip(
    name: 'ESP32',
    imageChipId: 0x00,
    magicValues: [0x00F01D83],
    bootloaderOffset: 0x1000,
    supportsEncryptedFlash: false,
    hasNativeUsb: false,
  );

  static const esp32s2 = EspChip(
    name: 'ESP32-S2',
    imageChipId: 0x02,
    magicValues: [0x000007C6],
    bootloaderOffset: 0x1000,
    supportsEncryptedFlash: true,
    hasNativeUsb: true,
  );

  static const esp32s3 = EspChip(
    name: 'ESP32-S3',
    imageChipId: 0x09,
    magicValues: [0x00000009, 0xEB004136],
    bootloaderOffset: 0x0,
    supportsEncryptedFlash: true,
    hasNativeUsb: true,
  );

  static const esp32c3 = EspChip(
    name: 'ESP32-C3',
    imageChipId: 0x05,
    magicValues: [0x6921506F, 0x1B31506F, 0x4881606F, 0x4361606F],
    bootloaderOffset: 0x0,
    supportsEncryptedFlash: true,
    hasNativeUsb: true,
  );

  static const esp32c6 = EspChip(
    name: 'ESP32-C6',
    imageChipId: 0x0D,
    magicValues: [0x2CE0806F],
    bootloaderOffset: 0x0,
    supportsEncryptedFlash: true,
    hasNativeUsb: true,
  );

  static const esp32c2 = EspChip(
    name: 'ESP32-C2',
    imageChipId: 0x0C,
    magicValues: [0x6F51306F, 0x7C41A06F],
    bootloaderOffset: 0x0,
    supportsEncryptedFlash: true,
    hasNativeUsb: false,
  );

  static const esp32h2 = EspChip(
    name: 'ESP32-H2',
    imageChipId: 0x10,
    magicValues: [0xD7B73E80],
    bootloaderOffset: 0x0,
    supportsEncryptedFlash: true,
    hasNativeUsb: true,
  );

  static const esp8266 = EspChip(
    name: 'ESP8266',
    imageChipId: -1,
    magicValues: [0xFFF0C101],
    bootloaderOffset: 0x0,
    supportsEncryptedFlash: false,
    hasNativeUsb: false,
  );

  static const all = <EspChip>[
    esp32,
    esp32s2,
    esp32s3,
    esp32c3,
    esp32c6,
    esp32c2,
    esp32h2,
    esp8266,
  ];

  /// Identifies a chip from a magic-register reading.
  static EspChip? fromMagic(int magic) {
    for (final c in all) {
      if (c.magicValues.contains(magic)) return c;
    }
    return null;
  }

  /// Identifies a chip from the id embedded in a firmware image header.
  static EspChip? fromImageChipId(int id) {
    for (final c in all) {
      if (c.imageChipId == id) return c;
    }
    return null;
  }

  @override
  String toString() => name;
}

/// Thrown when the board rejects a command or stops responding.
class EspException implements Exception {
  EspException(this.message, {this.cause, this.recoverable = true});

  final String message;
  final Object? cause;

  /// Whether retrying, or re-entering download mode, could plausibly help.
  final bool recoverable;

  @override
  String toString() => 'EspException: $message';
}
