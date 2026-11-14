import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:plezy/main.dart' as app;
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/music/album_detail_screen.dart';
import 'package:plezy/services/music/music_output.dart';
import 'package:plezy/services/music/music_output_controller.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/music/track_row.dart';

import 'support/add_music_assistant.dart';

class _Result {
  _Result(this.phase, this.ok, this.detail);
  final String phase;
  final bool ok;
  final String detail;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const serverUrl = String.fromEnvironment('MA_URL', defaultValue: 'http://10.0.2.107:8095');

  final results = <_Result>[];

  testWidgets('the player behaves under a full session', (tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;

    Future<bool> until(bool Function() predicate, {Duration timeout = const Duration(seconds: 30)}) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
        if (predicate()) return true;
      }
      return false;
    }

    Future<bool> untilFinder(Finder finder, {Duration timeout = const Duration(seconds: 30)}) =>
        until(() => finder.evaluate().isNotEmpty, timeout: timeout);

    /// Runs a phase, records the outcome, and never throws. A phase that blows
    /// up is a failure like any other and must not take the run with it.
    Future<void> phase(String name, Future<String?> Function() body) async {
      try {
        final failure = await body();
        results.add(_Result(name, failure == null, failure ?? 'ok'));
      } catch (e) {
        results.add(_Result(name, false, 'threw $e'));
      }
    }

    app.main();
    await tester.pump(const Duration(seconds: 5));
    releaseDebugSemantics();

    await ensureMusicAssistantServer(tester, serverUrl: serverUrl);

    final albumCard = find.byWidgetPredicate((widget) {
      final item = widget is MediaCard ? widget.item : null;
      return item is MediaItem && item.kind == MediaKind.album;
    }, description: 'an album card');
    if (!await untilFinder(albumCard, timeout: const Duration(seconds: 90))) {
      fail('no album ever appeared on the home screen — cannot exercise the player');
    }
    await tester.tap(albumCard.first, warnIfMissed: false);
    if (!await untilFinder(find.byType(AlbumDetailScreen), timeout: const Duration(seconds: 45))) {
      fail('tapping an album did not open it');
    }
    if (!await untilFinder(find.byType(TrackRow), timeout: const Duration(seconds: 45))) {
      fail('the album listed no tracks');
    }

    final element = tester.element(find.byType(AlbumDetailScreen));
    final playback = Provider.of<MusicPlaybackService>(element, listen: false);
    final outputs = Provider.of<MusicOutputController?>(element, listen: false);

    // ------------------------------------------------- output stays local
    await phase('output defaults to this device', () async {
      final selected = outputs?.selected;
      if (selected == null) return 'no output controller in scope';
      return selected.id == MusicOutput.thisDeviceId ? null : 'defaulted to ${selected.name}, not the phone';
    });

    // ------------------------------------------------------------ startup
    final rows = find.byType(TrackRow);
    final trackCount = rows.evaluate().length;

    await phase('a tapped track starts playing', () async {
      await tester.tap(rows.first, warnIfMissed: false);
      final started = await until(
        () => playback.status == MusicPlaybackStatus.playing,
        timeout: const Duration(seconds: 45),
      );
      if (!started) return 'never reached playing (status ${playback.status})';
      return playback.currentTrack == null ? 'playing but currentTrack is null' : null;
    });

    await phase('the whole album is queued, not just the track', () async {
      if (playback.queue.length < 2) return 'queue holds ${playback.queue.length} track(s)';
      return trackCount > 1 && playback.queue.length < trackCount
          ? 'queue holds ${playback.queue.length} of $trackCount listed tracks'
          : null;
    });

    await phase('position advances while playing', () async {
      final start = playback.position;
      final moved = await until(
        () => playback.position > start + const Duration(milliseconds: 700),
        timeout: const Duration(seconds: 20),
      );
      return moved ? null : 'position stuck at ${playback.position}';
    });

    await phase('the transport button offers pause while playing', () async {
      return find.byIcon(Symbols.pause_rounded).evaluate().isNotEmpty ? null : 'playing, but no pause icon on screen';
    });

    // ------------------------------------------------------ track changes
    await phase('tapping a different track changes track', () async {
      final before = playback.currentTrack?.id;
      await tester.tap(rows.at(1), warnIfMissed: false);
      final changed = await until(
        () => playback.currentTrack?.id != before && playback.status == MusicPlaybackStatus.playing,
        timeout: const Duration(seconds: 45),
      );
      return changed ? null : 'still on ${playback.currentTrack?.title} (status ${playback.status})';
    });

    await phase('next moves forward', () async {
      final before = playback.currentTrack?.id;
      final beforeIndex = playback.currentIndex;
      await playback.next();
      final changed = await until(() => playback.currentTrack?.id != before);
      if (!changed) return 'next did not change track (index still $beforeIndex)';
      return playback.currentIndex > beforeIndex ? null : 'index went $beforeIndex -> ${playback.currentIndex}';
    });

    await phase('previous moves back', () async {
      final beforeIndex = playback.currentIndex;
      if (beforeIndex == 0) return 'skipped: already at the head of the queue';
      // Past three seconds `previous` restarts the track rather than stepping
      // back, which is what every player does. Seek to the top and wait for
      // the position to actually report it: in flow mode the seek is served by
      // re-cutting the stream, so sampling too early sees the old position and
      // the call restarts instead of moving.
      await playback.seek(Duration.zero);
      if (!await until(() => playback.position < const Duration(seconds: 3), timeout: const Duration(seconds: 20))) {
        return 'position never fell below the restart threshold (${playback.position})';
      }
      await playback.previous();
      final moved = await until(() => playback.currentIndex < beforeIndex);
      return moved ? null : 'index stayed at ${playback.currentIndex}';
    });

    await phase('jumpTo lands on the requested index', () async {
      if (playback.queue.length < 3) return 'skipped: queue too short';
      await playback.jumpTo(2);
      final landed = await until(() => playback.currentIndex == 2);
      return landed ? null : 'asked for index 2, sat at ${playback.currentIndex}';
    });

    // -------------------------------------------------------------- seek
    await phase('seek moves the position and keeps playing', () async {
      final duration = playback.duration;
      if (duration == null || duration < const Duration(seconds: 30)) return 'skipped: no usable duration';
      final target = duration ~/ 2;
      await playback.seek(target);
      final arrived = await until(() => (playback.position - target).abs() < const Duration(seconds: 5));
      if (!arrived) return 'asked for $target, sat at ${playback.position}';
      final stillPlaying = await until(
        () => playback.status == MusicPlaybackStatus.playing,
        timeout: const Duration(seconds: 15),
      );
      return stillPlaying ? null : 'seek left the session in ${playback.status}';
    });

    // ------------------------------------------------- pause/play cycling
    await phase('pause and play cycle five times without drifting', () async {
      for (var i = 1; i <= 5; i++) {
        await playback.pause();
        if (!await until(() => playback.status == MusicPlaybackStatus.paused, timeout: const Duration(seconds: 15))) {
          return 'cycle $i: pause left status ${playback.status}';
        }
        if (!await until(
          () => find.byIcon(Symbols.play_arrow_rounded).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 8),
        )) {
          return 'cycle $i: paused but the button still shows pause';
        }
        await playback.play();
        if (!await until(() => playback.status == MusicPlaybackStatus.playing, timeout: const Duration(seconds: 15))) {
          return 'cycle $i: play left status ${playback.status}';
        }
        if (!await until(
          () => find.byIcon(Symbols.pause_rounded).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 8),
        )) {
          return 'cycle $i: playing but the button still shows play';
        }
      }
      return null;
    });

    await phase('position does not advance while paused', () async {
      await playback.pause();
      if (!await until(() => playback.status == MusicPlaybackStatus.paused, timeout: const Duration(seconds: 15))) {
        return 'could not pause (status ${playback.status})';
      }
      final at = playback.position;
      await tester.pump(const Duration(milliseconds: 200));
      final held = await until(() => false, timeout: const Duration(seconds: 3));
      if (held) return 'unreachable';
      final drift = (playback.position - at).abs();
      if (drift > const Duration(seconds: 1)) return 'position moved $drift while paused';
      await playback.play();
      await until(() => playback.status == MusicPlaybackStatus.playing, timeout: const Duration(seconds: 15));
      return null;
    });

    // --------------------------------------------------- rapid input
    await phase('rapid toggling settles in a consistent state', () async {
      for (var i = 0; i < 10; i++) {
        unawaitedToggle(playback);
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(const Duration(seconds: 3));
      final settled = await until(
        () => playback.status == MusicPlaybackStatus.playing || playback.status == MusicPlaybackStatus.paused,
        timeout: const Duration(seconds: 20),
      );
      if (!settled) return 'left in ${playback.status} after rapid toggling';
      final playing = playback.status == MusicPlaybackStatus.playing;
      final iconSaysPlaying = find.byIcon(Symbols.pause_rounded).evaluate().isNotEmpty;
      return playing == iconSaysPlaying
          ? null
          : 'status $playing but icon says ${iconSaysPlaying ? 'playing' : 'paused'}';
    });

    await phase('rapid next taps do not wedge the queue', () async {
      await playback.play();
      await until(() => playback.status == MusicPlaybackStatus.playing, timeout: const Duration(seconds: 15));
      for (var i = 0; i < 4; i++) {
        unawaitedNext(playback);
        await tester.pump(const Duration(milliseconds: 120));
      }
      final recovered = await until(
        () => playback.currentTrack != null && playback.status != MusicPlaybackStatus.error,
        timeout: const Duration(seconds: 30),
      );
      return recovered ? null : 'ended on ${playback.currentTrack?.title} in ${playback.status}';
    });

    // ----------------------------------------------------- queue editing
    await phase('addNext inserts after the current track', () async {
      // Paused first. The insert point is the cursor *at the moment of the
      // edit*, and a running session can advance it during the pump — which
      // made the earlier version of this fail against correct behaviour.
      await playback.pause();
      if (!await until(() => playback.status == MusicPlaybackStatus.paused, timeout: const Duration(seconds: 15))) {
        return 'could not pause to edit the queue (status ${playback.status})';
      }
      final queue = playback.queue;
      if (queue.length < 3) return 'skipped: queue too short';
      final candidate = queue.last;
      final lengthBefore = queue.length;
      final insertedAt = playback.currentIndex + 1;
      playback.addNext([candidate]);
      await tester.pump(const Duration(milliseconds: 600));
      if (playback.queue.length != lengthBefore + 1) {
        return 'queue went $lengthBefore -> ${playback.queue.length}';
      }
      if (playback.currentIndex + 1 != insertedAt) return 'the cursor moved while paused';
      return playback.queue[insertedAt].id == candidate.id
          ? null
          : 'inserted ${playback.queue[insertedAt].title}, not ${candidate.title}';
    });

    await phase('addToEnd appends', () async {
      final queue = playback.queue;
      if (queue.isEmpty) return 'skipped: empty queue';
      final candidate = queue.first;
      final lengthBefore = queue.length;
      playback.addToEnd([candidate]);
      await tester.pump(const Duration(milliseconds: 600));
      if (playback.queue.length != lengthBefore + 1) {
        return 'queue went $lengthBefore -> ${playback.queue.length}';
      }
      return playback.queue.last.id == candidate.id ? null : 'last is ${playback.queue.last.title}';
    });

    await phase('removeAt drops the right entry without moving the current track', () async {
      if (playback.queue.length < 3) return 'skipped: queue too short';
      final current = playback.currentTrack?.id;
      final removeIndex = playback.queue.length - 1;
      final removed = playback.queue[removeIndex];
      final lengthBefore = playback.queue.length;
      playback.removeAt(removeIndex);
      await tester.pump(const Duration(milliseconds: 600));
      if (playback.queue.length != lengthBefore - 1) {
        return 'queue went $lengthBefore -> ${playback.queue.length}';
      }
      if (playback.currentTrack?.id != current) return 'removing an upcoming track changed the current one';
      return playback.queue.length > removeIndex && playback.queue[removeIndex].id == removed.id
          ? 'the entry is still there'
          : null;
    });

    await phase('playback resumes after the queue edits', () async {
      await playback.play();
      final resumed = await until(
        () => playback.status == MusicPlaybackStatus.playing,
        timeout: const Duration(seconds: 20),
      );
      return resumed ? null : 'did not resume (status ${playback.status})';
    });

    await phase('clearUpcoming leaves the current track playing', () async {
      final current = playback.currentTrack?.id;
      playback.clearUpcoming();
      await tester.pump(const Duration(seconds: 1));
      if (playback.currentTrack?.id != current) return 'the current track changed';
      return playback.status == MusicPlaybackStatus.error ? 'session errored' : null;
    });

    // ------------------------------------------------- shuffle & repeat
    await phase('repeat mode round-trips', () async {
      final original = playback.repeatMode;
      for (final mode in MusicRepeatMode.values) {
        playback.setRepeatMode(mode);
        await tester.pump(const Duration(milliseconds: 300));
        if (playback.repeatMode != mode) return 'asked for $mode, got ${playback.repeatMode}';
      }
      playback.setRepeatMode(original);
      return null;
    });

    await phase('shuffle toggles and keeps the current track', () async {
      final current = playback.currentTrack?.id;
      final before = playback.shuffled;
      playback.toggleShuffle();
      await tester.pump(const Duration(seconds: 1));
      if (playback.shuffled == before) return 'shuffle did not toggle';
      if (playback.currentTrack?.id != current) return 'shuffling changed the playing track';
      playback.toggleShuffle();
      await tester.pump(const Duration(seconds: 1));
      return playback.shuffled == before ? null : 'shuffle did not toggle back';
    });

    // -------------------------------------------------------------- stop
    await phase('stop ends the session', () async {
      await playback.stop();
      final stopped = await until(
        () => playback.status == MusicPlaybackStatus.idle || playback.currentTrack == null,
        timeout: const Duration(seconds: 20),
      );
      return stopped ? null : 'after stop: status ${playback.status}, track ${playback.currentTrack?.title}';
    });

    ErrorWidget.builder = originalErrorWidgetBuilder;

    // ------------------------------------------------------------ report
    final failures = results.where((r) => !r.ok).toList();
    final report = StringBuffer('\n=== player report ===\n');
    for (final r in results) {
      report.writeln('${r.ok ? "PASS" : "FAIL"}  ${r.phase}${r.ok ? '' : ' — ${r.detail}'}');
    }
    report.writeln('${results.length - failures.length}/${results.length} passed');
    debugPrint(report.toString());

    expect(failures, isEmpty, reason: report.toString());
  });
}

void unawaitedToggle(MusicPlaybackService playback) {
  playback.togglePlayPause().catchError((_) {});
}

void unawaitedNext(MusicPlaybackService playback) {
  playback.next().catchError((_) {});
}
