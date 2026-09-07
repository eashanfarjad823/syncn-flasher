import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../esp/protocol.dart';
import '../esp/transport.dart';
import '../prefs.dart';

/// One line of console output, or a status note the session inserted itself.
class LogLine {
  const LogLine(this.text, {this.isNote = false});

  final String text;

  /// True for lines the app added (reconnects, speed changes) rather than
  /// bytes that came off the wire.
  final bool isNote;
}

/// A long-lived serial console attached to one board.
///
/// Beyond streaming bytes it does three jobs the plain monitor did not:
/// picks a readable baud rate, survives the board resetting and
/// re-enumerating, and watches the log for the device's IP address.
class SerialLogSession {
  SerialLogSession(this.device);

  final SerialDeviceInfo device;

  /// Tried in order. 921600 first because that is what the flashing flow uses
  /// and what was requested; 115200 is the Arduino default that this firmware
  /// actually logs at, so it is the fallback that usually wins.
  static const candidateBauds = [921600, 115200];

  SerialTransport? _transport;
  StreamSubscription<Uint8List>? _sub;
  Timer? _probeTimer;
  bool _disposed = false;
  bool _reconnecting = false;

  final _lines = <LogLine>[];
  List<LogLine> get lines => List.unmodifiable(_lines);

  final _controller = StreamController<void>.broadcast();

  /// Fires whenever anything observable changed (new lines, baud, IP, state).
  Stream<void> get changes => _controller.stream;

  int? _baud;
  int? get baud => _baud;

  bool get isRunning => _transport?.isOpen ?? false;

  String? _ip;

  /// Device IP as parsed out of the firmware's own log output.
  String? get detectedIp => _ip;

  String _partial = '';

  // Readability sampling for the baud fallback.
  int _printable = 0;
  int _total = 0;
  bool _baudSettled = false;

  /// Matches the firmware's own reporting, e.g.
  ///   [NETWORK] Connected SSID=Foo IP=192.168.1.50 RSSI=-52
  ///   [OTA] WiFi connected. IP=192.168.1.50 RSSI=-52 dBm
  ///   [WEB] Portal ready: http://192.168.1.50/
  static final _ipPattern = RegExp(
    r'(?:IP[=:\s]\s*|https?://)((?:\d{1,3}\.){3}\d{1,3})',
    caseSensitive: false,
  );

  void _note(String text) {
    _lines.add(LogLine(text, isNote: true));
    _emit();
  }

  void _emit() {
    if (!_disposed && !_controller.isClosed) _controller.add(null);
  }

  /// Opens the port, preferring a rate already known to work.
  Future<void> start() async {
    final remembered = await Prefs.workingBaud();
    final first = remembered ?? candidateBauds.first;
    await _open(first, settleImmediately: remembered != null);
  }

  Future<void> _open(int baud, {bool settleImmediately = false}) async {
    if (_disposed) return;

    await _closeTransport();

    final t = SerialTransport(device);
    try {
      await t.open(baudRate: baud);
    } on EspException catch (e) {
      _note('Could not open the port: ${e.message}');
      return;
    }

    // Release the board so it runs its application rather than sitting in
    // reset while we watch.
    await t.setDtr(false);
    await t.setRts(false);

    _transport = t;
    _baud = baud;
    _printable = 0;
    _total = 0;
    _baudSettled = settleImmediately;

    _sub = t.incoming.listen(_onData, onError: (_) => _handleDrop());
    _emit();

    if (!_baudSettled) _armReadabilityProbe(baud);
  }

  /// Samples the first couple of seconds of traffic. Output that is mostly
  /// non-printable means the rate is wrong, so drop to the next candidate.
  void _armReadabilityProbe(int baud) {
    _probeTimer?.cancel();
    _probeTimer = Timer(const Duration(milliseconds: 2500), () async {
      if (_disposed || _baudSettled) return;

      final sampled = _total;
      final legible = sampled == 0 ? 1.0 : _printable / sampled;

      // Nothing arrived at all: cannot judge the rate, so keep waiting rather
      // than churning the port on a board that is simply quiet.
      if (sampled < 16) return;

      if (legible >= 0.85) {
        _baudSettled = true;
        await Prefs.setWorkingBaud(baud);
        return;
      }

      final next = candidateBauds.firstWhere(
        (b) => b != baud,
        orElse: () => baud,
      );
      if (next == baud) {
        _baudSettled = true;
        return;
      }

      _note('Output unreadable at $baud baud - switching to $next.');
      _lines.removeWhere((l) => !l.isNote);
      _partial = '';
      await _open(next, settleImmediately: true);
      await Prefs.setWorkingBaud(next);
    });
  }

  void _onData(Uint8List data) {
    if (_disposed) return;

    for (final b in data) {
      _total++;
      if (b == 0x0A || b == 0x0D || b == 0x09 || (b >= 0x20 && b < 0x7F)) {
        _printable++;
      }
    }

    final text = const Utf8Decoder(allowMalformed: true).convert(data);
    _partial += text.replaceAll('\r', '');

    final parts = _partial.split('\n');
    _partial = parts.removeLast();
    if (parts.isEmpty) return;

    for (final line in parts) {
      _lines.add(LogLine(line));
      _scanForIp(line);
    }
    if (_lines.length > 4000) {
      _lines.removeRange(0, _lines.length - 4000);
    }
    _emit();
  }

  void _scanForIp(String line) {
    final m = _ipPattern.firstMatch(line);
    if (m == null) return;
    final ip = m.group(1);
    if (ip == null || ip == '0.0.0.0' || ip.startsWith('127.')) return;
    if (ip == _ip) return;
    _ip = ip;
    _note('Device IP detected: $ip');
  }

  /// The board resetting drops the USB device; reconnect rather than dying,
  /// but say so, because a board that reconnects repeatedly is boot-looping
  /// and that should be visible at a glance.
  Future<void> _handleDrop() async {
    if (_disposed || _reconnecting) return;
    _reconnecting = true;
    _note('Device disconnected - reconnecting...');

    await _closeTransport();

    for (var attempt = 0; attempt < 10 && !_disposed; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final devices = await SerialTransport.listDevices();
      final match = devices.where((d) => d.vid == device.vid && d.pid == device.pid);
      if (match.isEmpty) continue;

      await _open(_baud ?? candidateBauds.first, settleImmediately: true);
      if (isRunning) {
        _note('Reconnected.');
        _reconnecting = false;
        return;
      }
    }

    _note('Could not reconnect. Tap reconnect to try again.');
    _reconnecting = false;
    _emit();
  }

  /// Called by the UI when a USB attach/detach event is observed.
  Future<void> onUsbEvent() async {
    if (_disposed || isRunning || _reconnecting) return;
    await _handleDrop();
  }

  Future<void> reconnect() async {
    if (_disposed) return;
    await _open(_baud ?? candidateBauds.first, settleImmediately: true);
    _emit();
  }

  Future<void> setBaud(int baud) async {
    await _open(baud, settleImmediately: true);
    await Prefs.setWorkingBaud(baud);
    _emit();
  }

  void clear() {
    _lines.clear();
    _emit();
  }

  String get fullText => _lines.map((l) => l.text).join('\n');

  Future<void> _closeTransport() async {
    _probeTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    await _transport?.dispose();
    _transport = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _closeTransport();
    await _controller.close();
  }
}
