import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:plezy/main.dart' as app;
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/music/music_output.dart';
import 'package:plezy/services/music/music_output_controller.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';

import 'support/add_music_assistant.dart';

const String _diningRoomPlayerId = 'RINCON_7828CA0DABA601400';
const String _forbiddenPlayerId = 'RINCON_74CA6074EA9A01400';
const String _serverUrl = String.fromEnvironment('MA_URL', defaultValue: 'http://10.0.2.107:8095');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the transport survives playing to a speaker', (tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;

    Future<bool> until(bool Function() predicate, {Duration timeout = const Duration(seconds: 60)}) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
        if (predicate()) return true;
      }
      return false;
    }

    app.main();
    await tester.pump(const Duration(seconds: 8));
    releaseDebugSemantics();

    await ensureMusicAssistantServer(tester, serverUrl: _serverUrl);

    // Below the providers, not above them: the session scopes them, and the
    // MaterialApp sits outside that scope. The nav is the most reliable thing
    // that is always inside it, whatever screen the app happens to open on.
    final navItem = find.text('Libraries');
    expect(
      await until(() => navItem.evaluate().isNotEmpty, timeout: const Duration(seconds: 120)),
      isTrue,
      reason: 'the app never reached its main navigation',
    );
    final context = tester.element(navItem.first);

    final serverManager = Provider.of<MultiServerProvider>(context, listen: false).serverManager;
    MediaServerClient? client;
    MediaLibrary? music;
    for (final id in serverManager.serverIds) {
      final candidate = serverManager.getClient(ServerId(id));
      if (candidate == null) continue;
      final libraries = await candidate.fetchLibraries();
      music = libraries.where((l) => l.kind == MediaKind.artist).firstOrNull;
      if (music != null) {
        client = candidate;
        break;
      }
    }
    expect(client, isNotNull, reason: 'no server has a music library; nothing to play from');

    // A queue, not a single track, and started from part-way in — which is
    // what tapping a track in an album does. The remote engine sends the first
    // handle and appends the rest afterwards, so a multi-track queue has a
    // window a one-track queue never opens.
    final page = await client!.fetchLibraryPagedContent(
      music!.id,
      query: const LibraryQuery(kind: MediaKind.track, limit: 12),
    );
    expect(page.items.length, greaterThan(1), reason: 'need a queue, not a single track');
    final tracks = page.items;
    final startTrack = tracks[1];

    final playback = Provider.of<MusicPlaybackService>(context, listen: false);
    final outputs = Provider.of<MusicOutputController?>(context, listen: false);
    expect(outputs, isNotNull, reason: 'no output controller in scope');

    // Play on the phone first, then move to the speaker. That is the reported
    // sequence — a song already going, a speaker chosen, another track tapped —
    // and switching output deliberately stops the outgoing engine, so the
    // session passes through "nothing playing" on the way.
    await playback.playFromList(
      tracks: tracks,
      startTrack: tracks.first,
      playContext: const MusicPlayContext(title: 'local first', kind: MusicPlayContextKind.album),
    );
    expect(
      await until(() => playback.status == MusicPlaybackStatus.playing, timeout: const Duration(seconds: 60)),
      isTrue,
      reason: 'local playback never started',
    );

    expect(
      await until(() => outputs!.outputs.any((o) => o.playerId == _diningRoomPlayerId)),
      isTrue,
      reason: 'the Dining Room speaker never appeared in the output list',
    );
    final dining = outputs!.outputs.firstWhere((o) => o.playerId == _diningRoomPlayerId);
    expect(dining.playerId, isNot(_forbiddenPlayerId));
    await outputs.select(dining);
    expect(outputs.selected.playerId, _diningRoomPlayerId);

    await playback.playFromList(
      tracks: tracks,
      startTrack: startTrack,
      playContext: const MusicPlayContext(title: 'transport check', kind: MusicPlayContextKind.album),
    );

    expect(
      await until(() => playback.currentTrack != null, timeout: const Duration(seconds: 90)),
      isTrue,
      reason:
          'audio was sent to the speaker but the session never had a current track, '
          'so the transport has nothing to render and there is no way to stop it',
    );

    // The reported symptom: it appears and then goes. Watch it rather than
    // glance at it, and say what the session looked like when it went.
    final gone = <String>[];
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(const ValueKey('mini_player_card')).evaluate().isEmpty) {
        gone.add(
          'transport gone after ~${(i + 1) * 500}ms: track=${playback.currentTrack?.title}, '
          'status=${playback.status}, queue=${playback.queue.length}, index=${playback.currentIndex}',
        );
        break;
      }
    }

    await playback.stop();
    await outputs.select(MusicOutput.thisDevice);
    ErrorWidget.builder = originalErrorWidgetBuilder;

    expect(gone, isEmpty, reason: gone.join());
  });
}
