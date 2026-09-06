# Hardware findings — verified from the firmware binaries

**Source:** `bootloader.bin`, `partitions.bin`, `boot_app0.bin`, `firmware.bin`
(supplied 2026-09-03).
**Method:** direct parse of the ESP image headers, the IDF application
descriptor, and the partition-table entries — not read from documentation.
**Confidence key:** ✅ = decoded from the binary · 📄 = stated in the supplied
notes · ⚠️ = inferred, still to confirm on hardware.

> Everything below was cross-checked against the supplied `uploading-order.txt`
> and agreed on every field.

---

## 1. Target chip ✅

The 24-byte ESP image header carries the chip id at offset 12:

```
bootloader.bin  e9 03 00 00 b8 98 3c 40 ee 00 00 00 [09 00] ...
firmware.bin    e9 05 02 3f f0 74 37 40 ee 00 00 00 [09 00] ...
                                                     ^^^^^ chip_id = 9
```

`chip_id 0x09` is **ESP32-S3**. Corroborated by the entry points
(`0x403C98B8` and `0x403774F0`), both of which fall inside the ESP32-S3 IRAM
window `0x40370000–0x403DFFFF`.

**This matters more than it looks.** The second-stage bootloader lives at a
different address per family — `0x1000` on ESP32/S2, but **`0x0` on S3, C3, C6
and H2**. Writing an S3 bootloader to `0x1000` produces a board that never
boots. The flasher derives this offset from the detected chip rather than
assuming (`EspChip.bootloaderOffset`).

## 2. Flash geometry ✅

Byte 3 of the app header packs size and frequency into two nibbles:

| Field | Raw | Decoded |
|---|---|---|
| Flash size | `0x3` (high nibble) | **8 MB** |
| Flash frequency | `0xF` (low nibble) | **80 MHz** |
| Flash mode | `0x02` (byte 2) | **DIO** |

Matches the supplied notes exactly. 📄

## 3. Partition table ✅

`partitions.bin` decodes to six entries, each 32 bytes, magic `0x50AA`:

| Offset | Size | Type / subtype | Label |
|---|---|---|---|
| `0x009000` | 20 KB | `data/nvs` | `nvs` |
| `0x00E000` | 8 KB | `data/otadata` | `otadata` |
| `0x010000` | 3 MB | `app/ota_0` | `ota_0` |
| `0x310000` | 3 MB | `app/ota_1` | `ota_1` |
| `0x610000` | 1.875 MB | `data/spiffs` | `spiffs` |
| `0x7F0000` | 64 KB | `data/coredump` | `coredump` |

Sums to exactly `0x800000` = 8 MB, consistent with the header. ✅

Two consequences:

- **`nvs` holds Wi-Fi credentials and settings.** The default erase mode wipes
  only the sectors being written, so `nvs` survives an update and the board
  keeps its configuration. A full-chip erase is opt-in and clearly labelled as
  requiring re-provisioning.
- **The app is written to `ota_0`, not `factory`.** `boot_app0.bin` sets
  `otadata` to point at the first OTA slot, so the bootloader runs `ota_0`.
  `ota_1` stays empty — the flasher writes over USB only and never uses the
  second slot.

## 4. Application provenance ✅

The `esp_app_desc_t` struct at offset `0x20` of `firmware.bin`
(magic `0xABCD5432`):

| Field | Value |
|---|---|
| `project_name` | `arduino-lib-builder` |
| `version` | `esp-idf: v4.4.7 38eeba213a` |
| `idf_ver` | `v4.4.7-dirty` |
| `date` / `time` | `Mar 5 2024` `12:12:53` |

So this is an **Arduino-ESP32 core** build on ESP-IDF v4.4.7.

The app image is **1,721,520 bytes** — 55% of the 3 MB `ota_0` partition, so
there is comfortable headroom.

## 5. Flash order and offsets ✅ 📄

| # | File | Offset | Size | Goes to |
|---|---|---|---|---|
| 1 | `bootloader.bin` | `0x0000` | 14,032 B | second-stage bootloader |
| 2 | `partitions.bin` | `0x8000` | 3,072 B | partition table |
| 3 | `boot_app0.bin` | `0xE000` | 8,192 B | `otadata` |
| 4 | `firmware.bin` | `0x10000` | 1,721,520 B | `ota_0` |

`boot_app0.bin` is an otadata initialiser — its first word is `0x00000001`,
which points the bootloader at the first OTA slot.

**`spiffs` at `0x610000` is not written** by these four files. The flasher
leaves it untouched, so any filesystem contents survive an update.

## 6. USB path — CONFIRMED ON HARDWARE ✅

Resolved 2026-09-03 by connecting a real board from the app:

```
Espressif native USB    0x303A:0x1001
ESP32-S3                MAC A0:85:E3:FC:00:50
```

The board exposes the **S3's own USB-Serial-JTAG peripheral** — there is no
CH340/CP2102 bridge chip in the path. `0x303A` is Espressif's vendor id and
`0x1001` is the USB-Serial-JTAG product id.

Consequences, now that this is known rather than guessed:

- The **native-USB reset sequence** is the one that matters here, not the
  classic DTR/RTS-through-transistors sequence. The app tries classic first and
  falls through to the native sequence, so it works either way.
- The chip **re-enumerates when it resets** into download mode
  (`0x303A:0x1001` → `0x303A:0x0002`). Anything that resets the board mid-flow
  must tolerate the USB device disappearing and coming back.

Verified working end-to-end against this board: USB enumeration, download-mode
entry, the SYNC handshake, chip identification from the magic register, and the
eFuse MAC read.

## 7. Still open ⚠️

- **Auto-reset wiring.** Not yet established whether this board populates the
  DTR/RTS reset transistors, since the native-USB path can reset it regardless.
  The app escalates: classic auto-reset → native-USB sequence → guided manual
  BOOT/RST.
- **Actual flash chip size.** Read from the image header, not interrogated from
  the SPI flash itself. Reading the real JEDEC id needs register-level SPI
  access that is not yet implemented.
- **A full write has not been performed yet.** Connect and identify are proven
  on hardware; `FLASH_BEGIN`/`FLASH_DATA`/MD5-verify are not.
