import 'package:shared_preferences/shared_preferences.dart';

/// Small persistent store for things worth surviving an app restart.
///
/// Deliberately holds no secrets: Wi-Fi network names are remembered so a
/// technician does not retype them on every board, but passwords never are.
class Prefs {
  static const _kSsids = 'known_ssids';
  static const _kBaud = 'working_baud';
  static const _kIpPrefix = 'last_ip_';

  static SharedPreferences? _p;

  static Future<SharedPreferences> _prefs() async =>
      _p ??= await SharedPreferences.getInstance();

  /// Wi-Fi network names previously entered, most recent first.
  static Future<List<String>> knownSsids() async =>
      (await _prefs()).getStringList(_kSsids) ?? const [];

  static Future<void> rememberSsid(String ssid) async {
    final s = ssid.trim();
    if (s.isEmpty) return;
    final p = await _prefs();
    final list = p.getStringList(_kSsids) ?? <String>[];
    list
      ..remove(s)
      ..insert(0, s);
    await p.setStringList(_kSsids, list.take(12).toList());
  }

  /// The serial speed that last produced readable output, so the monitor can
  /// skip re-running the 921600 -> 115200 fallback.
  static Future<int?> workingBaud() async => (await _prefs()).getInt(_kBaud);

  static Future<void> setWorkingBaud(int baud) async =>
      (await _prefs()).setInt(_kBaud, baud);

  /// Last IP seen for a board, keyed by its MAC.
  ///
  /// Only ever presented as *last known* — DHCP can reassign it, so it is not
  /// treated as proof the address is still live.
  static Future<String?> lastIpFor(String mac) async =>
      (await _prefs()).getString('$_kIpPrefix$mac');

  static Future<void> setLastIp(String mac, String ip) async =>
      (await _prefs()).setString('$_kIpPrefix$mac', ip);
}
