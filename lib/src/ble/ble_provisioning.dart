import 'dart:async';
import 'dart:convert';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// Where the BLE commissioning flow currently is.
enum BleStage {
  idle,
  unavailable,
  scanning,
  notFound,
  connecting,
  ready,
  sending,
  success,
  failed,
}

/// A nearby board the app could commission.
class BleCandidate {
  const BleCandidate({
    required this.id,
    required this.name,
    required this.rssi,
    required this.matchesFlashedBoard,
  });

  /// Platform device identifier (a MAC on Android).
  final String id;
  final String name;
  final int rssi;

  /// True when this advertisement's address lines up with the MAC read over
  /// USB during flashing.
  final bool matchesFlashedBoard;
}

/// Why BLE cannot be used right now, phrased for a technician.
class BleUnavailable {
  const BleUnavailable(this.message, this.advice);
  final String message;
  final String advice;
}

/// Speaks the SyncN controller's custom BLE provisioning protocol.
///
/// The firmware exposes ONE service with ONE characteristic carrying a plain
/// ASCII, comma-delimited command language — no JSON:
///
///   `SET,<SSID>,<PASSWORD>`   provide Wi-Fi credentials
///   `STATUS`                  multi-line status block
///   `RESET`                   clear all saved credentials and reboot
///
/// Replies come back on the same handle, prefixed `OK:` or `ERROR:`, or as the
/// literal `INVALID COMMAND.` line.
///
/// Built on flutter_reactive_ble (BSD, Signify) rather than flutter_blue_plus,
/// whose 2.x releases require a paid licence for commercial use.
class BleProvisioningService {
  BleProvisioningService([FlutterReactiveBle? ble])
      : _ble = ble ?? FlutterReactiveBle();

  final FlutterReactiveBle _ble;

  /// Service and characteristic UUIDs recovered from the firmware image.
  static final serviceUuid = Uuid.parse('12345678-1234-1234-1234-123456789abc');
  static final characteristicUuid =
      Uuid.parse('abcd1234-ab12-cd34-ef56-1234567890ab');

  /// Advertised name pattern: SyncN-XXXX, MAC-derived.
  static final _namePattern = RegExp(r'^SyncN[-_]', caseSensitive: false);

  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  QualifiedCharacteristic? _char;
  String? _connectedName;

  final _responses = StreamController<String>.broadcast();

  /// Every reply received, for the UI transcript.
  Stream<String> get responses => _responses.stream;

  String? get connectedName => _connectedName;
  bool get isConnected => _char != null;

  /// Translates the radio's state into something worth showing a technician,
  /// or null when BLE is ready to use.
  Future<BleUnavailable?> checkAvailability() async {
    var status = _ble.status;
    if (status == BleStatus.unknown) {
      // The first reading is often 'unknown' before the platform reports in.
      status = await _ble.statusStream
          .firstWhere((s) => s != BleStatus.unknown)
          .timeout(const Duration(seconds: 5), onTimeout: () => BleStatus.unknown);
    }

    return switch (status) {
      BleStatus.ready => null,
      BleStatus.unsupported => const BleUnavailable(
          'This phone does not support Bluetooth Low Energy.',
          'Flashing, the serial monitor and the device portal all still work '
              'without it.',
        ),
      BleStatus.poweredOff => const BleUnavailable(
          'Bluetooth is turned off.',
          'Turn Bluetooth on, then scan again.',
        ),
      BleStatus.unauthorized => const BleUnavailable(
          'This app is not allowed to use Bluetooth.',
          'Grant the Nearby devices permission in Android settings. On Android '
              '11 or older, BLE scanning also needs Location, which this app '
              'does not request — use Android 12 or newer for BLE setup.',
        ),
      BleStatus.locationServicesDisabled => const BleUnavailable(
          'Location services are switched off.',
          'Android 11 and older require Location to be on before any app can '
              'scan for Bluetooth devices. Turn it on, or use a phone running '
              'Android 12 or newer.',
        ),
      BleStatus.unknown => const BleUnavailable(
          'Bluetooth state is unknown.',
          'Make sure Bluetooth is on, then scan again.',
        ),
    };
  }

  /// Scans for SyncN controllers.
  ///
  /// [flashedMac] is the Wi-Fi MAC read over USB. An ESP32's BLE address is
  /// commonly the base address plus a small offset, so matching is loose:
  /// same first five octets, last octet within a few counts.
  Future<List<BleCandidate>> scan({
    String? flashedMac,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final found = <String, BleCandidate>{};
    final done = Completer<void>();

    // Deliberately unfiltered: the firmware may advertise only its name, and a
    // service-filtered scan would then return nothing at all.
    final sub = _ble
        .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
        .listen(
      (d) {
        final isSyncn =
            _namePattern.hasMatch(d.name) || d.serviceUuids.contains(serviceUuid);
        if (!isSyncn) return;
        found[d.id] = BleCandidate(
          id: d.id,
          name: d.name.isEmpty ? d.id : d.name,
          rssi: d.rssi,
          matchesFlashedBoard: macLooselyMatches(flashedMac, d.id),
        );
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
    );

    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete();
    });

    try {
      await done.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }

    return found.values.toList()
      ..sort((a, b) {
        if (a.matchesFlashedBoard != b.matchesFlashedBoard) {
          return a.matchesFlashedBoard ? -1 : 1;
        }
        return b.rssi.compareTo(a.rssi);
      });
  }

  /// Compares two MAC strings allowing for the small offset between an
  /// ESP32's Wi-Fi and BLE addresses.
  static bool macLooselyMatches(String? wifiMac, String bleId) {
    if (wifiMac == null) return false;
    final a = wifiMac.toUpperCase().replaceAll('-', ':').split(':');
    final b = bleId.toUpperCase().replaceAll('-', ':').split(':');
    if (a.length != 6 || b.length != 6) return false;
    for (var i = 0; i < 5; i++) {
      if (a[i] != b[i]) return false;
    }
    final la = int.tryParse(a[5], radix: 16);
    final lb = int.tryParse(b[5], radix: 16);
    if (la == null || lb == null) return false;
    return (la - lb).abs() <= 4;
  }

  /// Connects and locates the provisioning characteristic.
  ///
  /// The connection lives as long as its stream subscription, so the
  /// subscription is retained until [disconnect].
  Future<void> connect(BleCandidate candidate) async {
    await disconnect();

    final connected = Completer<void>();

    _connSub = _ble
        .connectToDevice(
          id: candidate.id,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
      (update) {
        switch (update.connectionState) {
          case DeviceConnectionState.connected:
            if (!connected.isCompleted) connected.complete();
          case DeviceConnectionState.disconnected:
            if (!connected.isCompleted) {
              connected.completeError(
                StateError('The board disconnected before setup could start.'),
              );
            }
            _char = null;
          case DeviceConnectionState.connecting:
          case DeviceConnectionState.disconnecting:
            break;
        }
      },
      onError: (Object e) {
        if (!connected.isCompleted) connected.completeError(e);
      },
    );

    await connected.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException('Timed out connecting to the board.'),
    );

    await _ble.discoverAllServices(candidate.id);

    final characteristic = QualifiedCharacteristic(
      serviceId: serviceUuid,
      characteristicId: characteristicUuid,
      deviceId: candidate.id,
    );

    // Replies arrive on the same handle commands go out on. Not every build
    // marks it notifiable, so a failure here is not fatal — _send falls back
    // to reading the value directly.
    try {
      _notifySub = _ble.subscribeToCharacteristic(characteristic).listen(
        (v) {
          final text = _decode(v).trim();
          if (text.isNotEmpty) _responses.add(text);
        },
        onError: (Object _) {},
      );
    } catch (_) {
      _notifySub = null;
    }

    _char = characteristic;

    _connectedName = candidate.name;
  }

  static String _decode(List<int> v) =>
      const Utf8Decoder(allowMalformed: true).convert(v);

  /// Sends one command and waits for the board's reply.
  Future<String> _send(
    String command, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final c = _char;
    if (c == null) throw StateError('Not connected to a board.');

    final replyFuture =
        _responses.stream.first.timeout(timeout, onTimeout: () => '');

    final bytes = utf8.encode(command);
    try {
      await _ble.writeCharacteristicWithResponse(c, value: bytes);
    } catch (_) {
      await _ble.writeCharacteristicWithoutResponse(c, value: bytes);
    }

    var reply = await replyFuture;

    // No notification arrived: poll the characteristic instead.
    if (reply.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        reply = _decode(await _ble.readCharacteristic(c)).trim();
      } catch (_) {
        reply = '';
      }
    }

    if (reply.isEmpty) {
      throw TimeoutException('The board did not reply to "$command".');
    }
    return reply;
  }

  /// Rejects input the firmware itself would reject, or that the
  /// comma-delimited protocol cannot represent.
  static String? validate(String ssid, String password) {
    if (ssid.trim().isEmpty) return 'Enter the Wi-Fi network name.';
    if (ssid.contains(',')) {
      return 'The network name cannot contain a comma - the board separates '
          'fields with commas.';
    }
    if (password.contains(',')) {
      return 'The password cannot contain a comma - the board separates '
          'fields with commas.';
    }
    return null;
  }

  Future<String> sendWifi(String ssid, String password) =>
      _send('SET,$ssid,$password');

  Future<String> requestStatus() => _send('STATUS');

  /// Clears every saved credential and reboots the board.
  Future<String> requestReset() => _send('RESET');

  /// True when a reply indicates failure rather than success.
  static bool isError(String reply) {
    final r = reply.trim().toUpperCase();
    return r.startsWith('ERROR') || r.startsWith('INVALID COMMAND');
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    // Cancelling the connection subscription is what closes the link.
    await _connSub?.cancel();
    _connSub = null;
    _char = null;

    _connectedName = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _responses.close();
  }
}
