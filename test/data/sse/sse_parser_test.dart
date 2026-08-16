import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/features/watchlist/data/sse/sse_frame.dart';
import 'package:pulse/features/watchlist/data/sse/sse_parser.dart';

/// Feeds [text] to a fresh parser in fixed-size slices, so a test can prove the
/// result does not depend on where the network happened to break the stream.
List<SseFrame> parseInChunks(String text, int chunkSize) {
  final parser = SseParser();
  final frames = <SseFrame>[];
  for (var i = 0; i < text.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, text.length);
    frames.addAll(parser.add(text.substring(i, end)));
  }
  return frames;
}

void main() {
  group('SseParser', () {
    const tickFrame =
        'id: 1042\n'
        'event: tick\n'
        'data: {"s":"EURUSD","b":1.08123,"a":1.08141,"ts":1752912000123}\n'
        '\n';

    test('parses the canonical tick frame', () {
      final frames = SseParser().add(tickFrame);

      expect(frames, hasLength(1));
      final event = frames.single as SseEvent;
      expect(event.id, 1042);
      expect(event.event, 'tick');
      expect(
        event.data,
        '{"s":"EURUSD","b":1.08123,"a":1.08141,"ts":1752912000123}',
      );
    });

    test('surfaces heartbeat comments', () {
      final frames = SseParser().add(': ping\n\n');

      expect(frames, hasLength(1));
      expect((frames.single as SseComment).text, 'ping');
    });

    // The whole point of an incremental parser: TCP decides where the chunk
    // boundaries land, and every one of them must be invisible.
    for (final size in [1, 2, 3, 7, 13, 64]) {
      test('produces the same frame when split into $size-char chunks', () {
        final frames = parseInChunks(tickFrame, size);

        expect(frames, hasLength(1));
        final event = frames.single as SseEvent;
        expect(event.id, 1042);
        expect(event.event, 'tick');
        expect(event.data, contains('EURUSD'));
      });
    }

    test('handles CRLF line endings', () {
      final frames = SseParser().add('id: 7\r\nevent: tick\r\ndata: x\r\n\r\n');

      expect(frames, hasLength(1));
      final event = frames.single as SseEvent;
      expect(event.id, 7);
      expect(event.data, 'x');
    });

    test('handles a CRLF split across two chunks', () {
      final parser = SseParser();
      final frames = [
        ...parser.add('data: x\r'),
        ...parser.add('\n\r\n'), // the \n completing the CR, then a blank line
      ];

      expect(frames, hasLength(1));
      expect((frames.single as SseEvent).data, 'x');
    });

    test('handles bare CR as a line terminator', () {
      final frames = SseParser().add('data: x\r\r');

      expect(frames, hasLength(1));
      expect((frames.single as SseEvent).data, 'x');
    });

    test('joins multi-line data with newlines', () {
      final frames = SseParser().add('data: one\ndata: two\n\n');

      expect((frames.single as SseEvent).data, 'one\ntwo');
    });

    test('strips exactly one leading space from a value', () {
      final frames = SseParser().add('data:  padded\n\n');

      expect((frames.single as SseEvent).data, ' padded');
    });

    test('dispatches a field-less line as an empty value', () {
      final frames = SseParser().add('data\n\n');

      expect((frames.single as SseEvent).data, '');
    });

    // Malformed payloads must still reach the caller as events: dropping them
    // in the parser would hide them from the malformed-tick counter.
    test('dispatches garbage payloads as a default-type event', () {
      final frames = SseParser().add('data: ###garbage-not-json###\n\n');

      expect(frames, hasLength(1));
      final event = frames.single as SseEvent;
      expect(event.event, 'message');
      expect(event.id, isNull);
      expect(event.data, '###garbage-not-json###');
    });

    test('carries the last id forward to events that omit one', () {
      final parser = SseParser();
      final frames = [
        ...parser.add('id: 5\ndata: a\n\n'),
        ...parser.add('data: b\n\n'),
      ];

      expect((frames[0] as SseEvent).id, 5);
      expect((frames[1] as SseEvent).id, 5);
    });

    test('resets event type between frames but keeps the id', () {
      final parser = SseParser();
      final frames = [
        ...parser.add('id: 1\nevent: tick\ndata: a\n\n'),
        ...parser.add('id: 2\ndata: b\n\n'),
      ];

      expect((frames[1] as SseEvent).event, 'message');
      expect((frames[1] as SseEvent).id, 2);
    });

    test('ignores an unparseable id rather than clearing the current one', () {
      final parser = SseParser();
      final frames = [
        ...parser.add('id: 9\ndata: a\n\n'),
        ...parser.add('id: not-a-number\ndata: b\n\n'),
      ];

      expect((frames[1] as SseEvent).id, 9);
    });

    test('dispatches nothing for a blank line with no buffered data', () {
      expect(SseParser().add('\n\n\n'), isEmpty);
    });

    test('withholds a frame until its terminating blank line arrives', () {
      final parser = SseParser();

      expect(parser.add('id: 1\nevent: tick\ndata: a\n'), isEmpty);
      expect(parser.add('\n'), hasLength(1));
    });

    test('parses a run of frames interleaved with heartbeats', () {
      final frames = SseParser().add(
        'id: 1\nevent: tick\ndata: a\n\n'
        ': ping\n\n'
        'id: 2\nevent: gap\ndata: {"resumeFrom":50}\n\n',
      );

      expect(frames, hasLength(3));
      expect((frames[0] as SseEvent).event, 'tick');
      expect(frames[1], isA<SseComment>());
      expect((frames[2] as SseEvent).event, 'gap');
      expect((frames[2] as SseEvent).data, '{"resumeFrom":50}');
    });
  });
}
