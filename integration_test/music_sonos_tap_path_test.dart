import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:plezy/main.dart' as app;
import 'package:plezy/services/music/music_output.dart';
import 'package:plezy/services/music/music_output_controller.dart';
import 'package:plezy/services/music/music_playback_service.dart';

import 'support/add_music_assistant.dart';
import 'support/ui_probe.dart';

const String _diningRoomPlayerId = 'RINCON_7828CA0DABA601400';
const String _forbiddenPlayerId = 'RINCON_74CA6074EA9A01400';
const String _serverUrl = String.fromEnvironment('MA_URL', defaultValue: 'http://10.0.2.107:8095');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a tapped track keeps its transport when it plays to a speaker', (tester) async {
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

    expect(
      await until(() => find.text('Libraries').evaluate().isNotEmpty, timeout: const Duration(seconds: 120)),
      isTrue,
      reason: 'never reached the main navigation; screen: ${visibleText(tester)}',
    );

    // ------------------------------------------------ choose the speaker
    final context = tester.element(find.text('Libraries').first);
    final playback = Provider.of<MusicPlaybackService>(context, listen: false);
    final outputs = Provider.of<MusicOutputController?>(context, listen: false);
    expect(outputs, isNotNull, reason: 'no output controller in scope');

    expect(
      await until(() => outputs!.outputs.any((o) => o.playerId == _diningRoomPlayerId)),
      isTrue,
      reason: 'the Dining Room speaker never appeared in the output list',
    );
    final dining = outputs!.outputs.firstWhere((o) => o.playerId == _diningRoomPlayerId);
    expect(dining.playerId, isNot(_forbiddenPlayerId));
    await outputs.select(dining);
    expect(outputs.selected.playerId, _diningRoomPlayerId);

    // --------------------------------------- navigate to something tappable
    await tester.tap(find.text('Libraries').first);
    await tester.pump(const Duration(seconds: 3));

    final maLibrary = find.textContaining('Music Assistant');
    expect(
      await until(() => maLibrary.evaluate().isNotEmpty),
      isTrue,
      reason: 'no Music Assistant library; screen: ${visibleText(tester)}',
    );
    await tester.tap(maLibrary.first, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 5));

    // A track card, tapped where it sits. That is the reported action —
    // "searched for a track, tapped it" — and it needs no navigation, which is
    // where every earlier attempt died guessing at finders.
    expect(
      await until(
        () => tappables(
          tester,
        ).any((t) => t.kind == 'track' && t.hittableIn(tester.view.physicalSize / tester.view.devicePixelRatio)),
      ),
      isTrue,
      reason: 'no hittable track card; tappables: ${describeTappables(tester)}',
    );

    // ------------------------------------------------------ tap a track
    final track = tappables(
      tester,
    ).firstWhere((t) => t.kind == 'track' && t.hittableIn(tester.view.physicalSize / tester.view.devicePixelRatio));
    await tapTarget(tester, track, what: 'a track');

    expect(
      await until(() => playback.currentTrack != null, timeout: const Duration(seconds: 90)),
      isTrue,
      reason: 'tapping a track sent audio to the speaker but the session never had a current track',
    );

    // The reported symptom: it shows and then goes, within about a second.
    final gone = <String>[];
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(const ValueKey('mini_player_card')).evaluate().isEmpty) {
        gone.add(
          'transport gone after ~${(i + 1) * 500}ms: track=${playback.currentTrack?.title}, '
          'status=${playback.status}, queue=${playback.queue.length}, '
          'output=${outputs.selected.name}, screen: ${visibleText(tester, limit: 12)}',
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
