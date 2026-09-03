# SyncN Flasher

An Android app that writes ESP32-S3 firmware to a KinCony board **directly from
a phone**, over a USB-C to USB-C cable. No laptop, no esptool, no Arduino IDE.

Built in Flutter/Dart. The ESP ROM bootloader protocol is implemented in pure
Dart on top of Android's USB Host API — there is no native code and no bundled
C library.

---

## What it does

- **Detects the board automatically** — reads the chip's magic register and
  identifies ESP32 / S2 / S3 / C2 / C3 / C6 / H2 / ESP8266, then adapts flash
  offsets to that family.
- **Ships with the SyncN firmware built in.** One tap flashes a known-good
  image with no file hunting. An *Advanced* picker takes any `.bin` set for
  development or recovery.
- **Verifies every write** by asking the board for the MD5 of each region and
  comparing it against the local file. A region is only ever labelled
  "verified" when those checksums actually matched.
- **Negotiates link speed** — tries 921600 baud first and falls back to 460800
  then 115200 if the link proves unreliable, rather than failing outright.
- **Escalates into download mode** — classic DTR/RTS auto-reset, then the
  native-USB sequence, then guided manual BOOT/RST instructions.
- **Serial monitor** with an explicit baud choice, autoscroll, copy and share.
- **Shareable reports** — chip, MAC, regions written, checksums, timings, and a
  full protocol trace for diagnosing a board that will not take firmware.

---

## Requirements

| | |
|---|---|
| Phone | Android 8.0 (API 26) or newer, with **USB host / OTG support** |
| Cable | USB-C to USB-C (data-capable — many charge-only cables are not) |
| Board power | **Its own 12V/24V supply.** See the warning below. |
| Build | Flutter 3.47+, JDK 21 or newer, Android SDK 36 |

Check your phone supports USB host before anything else:

```bash
adb shell pm list features | grep usb.host
```

If `android.hardware.usb.host` is missing, the phone physically cannot do this.

> **Power the board externally.** A phone in OTG host mode supplies limited
> current. A KinCony board with relays energised can exceed it, and a voltage
> sag mid-write corrupts the flash. Use the board's own PSU and let the USB-C
> cable carry data only.

---

## Build and install

```bash
flutter pub get
```

```bash
flutter build apk --debug
```

```bash
flutter install
```

Debugging while a board is plugged in requires **wireless adb**, because the
phone's USB-C port is occupied:

```bash
adb tcpip 5555
```

---

## Flashing a board

1. Power the KinCony board from its own supply.
2. Connect it to the phone with a USB-C to USB-C cable.
3. Open SyncN Flasher. The board appears under **Board** — tap **Connect**.
   - Android will ask for USB permission. Tick *always open* to stop the prompt
     recurring.
   - If auto-reset fails, the app walks you through **hold BOOT → tap RST →
     release BOOT**.
4. Confirm the firmware under **Firmware** (built-in by default).
5. Tap **Flash firmware**, review the confirmation sheet, choose the erase
   mode, then **Flash now**.
6. When it finishes, open the **serial monitor** and pick your firmware's log
   speed to confirm the board booted.

### Erase modes

| Mode | Effect |
|---|---|
| Only what is being written | Default. Erases just the sectors being written. `nvs` survives, so Wi-Fi credentials and settings are kept. |
| Erase the whole chip | Blanks all 8 MB. The board needs re-provisioning afterwards. |

---

## Firmware layout

Written in this order — see [`01_HARDWARE_FINDINGS.md`](01_HARDWARE_FINDINGS.md)
for how these were verified from the binaries themselves:

| # | File | Offset |
|---|---|---|
| 1 | `bootloader.bin` | `0x0000` |
| 2 | `partitions.bin` | `0x8000` |
| 3 | `boot_app0.bin` | `0xE000` |
| 4 | `firmware.bin` | `0x10000` |

`spiffs` at `0x610000` is deliberately left untouched.

> The bootloader sits at `0x0` because this is an **ESP32-S3**. On a classic
> ESP32 it belongs at `0x1000`. The app derives this from the detected chip.

### Replacing the built-in firmware

Drop new binaries into `assets/firmware/syncn-v1/` and update `manifest.json`
alongside them. The `offset` values are decimal.

---

## Architecture

```
lib/
  main.dart                     app entry, theme selection
  src/
    esp/
      slip.dart                 SLIP framing (RFC 1055)
      protocol.dart             ROM opcodes, chip table, constants
      image.dart                image header, app descriptor, partition table
      transport.dart            USB serial + download-mode reset sequences
      loader.dart               the ROM bootloader conversation
    flash/
      firmware.dart             bundled assets and the file picker
      flash_service.dart        orchestration, progress, verification, reports
    ui/
      theme.dart                SyncN design tokens, light + dark
      widgets.dart              shared components
      home_screen.dart          connect, confirm, flash, report
      serial_monitor.dart       serial console
```

The flashing engine has no Flutter dependency beyond `usb_serial`, so it can be
reused or ported without dragging the UI along.

---

## Known limitations

- **No stub loader.** Only the ROM bootloader is used. That is enough to write
  and MD5-verify firmware, but the ROM offers no flash-read command, so
  **backing up existing firmware and byte-for-byte read-back verification are
  not available.** The backup toggle is present and says so rather than
  silently doing nothing. Uploading the Espressif stub would enable both, and
  would also raise the write block size from 1 KB to 16 KB.
- **No foreground service yet.** A wakelock keeps the screen on during a flash;
  leaving the app mid-write will still interrupt it.
- **Wi-Fi OTA is not implemented.** The partition table supports it and the
  code is structured for it, but the firmware's update endpoint is not yet
  known.
- **Flash size is read from the image header**, not interrogated from the SPI
  flash chip.
- **Android only.** iOS cannot reach USB-serial devices without MFi
  certification; desktop was descoped.

---

## Licence

All rights reserved.
