import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music_assistant/music_assistant_api.dart';

const _greeting = {
  'server_id': 'fe2f5b6fd78e4608bb8b075a6c269fbf',
  'server_version': '2.6.3',
  'schema_version': 26,
  'min_supported_schema_version': 24,
  'base_url': 'http://10.0.2.107:8095',
  'homeassistant_addon': false,
  'onboard_done': true,
};

void main() {
  group('handshake', () {
    test('reads the unsolicited greeting and exposes server metadata', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      expect(harness.client.serverVersion, '2.6.3');
      expect(harness.client.schemaVersion, 26);
      expect(harness.client.isConnected, isTrue);
      // Derived from the connect URL, not the greeting's base_url, so a server
      // advertising an unreachable address cannot break image loading.
      expect(harness.client.httpBaseUrl.toString(), 'http://127.0.0.1:8095');
    });

    test('normalises the connect URL to the single /ws endpoint', () async {
      final harness = await _Harness.connected(baseUrl: Uri.parse('https://ma.example.com/'));
      addTearDown(harness.dispose);

      expect(harness.channel.url.toString(), 'wss://ma.example.com/ws');
    });

    test('a socket that never opens fails inside the handshake budget', () {
      // The device bug. `handshakeTimeout` bounded only the greeting, and the
      // socket open was awaited with no deadline at all — so a host that
      // accepts no connection left `connect()` hanging on the platform's TCP
      // retransmit schedule. Measured against a blackholed address: still
      // unsettled 24 seconds into an 8 second budget, with the add-server form
      // showing a spinner and no error the entire time.
      //
      // Fake time, because the real thing is a minute of wall clock: the point
      // under test is that the deadline exists, not how long Darwin retries.
      fakeAsync((async) {
        // A factory whose future never completes is exactly a SYN into a
        // blackhole — no answer, no refusal, no error.
        final client = MusicAssistantApi(
          autoReconnect: false,
          handshakeTimeout: const Duration(seconds: 8),
          channelFactory: (_) => Completer<MaChannel>().future,
        );
        Object? outcome;
        unawaited(
          client
              .connect(Uri.parse('http://10.255.255.1:8095'))
              .then<void>((_) => outcome = 'connected', onError: (Object e) => outcome = e),
        );

        async.elapse(const Duration(seconds: 7));
        expect(outcome, isNull, reason: 'must not give up before its budget');

        async.elapse(const Duration(seconds: 2));
        expect(outcome, isA<MaConnectionException>());
        // Named apart from "Server sent no greeting": nothing answering and a
        // port that answers but stays silent have different causes.
        expect((outcome! as MaConnectionException).message, contains('No answer from 10.255.255.1:8095'));
        client.dispose();
      });
    });
  });

  group('message_id correlation', () {
    test('resolves out-of-order replies to the right request', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final albums = harness.client.sendCommand('music/albums/count');
      final artists = harness.client.sendCommand('music/artists/count');
      final tracks = harness.client.sendCommand('music/tracks/count');
      await harness.pump();

      final ids = harness.sentMessageIds;
      expect(ids, hasLength(3));

      // Reply in 3, 1, 2 order — the server genuinely does this.
      harness.channel.emit({'message_id': ids[2], 'result': 365691, 'partial': false});
      harness.channel.emit({'message_id': ids[0], 'result': 32717, 'partial': false});
      harness.channel.emit({'message_id': ids[1], 'result': 10331, 'partial': false});

      expect(await albums, 32717);
      expect(await artists, 10331);
      expect(await tracks, 365691);
    });

    test('a reply for one request never completes another', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final first = harness.client.sendCommand('music/albums/count');
      final second = harness.client.sendCommand('music/artists/count');
      await harness.pump();

      harness.channel.emit({'message_id': harness.sentMessageIds[1], 'result': 7});
      await harness.pump();

      expect(await second, 7);
      // The first request must still be outstanding, not resolved by proximity.
      var firstDone = false;
      unawaited(first.then<void>((_) => firstDone = true).catchError((Object _) {}));
      await harness.pump();
      expect(firstDone, isFalse);

      harness.channel.emit({'message_id': harness.sentMessageIds[0], 'result': 28671});
      expect(await first, 28671);
    });

    test('an unknown message_id is ignored instead of failing a live request', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final pending = harness.client.sendCommand('music/albums/count');
      await harness.pump();

      harness.channel.emit({'message_id': 'stale-9999', 'result': 1});
      harness.channel.emit({'message_id': harness.sentMessageIds.first, 'result': 28671});

      expect(await pending, 28671);
    });

    test('an error frame surfaces error_code and details', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final pending = harness.client.sendCommand('this/does/not/exist');
      await harness.pump();
      harness.channel.emit({
        'message_id': harness.sentMessageIds.first,
        'error_code': 12,
        'details': 'Invalid command: this/does/not/exist',
      });

      await expectLater(
        pending,
        throwsA(
          isA<MaRequestException>()
              .having((error) => error.errorCode, 'errorCode', 12)
              .having((error) => error.message, 'message', contains('Invalid command')),
        ),
      );
    });

    test('a request that is never answered times out', () async {
      final harness = await _Harness.connected(requestTimeout: const Duration(milliseconds: 40));
      addTearDown(harness.dispose);

      await expectLater(harness.client.sendCommand('music/albums/count'), throwsA(isA<MaTimeoutException>()));
    });
  });

  group('concurrency limit', () {
    // These exist because the server has no way to defend itself. Music
    // Assistant drops a client at `Client exceeded max pending messages: 512`,
    // but it stops being usable long before that: a saturated server answers
    // `count` in 9ms while `players/all` and every `library_items` request hang
    // for an hour, and only a container restart brings it back. That happened
    // three times in one day, and the smallest fan-out that did it was seven
    // parallel `music/item_by_uri` calls. Two features — "Most played" as a row,
    // and expanding the "recently played" rows — were deleted rather than
    // fixed, because there was nothing here to make them safe.

    test('twenty concurrent callers never put more than the limit on the wire', () async {
      const limit = 3;
      const callers = 20;
      final harness = await _Harness.connected(maxConcurrentRequests: limit);
      addTearDown(harness.dispose);

      // One `music/item_by_uri` per row is exactly the shape of the expansion
      // that was dropped: twenty rows, twenty requests, all issued at once.
      final results = [
        for (var i = 0; i < callers; i++)
          harness.client.sendCommand('music/item_by_uri', args: {'uri': 'library://track/$i'}),
      ];
      await harness.pump();

      var highWater = 0;
      for (var answered = 0; answered < callers; answered++) {
        final outstanding = harness.channel.sent.length - answered;
        if (outstanding > highWater) highWater = outstanding;
        expect(
          harness.client.inFlightRequestCount,
          lessThanOrEqualTo(limit),
          reason: 'the client must never hold more than $limit slots',
        );

        // Answer the oldest outstanding request, and answer it with its own
        // index — so a mis-routed reply shows up as a wrong value below.
        harness.channel.emit({'message_id': harness.sentMessageIds[answered], 'result': answered});
        await harness.pump();
      }

      expect(
        highWater,
        limit,
        reason: 'without a limiter all $callers frames go out at once; the wedge is the whole point',
      );
      // Queued, not dropped: every caller is still served.
      expect(harness.channel.sent, hasLength(callers));
      expect(harness.client.queuedRequestCount, 0);
      expect(harness.client.inFlightRequestCount, 0);
      for (var i = 0; i < callers; i++) {
        expect(await results[i], i, reason: 'queueing must not disturb message_id correlation');
      }
    });

    test('a queued request still correlates by message_id, not by arrival order', () async {
      final harness = await _Harness.connected(maxConcurrentRequests: 2);
      addTearDown(harness.dispose);

      final first = harness.client.sendCommand('music/albums/count');
      final second = harness.client.sendCommand('music/artists/count');
      final third = harness.client.sendCommand('music/tracks/count');
      await harness.pump();

      expect(harness.channel.sent, hasLength(2), reason: 'the third is behind the limit');
      expect(harness.client.queuedRequestCount, 1);

      // Reply to the second first. That releases a slot, so the third goes out
      // while the first is still outstanding.
      harness.channel.emit({'message_id': harness.sentMessageIds[1], 'result': 10331});
      await harness.pump();
      expect(harness.channel.sent, hasLength(3));

      // And now answer the remaining two in reverse order.
      harness.channel.emit({'message_id': harness.sentMessageIds[2], 'result': 365691});
      harness.channel.emit({'message_id': harness.sentMessageIds[0], 'result': 32717});

      expect(await first, 32717);
      expect(await second, 10331);
      expect(await third, 365691);
    });

    test('time spent waiting for a slot is not charged to the request timeout', () async {
      // The deadline is a claim about how long the *server* may take. Starting
      // the timer when the caller asked would make a deep fan-out fail from the
      // back forwards under a limiter that is doing exactly its job — and the
      // failure would look like server slowness, which is the misdiagnosis this
      // whole area keeps producing.
      final harness = await _Harness.connected(
        maxConcurrentRequests: 1,
        requestTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(harness.dispose);

      final blocker = harness.client.sendCommand('music/search');
      final queued = harness.client.sendCommand('music/albums/count');
      await harness.pump();
      expect(harness.channel.sent, hasLength(1), reason: 'the second request must be waiting for a slot');

      // Hold the only slot for most of the deadline.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      harness.channel.emit({'message_id': harness.sentMessageIds.first, 'result': 1});
      expect(await blocker, 1);
      await harness.pump();
      expect(harness.channel.sent, hasLength(2), reason: 'the freed slot must dispatch the queued request');

      // Past 120ms since the caller asked, but well inside 120ms since it was
      // sent. It must still be alive.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      harness.channel.emit({'message_id': harness.sentMessageIds[1], 'result': 28671});
      expect(await queued, 28671);
    });

    test('a timed-out request releases its slot so the queue keeps draining', () async {
      // The path that matters against a server that has gone quiet: if a
      // timeout did not free its slot the queue would deadlock behind it and
      // the app would hang rather than surface the failure.
      final harness = await _Harness.connected(
        maxConcurrentRequests: 1,
        requestTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(harness.dispose);

      final ignored = harness.client.sendCommand('players/all');
      final failure = expectLater(ignored, throwsA(isA<MaTimeoutException>()));
      final queued = harness.client.sendCommand('music/albums/count');
      await harness.pump();
      expect(harness.channel.sent, hasLength(1));

      await failure;
      await harness.pump();

      expect(harness.channel.sent, hasLength(2));
      harness.channel.emit({'message_id': harness.sentMessageIds[1], 'result': 28671});
      expect(await queued, 28671);
    });

    test('a chunked response holds its slot until the terminating frame', () async {
      // A `partial: true` stream is still work in progress on the server.
      // Releasing on the first chunk would let the client run over the limit by
      // however many streams were open.
      final harness = await _Harness.connected(maxConcurrentRequests: 1);
      addTearDown(harness.dispose);

      final chunked = harness.client.sendCommand('music/playlists/playlist_tracks');
      final queued = harness.client.sendCommand('music/albums/count');
      await harness.pump();
      final messageId = harness.sentMessageIds.first;

      harness.channel.emit({
        'message_id': messageId,
        'result': [
          {'item_id': '1', 'name': 'A'},
        ],
        'partial': true,
      });
      await harness.pump();
      expect(harness.channel.sent, hasLength(1), reason: 'a chunk is not a completion');

      harness.channel.emit({'message_id': messageId, 'result': <dynamic>[], 'partial': false});
      expect(await chunked as List<dynamic>, hasLength(1));
      await harness.pump();

      expect(harness.channel.sent, hasLength(2));
      harness.channel.emit({'message_id': harness.sentMessageIds[1], 'result': 28671});
      expect(await queued, 28671);
    });

    test('a dropped socket fails queued requests as well as in-flight ones', () async {
      // A queued request that survived the drop would be sent on a connection
      // that never asked for it; one that did not survive would hang forever
      // with nothing left to dispatch it.
      final harness = await _Harness.connected(maxConcurrentRequests: 1, autoReconnect: false);
      addTearDown(harness.dispose);

      final inFlight = harness.client.sendCommand('players/all');
      final queued = harness.client.sendCommand('music/albums/count');
      final failures = Future.wait([
        expectLater(inFlight, throwsA(isA<MaConnectionException>())),
        expectLater(queued, throwsA(isA<MaConnectionException>())),
      ]);
      await harness.pump();
      expect(harness.client.queuedRequestCount, 1);

      await harness.channel.closeFromServer();
      await harness.pump();

      await failures;
      expect(harness.client.queuedRequestCount, 0);
    });

    test('the default bound sits under the fan-out that wedged a real server', () {
      final client = MusicAssistantApi();
      addTearDown(client.dispose);

      expect(client.maxConcurrentRequests, MusicAssistantApi.defaultMaxConcurrentRequests);
      expect(MusicAssistantApi.defaultMaxConcurrentRequests, greaterThan(0));
      // 512 is where the protocol drops the client outright, but seven parallel
      // `music/item_by_uri` calls were enough to hang a real server for an hour.
      // The default has to be chosen against the seven, not the 512.
      expect(
        MusicAssistantApi.defaultMaxConcurrentRequests,
        lessThan(7),
        reason: 'a default at or above the measured wedge is not a limit',
      );
    });
  });

  group('sendCommandForMap', () {
    test('a JSON object comes back as-is', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final pending = harness.client.sendCommandForMap('music/search');
      await harness.pump();
      harness.channel.emit({
        'message_id': harness.sentMessageIds.last,
        'result': {'albums': <dynamic>[]},
      });

      expect(await pending, {'albums': <dynamic>[]});
    });

    test('a null result is "nothing there", so it maps to the empty object', () async {
      // `music/item_by_uri` answers null for a uri that no longer resolves.
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final pending = harness.client.sendCommandForMap('music/item_by_uri');
      await harness.pump();
      harness.channel.emit({'message_id': harness.sentMessageIds.last, 'result': null});

      expect(await pending, isEmpty);
    });

    test('a non-object result is a fault, not an empty answer', () async {
      // Returning `const {}` here made a renamed command, an interposed proxy
      // or an unknown schema all render as "your library is empty" — an
      // outcome nobody reports, because it looks like the truth.
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final pending = harness.client.sendCommandForMap('music/search');
      final failure = expectLater(
        pending,
        throwsA(isA<MaProtocolException>().having((e) => e.command, 'command', 'music/search')),
      );
      await harness.pump();
      harness.channel.emit({
        'message_id': harness.sentMessageIds.last,
        'result': ['not', 'an', 'object'],
      });

      await failure;
    });
  });

  group('events', () {
    test('event frames go to the event stream and are not treated as replies', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final received = <MaEvent>[];
      final subscription = harness.client.events.listen(received.add);
      addTearDown(subscription.cancel);

      final pending = harness.client.sendCommand('music/albums/count');
      await harness.pump();

      // The frames immediately following a request are, in practice, events.
      harness.channel.emit({'event': 'media_item_added', 'object_id': 'library://track/365455', 'data': {}});
      harness.channel.emit({
        'event': 'player_updated',
        'object_id': 'ma_plezy_abc',
        'data': {'state': 'playing'},
      });
      await harness.pump();

      expect(received.map((event) => event.event), ['media_item_added', 'player_updated']);
      expect(received.last.data['state'], 'playing');

      var resolved = false;
      unawaited(pending.then<void>((_) => resolved = true).catchError((Object _) {}));
      await harness.pump();
      expect(resolved, isFalse, reason: 'events must not resolve an outstanding request');

      harness.channel.emit({'message_id': harness.sentMessageIds.first, 'result': 28671});
      expect(await pending, 28671);
    });

    test('a malformed frame is dropped without breaking the stream', () async {
      final harness = await _Harness.connected();
      addTearDown(harness.dispose);

      final received = <MaEvent>[];
      final subscription = harness.client.events.listen(received.add);
      addTearDown(subscription.cancel);

      harness.channel.emitRaw('not json at all');
      harness.channel.emitRaw('[1,2,3]');
      harness.channel.emit({'event': 'queue_updated', 'object_id': 'q', 'data': {}});
      await harness.pump();

      expect(received.single.event, 'queue_updated');
    });
  });

  group('lifecycle', () {
    test('a dropped socket fails in-flight requests', () async {
      final harness = await _Harness.connected(autoReconnect: false);
      addTearDown(harness.dispose);

      final pending = harness.client.sendCommand('music/albums/count');
      // Attached before the drop: the client fails the request synchronously
      // from the close callback, so a later listener would be too late and the
      // error would be reported as unhandled.
      final failure = expectLater(pending, throwsA(isA<MaConnectionException>()));
      await harness.pump();
      await harness.channel.closeFromServer();
      await harness.pump();

      await failure;
      expect(harness.client.isConnected, isFalse);
    });

    test('dispose cancels pending requests and the scheduled retry', () async {
      final harness = await _Harness.connected(retryBaseDelay: const Duration(milliseconds: 5));

      final pending = harness.client.sendCommand('music/albums/count');
      final failure = expectLater(pending, throwsA(isA<MaConnectionException>()));
      await harness.pump();
      await harness.channel.closeFromServer();
      await harness.pump();

      await failure;

      final attemptsAtDispose = harness.channel.openCount;
      await harness.client.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(harness.channel.openCount, attemptsAtDispose, reason: 'no retry may run after dispose');
    });
  });

  group('keepalive', () {
    test('the production transport arms a WebSocket ping', () async {
      // The whole point: web_socket_channel defaults pingInterval to null, and
      // with it null a link that dies silently (AP reboot, Wi-Fi→cellular, iOS
      // suspending the socket) produces no onDone and no onError. The client
      // then sits in `connected` forever with a socket nothing can travel over.
      // Asserted against a real loopback server because the assignment is one
      // line that reads like decoration.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.first.then((request) async {
          final peer = await WebSocketTransformer.upgrade(request);
          try {
            await peer.done;
          } finally {
            await peer.close();
          }
        }),
      );

      final socket = await MusicAssistantApi.connectKeepAliveSocket(
        Uri.parse('ws://${server.address.address}:${server.port}/ws'),
        const Duration(seconds: 7),
      );
      addTearDown(() => socket.close());

      expect(socket.pingInterval, const Duration(seconds: 7));
    });

    test('the default interval is a real duration, not null', () {
      // A null or zero interval is the shipped bug, not a configuration.
      expect(MusicAssistantApi().pingInterval, MusicAssistantApi.defaultPingInterval);
      expect(MusicAssistantApi.defaultPingInterval, greaterThan(Duration.zero));
    });
  });

  group('reconnect backoff', () {
    test('doubles and caps at 30s', () {
      Duration delay(int attempt) => MusicAssistantApi.backoffDelay(attempt);

      expect(delay(0), const Duration(seconds: 1));
      expect(delay(1), const Duration(seconds: 2));
      expect(delay(2), const Duration(seconds: 4));
      expect(delay(3), const Duration(seconds: 8));
      expect(delay(4), const Duration(seconds: 16));
      expect(delay(5), MusicAssistantApi.maxRetryDelay);
      expect(delay(12), MusicAssistantApi.maxRetryDelay);
    });

    test('retries do not reset the attempt counter', () async {
      // Regression guard for the shipped bug: routing retries through the
      // public connect(), which resets the counter, pinned every retry at the
      // first rung of the ladder and produced an endless fast reconnect loop.
      final channel = _FakeChannel(failConnections: true);
      final client = MusicAssistantApi(
        channelFactory: channel.open,
        retryBaseDelay: const Duration(milliseconds: 5),
        maxRetryDelayOverride: const Duration(milliseconds: 40),
      );
      addTearDown(client.dispose);

      await expectLater(client.connect(Uri.parse('http://127.0.0.1:8095')), throwsA(anything));

      // Wait long enough for several rungs (5 + 10 + 20 + 40ms) to elapse.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(channel.openCount, greaterThan(1), reason: 'the retry loop must actually run');
      expect(
        client.retryAttempt,
        greaterThanOrEqualTo(channel.openCount),
        reason: 'every failed attempt must advance the ladder',
      );
    });

    test('a successful connect resets the ladder', () async {
      final channel = _FakeChannel(failConnections: true);
      final client = MusicAssistantApi(
        channelFactory: channel.open,
        retryBaseDelay: const Duration(milliseconds: 5),
        maxRetryDelayOverride: const Duration(milliseconds: 20),
      );
      addTearDown(client.dispose);

      await expectLater(client.connect(Uri.parse('http://127.0.0.1:8095')), throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(client.retryAttempt, greaterThan(1));

      channel.failConnections = false;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      channel.emit(_greeting);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.isConnected, isTrue);
      expect(client.retryAttempt, 0);
    });
  });
}

// --- fakes ------------------------------------------------------------------

/// In-memory [MaChannel] standing in for the WebSocket.
class _FakeChannel implements MaChannel {
  final List<String> sent = [];
  final StreamController<dynamic> _incoming = StreamController<dynamic>.broadcast();

  /// Number of times the client asked for a transport, i.e. connection
  /// attempts. Used to observe the retry loop.
  int openCount = 0;
  bool failConnections;
  Uri? url;

  _FakeChannel({this.failConnections = false});

  Future<MaChannel> open(Uri url) async {
    openCount++;
    this.url = url;
    if (failConnections) throw const SocketFailure();
    return this;
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  Future<void> close() async {}

  void emit(Map<String, dynamic> frame) => emitRaw(jsonEncode(frame));

  void emitRaw(String frame) {
    if (!_incoming.isClosed) _incoming.add(frame);
  }

  Future<void> closeFromServer() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  Future<void> shutdown() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

class SocketFailure implements Exception {
  const SocketFailure();
}

/// A connected client plus its fake transport.
class _Harness {
  final MusicAssistantApi client;
  final _FakeChannel channel;

  _Harness(this.client, this.channel);

  static Future<_Harness> connected({
    Uri? baseUrl,
    Duration requestTimeout = const Duration(seconds: 5),
    Duration retryBaseDelay = const Duration(seconds: 30),
    int maxChunkedItems = MusicAssistantApi.defaultMaxChunkedItems,
    Duration chunkedResponseTimeout = MusicAssistantApi.defaultChunkedResponseTimeout,
    int maxConcurrentRequests = MusicAssistantApi.defaultMaxConcurrentRequests,
    bool autoReconnect = true,
  }) async {
    final channel = _FakeChannel();
    final client = MusicAssistantApi(
      channelFactory: channel.open,
      requestTimeout: requestTimeout,
      handshakeTimeout: const Duration(seconds: 2),
      retryBaseDelay: retryBaseDelay,
      maxChunkedItems: maxChunkedItems,
      chunkedResponseTimeout: chunkedResponseTimeout,
      maxConcurrentRequests: maxConcurrentRequests,
      autoReconnect: autoReconnect,
    );
    final connecting = client.connect(baseUrl ?? Uri.parse('http://127.0.0.1:8095'));
    // The greeting is unsolicited, so it can only be emitted once the client
    // has subscribed.
    await Future<void>.delayed(Duration.zero);
    channel.emit(_greeting);
    await connecting;
    channel.sent.clear();
    return _Harness(client, channel);
  }

  List<Map<String, dynamic>> get sentFrames => [
    for (final frame in channel.sent) jsonDecode(frame) as Map<String, dynamic>,
  ];

  List<String> get sentMessageIds => [for (final frame in sentFrames) frame['message_id'] as String];

  /// Lets queued microtasks and stream events settle.
  Future<void> pump() => Future<void>.delayed(Duration.zero);

  Future<void> dispose() async {
    await client.dispose();
    await channel.shutdown();
  }
}
