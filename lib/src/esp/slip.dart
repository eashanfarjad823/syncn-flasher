import 'dart:typed_data';

/// SLIP (RFC 1055) framing, as used by the ESP ROM bootloader.
///
/// Every command and response on the wire is wrapped in `0xC0 ... 0xC0`, with
/// any literal `0xC0`/`0xDB` inside the payload escaped so it cannot be
/// mistaken for a frame delimiter.
class Slip {
  static const int end = 0xC0;
  static const int esc = 0xDB;
  static const int escEnd = 0xDC;
  static const int escEsc = 0xDD;

  /// Wraps [payload] in a SLIP frame, escaping reserved bytes.
  static Uint8List encode(List<int> payload) {
    final out = BytesBuilder(copy: false);
    out.addByte(end);
    for (final b in payload) {
      switch (b) {
        case end:
          out..addByte(esc)..addByte(escEnd);
        case esc:
          out..addByte(esc)..addByte(escEsc);
        default:
          out.addByte(b);
      }
    }
    out.addByte(end);
    return out.toBytes();
  }
}

/// Incremental SLIP decoder.
///
/// Serial data arrives in arbitrarily-sized chunks that rarely line up with
/// frame boundaries, so bytes are fed in as they arrive and complete frames
/// are emitted via [onFrame].
class SlipDecoder {
  SlipDecoder(this.onFrame);

  /// Called once per complete, unescaped frame.
  final void Function(Uint8List frame) onFrame;

  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool _inFrame = false;
  bool _escaped = false;

  void feed(List<int> data) {
    for (final b in data) {
      if (!_inFrame) {
        // Anything outside a frame is boot-log noise; wait for a delimiter.
        if (b == Slip.end) {
          _inFrame = true;
          _escaped = false;
          _buf.clear();
        }
        continue;
      }

      if (_escaped) {
        _escaped = false;
        // An invalid escape sequence is passed through rather than dropped, so
        // a corrupt frame fails a later checksum instead of silently shrinking.
        _buf.addByte(switch (b) {
          Slip.escEnd => Slip.end,
          Slip.escEsc => Slip.esc,
          _ => b,
        });
        continue;
      }

      switch (b) {
        case Slip.esc:
          _escaped = true;
        case Slip.end:
          // A zero-length frame is just two adjacent delimiters — stay in-frame
          // and treat this as the start of the next one.
          if (_buf.length > 0) {
            onFrame(_buf.toBytes());
            _buf.clear();
          }
        default:
          _buf.addByte(b);
      }
    }
  }

  void reset() {
    _buf.clear();
    _inFrame = false;
    _escaped = false;
  }
}
