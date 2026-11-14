import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:plezy/main.dart' as app;
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/music/album_detail_screen.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/music/track_row.dart';

import 'support/add_music_assistant.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const serverUrl = String.fromEnvironment('MA_URL', defaultValue: 'http://10.0.2.107:8095');

  Future<bool> pumpUntilTrue(
    WidgetTester tester,
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (predicate()) return true;
    }
    return false;
  }

  Future<bool> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 60)}) =>
      pumpUntilTrue(tester, () => finder.evaluate().isNotEmpty, timeout: timeout);

  /// True when the transport button in the mini player is showing "pause",
  /// which is what it shows while audio is playing.
  bool showsPauseIcon(WidgetTester tester) => find.byIcon(Symbols.pause_rounded).evaluate().isNotEmpty;

  bool showsPlayIcon(WidgetTester tester) => find.byIcon(Symbols.play_arrow_rounded).evaluate().isNotEmpty;

  testWidgets('transport survives a track change and repeated pause/play', (tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;

    app.main();
    await tester.pump(const Duration(seconds: 5));
    releaseDebugSemantics();

    await ensureMusicAssistantServer(tester, serverUrl: serverUrl);

    final albumCard = find.byWidgetPredicate((widget) {
      final item = widget is MediaCard ? widget.item : null;
      return item is MediaItem && item.kind == MediaKind.album;
    }, description: 'an album card');
    expect(await pumpUntil(tester, albumCard, timeout: const Duration(seconds: 90)), isTrue);
    await tester.tap(albumCard.first, warnIfMissed: false);

    expect(await pumpUntil(tester, find.byType(AlbumDetailScreen), timeout: const Duration(seconds: 45)), isTrue);
    expect(await pumpUntil(tester, find.byType(TrackRow), timeout: const Duration(seconds: 45)), isTrue);

    final playback = Provider.of<MusicPlaybackService>(tester.element(find.byType(AlbumDetailScreen)), listen: false);

    // -------------------------------------------------- 1. play one track
    final rows = find.byType(TrackRow);
    expect(rows.evaluate().length, greaterThan(1), reason: 'need at least two tracks to test changing between them');

    await tester.tap(rows.first, warnIfMissed: false);
    expect(
      await pumpUntilTrue(tester, () => playback.status == MusicPlaybackStatus.playing),
      isTrue,
      reason: 'first track never started (status ${playback.status})',
    );
    final firstTrack = playback.currentTrack;
    expect(firstTrack, isNotNull);
    expect(showsPauseIcon(tester), isTrue, reason: 'playing, but the button does not offer pause');

    // ------------------------------------- 2. play a *different* track
    // The reported failure. Tapping another row while one plays has to replace
    // the current track, not be swallowed by the running session.
    await tester.tap(rows.at(1), warnIfMissed: false);
    expect(
      await pumpUntilTrue(
        tester,
        () => playback.currentTrack?.id != firstTrack!.id && playback.status == MusicPlaybackStatus.playing,
      ),
      isTrue,
      reason:
          'tapping a second track did not change tracks '
          '(still ${playback.currentTrack?.title}, status ${playback.status})',
    );
    expect(showsPauseIcon(tester), isTrue, reason: 'playing the second track, but the button does not offer pause');

    // --------------------------------- 3. pause / play / pause / play
    for (var cycle = 1; cycle <= 2; cycle++) {
      await tester.tap(find.byIcon(Symbols.pause_rounded).first, warnIfMissed: false);
      expect(
        await pumpUntilTrue(
          tester,
          () => playback.status == MusicPlaybackStatus.paused,
          timeout: const Duration(seconds: 20),
        ),
        isTrue,
        reason: 'cycle $cycle: pause did not pause (status ${playback.status})',
      );
      expect(
        await pumpUntilTrue(tester, () => showsPlayIcon(tester), timeout: const Duration(seconds: 10)),
        isTrue,
        reason: 'cycle $cycle: paused, but the button still shows pause',
      );

      await tester.tap(find.byIcon(Symbols.play_arrow_rounded).first, warnIfMissed: false);
      expect(
        await pumpUntilTrue(
          tester,
          () => playback.status == MusicPlaybackStatus.playing,
          timeout: const Duration(seconds: 20),
        ),
        isTrue,
        reason: 'cycle $cycle: play did not resume (status ${playback.status})',
      );
      expect(
        await pumpUntilTrue(tester, () => showsPauseIcon(tester), timeout: const Duration(seconds: 10)),
        isTrue,
        reason: 'cycle $cycle: playing, but the button still shows play',
      );
    }

    await playback.stop();
    await tester.pump(const Duration(seconds: 1));

    ErrorWidget.builder = originalErrorWidgetBuilder;
  });
}
