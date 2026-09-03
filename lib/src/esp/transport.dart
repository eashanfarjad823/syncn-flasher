import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import 'protocol.dart';

/// A USB-serial adapter we know how to talk to, plus how it reaches the MCU.
class SerialDeviceInfo {
  const SerialDeviceInfo({
    required this.deviceId,
    required this.vid,
    required this.pid,
    required this.productName,
    required this.manufacturer,
    required this.driver,
    required this.isNativeUsb,
  });

  final int deviceId;
  final int vid;
  final int pid;
  final String productName;
  final String manufacturer;

  /// usb_serial driver name, or null to let the plugin choose.
  final String? driver;

  /// True when the port is the MCU's own USB peripheral rather than a separate
  /// bridge chip. Native-USB parts re-enumerate when they reset, which the
  /// flash sequence has to tolerate.
  final bool isNativeUsb;

  String get vidPid =>
      '0x${vid.toRadixString(16).padLeft(4, '0').toUpperCase()}:'
      '0x${pid.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  String get bridgeName {
    return switch (vid) {
      0x1A86 => 'WCH CH34x',
      0x10C4 => 'Silicon Labs CP210x',
      0x0403 => 'FTDI',
      0x067B => 'Prolific PL2303',
      0x303A => 'Espressif native USB',
      _ => productName.isNotEmpty ? productName : 'USB serial',
    };
  }

  static String? _driverFor(int vid) {
    return switch (vid) {
      0x1A86 => UsbSerial.CH34x,
      0x10C4 => UsbSerial.CP210x,
      0x0403 => UsbSerial.FTDI,
      0x067B => UsbSerial.PL2303,
      0x303A => UsbSerial.CDC,
      _ => null,
    };
  }

  factory SerialDeviceInfo.fromUsbDevice(UsbDevice d) {
    final vid = d.vid ?? 0;
    return SerialDeviceInfo(
      deviceId: d.deviceId ?? 0,
      vid: vid,
      pid: d.pid ?? 0,
      productName: d.productName ?? '',
      manufacturer: d.manufacturerName ?? '',
      driver: _driverFor(vid),
      isNativeUsb: vid == 0x303A,
    );
  }
}

/// Serial link to the board, with the reset choreography that drives the chip
/// into its ROM download mode.
class SerialTransport {
  SerialTransport(this._info);

  final SerialDeviceInfo _info;
  SerialDeviceInfo get info => _info;

  UsbPort? _port;
  StreamSubscription<Uint8List>? _sub;
  final StreamController<Uint8List> _rx = StreamController<Uint8List>.broadcast();

  int _baud = 115200;
  int get baudRate => _baud;
  bool get isOpen => _port != null;

  /// Raw bytes from the board. Used both by the protocol layer and, verbatim,
  /// by the serial monitor.
  Stream<Uint8List> get incoming => _rx.stream;

  /// Enumerates attached adapters the flasher recognises.
  static Future<List<SerialDeviceInfo>> listDevices() async {
    final devices = await UsbSerial.listDevices();
    return devices.map(SerialDeviceInfo.fromUsbDevice).toList();
  }

  /// Fires when a USB device is attached or detached.
  static Stream<UsbEvent> get usbEvents => UsbSerial.usbEventStream ?? const Stream.empty();

  Future<void> open({int baudRate = 115200}) async {
    if (_port != null) return;

    final port = await UsbSerial.createFromDeviceId(_info.deviceId, _info.driver ?? '');
    if (port == null) {
      throw EspException(
        'Could not create a serial port for ${_info.bridgeName}.',
        recoverable: false,
      );
    }

    // open() triggers Android's USB permission prompt when needed.
    final opened = await port.open();
    if (!opened) {
      throw EspException(
        'USB permission denied, or the port is already in use by another app.',
      );
    }

    await port.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    _sub = port.inputStream?.listen(
      _rx.add,
      onError: (Object e) => _rx.addError(e),
      cancelOnError: false,
    );

    _port = port;
    _baud = baudRate;
  }

  Future<void> setBaudRate(int baud) async {
    final port = _requirePort();
    await port.setPortParameters(
      baud,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    _baud = baud;
  }

  Future<void> write(Uint8List data) async {
    await _requirePort().write(data);
  }

  Future<void> setDtr(bool value) async => _requirePort().setDTR(value);
  Future<void> setRts(bool value) async => _requirePort().setRTS(value);

  /// Classic esptool auto-reset: RTS drives EN (reset), DTR drives GPIO0
  /// (boot select), both through inverting transistors on the board.
  ///
  /// Boards without those transistors ignore this entirely — which is why the
  /// caller falls back to asking the user to press BOOT/RST by hand.
  Future<void> enterDownloadModeClassic() async {
    await setDtr(false); // GPIO0 high
    await setRts(true); // EN low: hold in reset
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await setDtr(true); // GPIO0 low: select download mode
    await setRts(false); // EN high: release reset
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await setDtr(false); // GPIO0 released
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// Reset sequence for parts driven through their own USB-Serial-JTAG
  /// peripheral, where DTR/RTS are interpreted by on-die logic instead of
  /// external transistors.
  Future<void> enterDownloadModeUsbJtag() async {
    await setRts(false);
    await setDtr(false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await setDtr(true);
    await setRts(false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await setRts(true);
    await setDtr(false);
    await setRts(true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await setRts(false);
    await setDtr(false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// Releases reset so the freshly-written application starts running.
  Future<void> hardReset() async {
    await setDtr(false);
    await setRts(true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await setRts(false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _port?.close();
    _port = null;
  }

  Future<void> dispose() async {
    await close();
    await _rx.close();
  }

  UsbPort _requirePort() {
    final p = _port;
    if (p == null) {
      throw EspException('Serial port is not open.', recoverable: false);
    }
    return p;
  }
}
