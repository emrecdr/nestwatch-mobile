/// The event-stream parser, including the cases a hand-rolled one gets wrong.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/server_events.dart';

Stream<List<int>> _chunks(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

Future<List<String>> _names(List<String> parts) =>
    serverSentEventNames(_chunks(parts)).toList();

void main() {
  group('what nestwatch actually sends', () {
    test('a tagged event dispatches its name', () async {
      expect(await _names(['event: requests\ndata: 1\n\n']), ['requests']);
    });

    test('several in one chunk all arrive, in order', () async {
      expect(
        await _names([
          'event: requests\ndata: 1\n\n'
              'event: usage\ndata: 1\n\n'
              'event: requests\ndata: 1\n\n',
        ]),
        ['requests', 'usage', 'requests'],
      );
    });

    test('the lag tag comes through as itself', () async {
      expect(await _names(['event: all\ndata: 1\n\n']), ['all']);
    });
  });

  group('the keep-alive must not look like news', () {
    test('a bare comment dispatches nothing', () async {
      // axum's KeepAlive sends this on an idle stream. Counting it as an event would
      // turn a quiet house into a refetch every fifteen seconds, forever.
      expect(await _names([':\n\n']), isEmpty);
    });

    test('a commented keep-alive between two events changes nothing', () async {
      expect(
        await _names([
          'event: usage\ndata: 1\n\n',
          ':\n\n',
          ':ping\n\n',
          'event: requests\ndata: 1\n\n',
        ]),
        ['usage', 'requests'],
      );
    });

    test('an event with no data is NOT dispatched', () async {
      // Per spec, and the reason the keep-alive above cannot slip through: dispatch is
      // gated on the data buffer, not on having seen an `event:` line.
      expect(await _names(['event: requests\n\n']), isEmpty);
    });
  });

  group('framing that arrives in pieces', () {
    test('a tag split across two reads is still one tag', () async {
      expect(await _names(['event: requ', 'ests\ndata: 1\n\n']), ['requests']);
    });

    test('a frame split mid-field survives', () async {
      expect(
        await _names(['event: usage\nda', 'ta: 1\n', '\n']),
        ['usage'],
      );
    });

    test('a multi-byte character split down the middle does not corrupt the stream',
        () async {
      // The é is two bytes; hand them over one per chunk. A naive per-chunk utf8.decode
      // throws here, which on a live stream would look like the server hanging up.
      final bytes = utf8.encode('event: usage\ndata: é\n\n');
      final split = bytes.indexOf(0xC3) + 1;
      // Typed as the stream an HttpClientResponse actually is. `Uint8List.sublist`
      // returns a Uint8List, and a Stream<Uint8List> will not accept utf8.decoder —
      // which is a property of the test's literals, not of the response type.
      final Stream<List<int>> stream = Stream.fromIterable(<List<int>>[
        bytes.sublist(0, split),
        bytes.sublist(split),
      ]);
      expect(await serverSentEventNames(stream).toList(), ['usage']);
    });

    test('CRLF line endings parse the same as LF', () async {
      expect(await _names(['event: usage\r\ndata: 1\r\n\r\n']), ['usage']);
    });
  });

  group('spec corners that keep the stream alive', () {
    test('an unknown field is ignored rather than fatal', () async {
      // This is what lets nestwatch add a field before this app ships support for it.
      expect(
        await _names(['event: usage\nid: 7\nretry: 5000\nwhat: ?\ndata: 1\n\n']),
        ['usage'],
      );
    });

    test('a data-only event is the default type', () async {
      expect(await _names(['data: 1\n\n']), ['message']);
    });

    test('exactly one leading space is stripped, not two', () async {
      expect(await _names(['event:  usage\ndata: 1\n\n']), [' usage']);
    });

    test('a field with no colon is legal and valueless', () async {
      expect(await _names(['event\ndata: 1\n\n']), ['message']);
    });

    test('an unterminated final frame is not dispatched', () async {
      // The connection dropped mid-event. Acting on half a frame would be inventing news.
      expect(await _names(['event: requests\ndata: 1\n']), isEmpty);
    });
  });

  group('tags to subjects', () {
    test('a known tag is its own subject', () {
      expect(subjectsOf('requests'), {'requests'});
    });

    test('all fans out to everything', () {
      expect(subjectsOf('all'), knownEventTags);
    });

    test('an unknown tag invalidates nothing', () {
      expect(subjectsOf('weather'), isEmpty);
    });

    test('all is not itself a subject', () {
      expect(knownEventTags, isNot(contains('all')));
    });
  });
}
