import 'sse_frame.dart';

/// Incremental parser for the Server-Sent Events wire format.
///
/// Push decoded text in with [add]; whole frames come back out. Everything
/// partial is retained, so the caller may split the stream at *any* byte —
/// mid-line, mid-frame, or between the `\r` and the `\n` of a CRLF pair.
///
/// Kept deliberately free of I/O so it can be tested by hand-feeding chunks.
class SseParser {
  final StringBuffer _line = StringBuffer();
  final StringBuffer _data = StringBuffer();

  /// True when a `\r` ended the previous line, so a following `\n` is the
  /// other half of a CRLF and must not end a second, empty line.
  bool _sawCr = false;

  bool _hasData = false;
  String? _event;

  /// Persists across events, per spec: `id` is only overwritten by a new `id:`
  /// field, never cleared by a dispatch.
  int? _lastId;

  /// Feeds [chunk] to the parser and returns whatever frames it completed.
  List<SseFrame> add(String chunk) {
    final frames = <SseFrame>[];
    for (final unit in chunk.codeUnits) {
      switch (unit) {
        case 0x0A: // \n
          if (_sawCr) {
            _sawCr = false; // trailing half of CRLF — already handled
            continue;
          }
          _endLine(frames);
        case 0x0D: // \r
          _sawCr = true;
          _endLine(frames);
        default:
          _sawCr = false;
          _line.writeCharCode(unit);
      }
    }
    return frames;
  }

  void _endLine(List<SseFrame> out) {
    final line = _line.toString();
    _line.clear();

    if (line.isEmpty) {
      _dispatch(out);
      return;
    }
    if (line.startsWith(':')) {
      out.add(SseComment(line.substring(1).trim()));
      return;
    }

    final colon = line.indexOf(':');
    final String field;
    final String value;
    if (colon == -1) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      final raw = line.substring(colon + 1);
      value = raw.startsWith(' ') ? raw.substring(1) : raw;
    }

    switch (field) {
      case 'data':
        if (_hasData) _data.write('\n'); // multi-line data joins with newlines
        _data.write(value);
        _hasData = true;
      case 'event':
        _event = value;
      case 'id':
        // Spec: ignore an unparseable id rather than clearing the current one.
        _lastId = int.tryParse(value) ?? _lastId;
      case 'retry':
        break; // this server never sends it; our backoff is client-owned
      default:
        break; // unknown fields are ignored, not errors
    }
  }

  void _dispatch(List<SseFrame> out) {
    // Spec: a blank line with no data buffered dispatches nothing.
    if (_hasData) {
      out.add(
        SseEvent(
          id: _lastId,
          event: _event ?? 'message',
          data: _data.toString(),
        ),
      );
    }
    _data.clear();
    _hasData = false;
    _event = null;
  }
}
