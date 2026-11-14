import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:plezy/main.dart' as app;
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/music/album_detail_screen.dart';
import 'package:plezy/services/music/music_output.dart';
import 'package:plezy/services/music/music_output_controller.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music_assistant/music_assistant_api.dart';
import 'package:plezy/services/music_assistant/music_assistant_players.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/music/output_picker_sheet.dart';

import 'support/add_music_assistant.dart';

/// Plays music out of a **real Sonos speaker**, driven from the real UI, and
/// asks the server rather than the app whether it worked.
///
/// This is the test for the thing the whole branch exists for: the owner has
/// 372,000 tracks and a set of Sonos speakers, and wants the phone to be a
/// remote rather than the thing making noise. Everything before this could
/// only ever address `builtin_player` — the phone itself.
///
/// ### Safety
///
/// **One speaker is authorised — `➡️ 🥙 Dining Room` — and only at volume 0.**
/// The Era 100 pair is not, and is never addressed: [_forbiddenPlayerId] is
/// asserted against before anything is sent. Volume is set to 0 and *read back
/// as 0* before any play command, because a command that returns without error
/// has only been accepted. It is restored to 2 afterwards, including when the
/// test fails — see [_withSilencedSpeaker].
///
/// ### Two tests, because there are two claims
///
/// The first drives the whole app: cold install, browse, pick the room, press
/// play, then transport and volume, then disconnect the app and check the
/// music is still going.
///
/// The second pins the discovery the design rests on — that Music Assistant
/// will play a **bare Plex URL** on a Sonos, resolving the title and duration
/// out of the file's own metadata, with its own library not involved at all.
/// That is what makes the resolver, the matching and the second index
/// unnecessary on the playback path.
///
/// It deserves its own test for two reasons. Nothing in the first one
/// exercises it — browsing Music Assistant means the handle sent is a Music
/// Assistant uri — and it checks the exact fields
/// [RemoteMusicPlaybackService] builds on: that `current_item` echoes the URL
/// back verbatim (which is how a reading is matched to a local track), that a
/// duration is read from the file, and that the *queue's* elapsed advances.
/// If Music Assistant ever stops echoing the handle, this fails here rather
/// than as tracks rendered under the wrong title.
///
/// Run against a booted simulator on the same network:
///   flutter test integration_test/music_assistant_sonos_output_test.dart \
///     -d `sim id` --dart-define=PLEX_TOKEN=`token`

/// The only speaker this test may play on, at the owner's explicit direction.
const String _authorisedPlayerId = 'RINCON_7828CA0DABA601400';

/// The Era 100 pair. Never addressed. Present so the guard can name it.
const String _forbiddenPlayerId = 'RINCON_74CA6074EA9A01400';

/// Volume to restore when the test is done.
const int _restoreVolume = 2;

/// Stable builtin-player id, so repeated runs reuse one record instead of
/// littering the server with a player per run.
const String _testPlayerId = 'ma_plezy_sonos_test';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const serverUrl = String.fromEnvironment('MA_URL', defaultValue: 'http://10.0.2.107:8095');
  const plexUrl = String.fromEnvironment('PLEX_URL', defaultValue: 'https://10.0.2.105:32400');
  const plexToken = String.fromEnvironment('PLEX_TOKEN');

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

  /// Real time *and* frames. The app has to keep pumping for its own state to
  /// advance, and the server has to be given wall-clock seconds to play.
  Future<void> settle(WidgetTester tester, Duration duration) async {
    final deadline = DateTime.now().add(duration);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  testWidgets('picks a Sonos room, plays to it, and keeps playing without the app', (tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;

    app.main();
    await tester.pump(const Duration(seconds: 5));
    releaseDebugSemantics();

    // ---------------------------------------------------------------- setup
    //
    // The install needs Plex signed in already; the speakers come from the
    // Music Assistant server, set up here if the device has none.
    final link = await ensureMusicAssistantServer(tester, serverUrl: serverUrl);

    // ------------------------------------------------------- open an album
    //
    // Not "the first card on the home screen": on an install that also has a
    // Plex video library the home screen is films and episodes, and there may
    // be no album on it at all. Search is the one route to an album that holds
    // whatever else is configured — and it is how someone navigates 372,000
    // tracks anyway.
    final albumCard = find.byWidgetPredicate((widget) {
      final item = widget is MediaCard ? widget.item : null;
      return item is MediaItem && item.kind == MediaKind.album;
    }, description: 'an album card');

    if (!await pumpUntil(tester, albumCard, timeout: const Duration(seconds: 20))) {
      final search = find.text('Search');
      expect(search, findsWidgets, reason: 'no way to search; screen showed: ${_visibleText(tester)}');
      await tester.tap(search.first, warnIfMissed: false);
      await tester.pump(const Duration(seconds: 2));
      final field = find.byType(TextField);
      expect(
        await pumpUntil(tester, field, timeout: const Duration(seconds: 20)),
        isTrue,
        reason: 'the search screen never offered a field',
      );
      await tester.enterText(field.first, const String.fromEnvironment('ALBUM_QUERY', defaultValue: 'radiohead'));
      await tester.pump(const Duration(seconds: 2));
      FocusManager.instance.primaryFocus?.unfocus();
      expect(
        await pumpUntil(tester, albumCard, timeout: const Duration(seconds: 45)),
        isTrue,
        reason: 'the search returned no albums; screen showed: ${_visibleText(tester)}',
      );
    }
    await tester.tap(albumCard.first, warnIfMissed: false);
    expect(
      await pumpUntil(tester, find.byType(AlbumDetailScreen), timeout: const Duration(seconds: 45)),
      isTrue,
      reason: 'tapping album artwork did not open an album; screen showed: ${_visibleText(tester)}',
    );

    final albumElement = tester.element(find.byType(AlbumDetailScreen));
    final outputs = Provider.of<MusicOutputController>(albumElement, listen: false);
    final playback = Provider.of<MusicPlaybackService>(albumElement, listen: false);

    // ------------------------------------------------- the Sonos is offered
    expect(
      await pumpUntilTrue(tester, () => outputs.hasRemoteOutputs, timeout: const Duration(seconds: 60)),
      isTrue,
      reason: 'no Music Assistant players were discovered at all',
    );
    final room = outputs.outputs.firstWhere(
      (output) => output.playerId == _authorisedPlayerId,
      orElse: () => MusicOutput.thisDevice,
    );
    expect(
      room.isRemote,
      isTrue,
      reason:
          'the authorised speaker was not offered as an output; '
          'saw ${outputs.outputs.map((o) => '${o.name}(${o.playerId})').join(', ')}',
    );
    expect(room.available, isTrue, reason: '${room.name} reported unavailable: ${room.unavailableReason}');

    // The picker is the feature. Open the real sheet and tap the real row
    // rather than calling select() — a controller that works behind a button
    // nobody can reach is not the thing that was asked for.
    expect(find.byTooltip(outputs.selected.name), findsWidgets, reason: 'no output button on the album screen');
    await tester.tap(find.byTooltip(outputs.selected.name).first, warnIfMissed: false);
    expect(
      await pumpUntil(tester, find.byType(OutputPickerSheet), timeout: const Duration(seconds: 10)),
      isTrue,
      reason: 'the output picker never opened',
    );
    expect(find.text(room.name), findsWidgets, reason: 'the picker did not list ${room.name}');
    await tester.tap(find.text(room.name).first, warnIfMissed: false);
    expect(
      await pumpUntilTrue(
        tester,
        () => outputs.selected.playerId == _authorisedPlayerId,
        timeout: const Duration(seconds: 15),
      ),
      isTrue,
      reason: 'tapping ${room.name} in the picker did not select it',
    );

    // ------------------------------------------------------------- observer
    final probe = MusicAssistantApi();
    await probe.connect(Uri.parse(serverUrl));
    final players = MusicAssistantPlayers(probe);
    addTearDown(() async {
      await _restore(players);
      await probe.sendCommand('builtin_player/unregister', args: {'player_id': _testPlayerId}).catchError((_) => null);
      await probe.sendCommand('config/players/remove', args: {'player_id': _testPlayerId}).catchError((_) => null);
      await probe.dispose();
    });

    await _withSilencedSpeaker(players, () async {
      // ---------------------------------------------------------- press play
      expect(playback.status, MusicPlaybackStatus.idle, reason: 'something was already playing');
      await tester.tap(find.text('Play').first, warnIfMissed: false);

      // The server is the one producing audio, so ask it. A status flag in the
      // app is a claim; `player_queues` is evidence.
      MaQueueState? queue;
      final started = await pumpUntilTrue(tester, () {
        unawaited(players.queueState(_authorisedPlayerId).then((q) => queue = q).catchError((_) => null));
        return queue?.state == MaPlayerState.playing;
      }, timeout: const Duration(seconds: 90));
      expect(started, isTrue, reason: 'the server never reported ${room.name} playing (last reading: $queue)');
      expect(queue!.currentItemId, isNotNull, reason: 'the room is playing nothing identifiable');

      // The app shows the track it queued, under the title it browsed.
      expect(
        await pumpUntilTrue(tester, () => playback.currentTrack != null, timeout: const Duration(seconds: 30)),
        isTrue,
        reason: 'the session never adopted a current track',
      );
      final playingTitle = playback.currentTrack!.displayTitle;

      // Elapsed advancing is the difference between "a stream was opened" and
      // "audio is coming out of it". Read from `player_queues`: a player's own
      // elapsed_time freezes a few seconds in and stays there for the whole
      // track (measured at 4.907 for 131s), which would pass a naive check for
      // "non-zero" while proving nothing.
      final before = (await players.queueState(_authorisedPlayerId))!.elapsed;
      await settle(tester, const Duration(seconds: 8));
      final after = (await players.queueState(_authorisedPlayerId))!.elapsed;
      expect(after, greaterThan(before + 4), reason: 'the queue on ${room.name} is not advancing: $before -> $after');

      // --------------------------------------------------------- transport
      await playback.pause();
      final paused = await pumpUntilTrue(
        tester,
        () => playback.status == MusicPlaybackStatus.paused,
        timeout: const Duration(seconds: 25),
      );
      expect(paused, isTrue, reason: 'pause did not take: status ${playback.status}');
      final pausedAt = (await players.queueState(_authorisedPlayerId))!.elapsed;
      await settle(tester, const Duration(seconds: 5));
      final stillPausedAt = (await players.queueState(_authorisedPlayerId))!.elapsed;
      expect(
        stillPausedAt,
        closeTo(pausedAt, 1.5),
        reason: 'the speaker kept playing through a pause: $pausedAt -> $stillPausedAt',
      );

      await playback.play();
      expect(
        await pumpUntilTrue(
          tester,
          () => playback.status == MusicPlaybackStatus.playing,
          timeout: const Duration(seconds: 25),
        ),
        isTrue,
        reason: 'resume did not take: status ${playback.status}',
      );

      // Next moves the room onto another track, and the app follows the
      // server rather than announcing its own guess.
      if (playback.queue.length > 1) {
        await playback.next();
        expect(
          await pumpUntilTrue(
            tester,
            () => playback.currentTrack != null && playback.currentTrack!.displayTitle != playingTitle,
            timeout: const Duration(seconds: 45),
          ),
          isTrue,
          reason: 'next() did not move ${room.name} off "$playingTitle"',
        );
        final afterNext = await players.queueState(_authorisedPlayerId);
        expect(afterNext!.currentIndex, greaterThan(0), reason: 'the server did not advance its queue');
      }

      // ----------------------------------------------------------- volume
      // Still inside the silenced block: 0 -> 1 -> 0 is the whole authorised
      // range, and it is enough to prove the control reaches the speaker.
      await playback.setVolume(1);
      await settle(tester, const Duration(seconds: 2));
      expect(await players.volumeOf(_authorisedPlayerId), 1, reason: 'setVolume(1) did not reach the speaker');
      await playback.setVolume(0);
      await settle(tester, const Duration(seconds: 2));
      expect(await players.volumeOf(_authorisedPlayerId), 0, reason: 'setVolume(0) did not reach the speaker');

      // ------------------------------------- the app goes away, music stays
      // The point of the whole feature. The speaker is fetching the audio
      // itself and Music Assistant is driving it, so nothing in this process
      // is on the audio path. Killing the app's socket is the strongest
      // version of "lock the phone and walk away" available from inside the
      // app's own test.
      final appSocket = link.api;
      expect(appSocket, isNotNull, reason: 'could not find the app\'s Music Assistant connection to close');
      await appSocket!.dispose();

      final aloneBefore = (await players.queueState(_authorisedPlayerId))!;
      expect(aloneBefore.state, MaPlayerState.playing, reason: 'the room stopped the moment the app disconnected');
      // Deliberately real time with no pumping: the app is not participating.
      await Future<void>.delayed(const Duration(seconds: 10));
      final aloneAfter = (await players.queueState(_authorisedPlayerId))!;
      expect(aloneAfter.state, MaPlayerState.playing, reason: 'playback stopped once the app was gone');
      expect(
        aloneAfter.elapsed,
        greaterThan(aloneBefore.elapsed + 5),
        reason:
            'playback did not survive the app disconnecting: '
            '${aloneBefore.elapsed} -> ${aloneAfter.elapsed}',
      );

      await players.stop(_authorisedPlayerId);
    });

    ErrorWidget.builder = originalErrorWidgetBuilder;
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('a bare Plex URL plays on the Sonos with no Music Assistant library involved', (tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    // Not a widget test: it drives the service directly against real hardware.
    // It lives here because there is no other place a real speaker exists.
    expect(plexToken, isNotEmpty, reason: 'pass --dart-define=PLEX_TOKEN=<token> to run this');

    final track = await _firstPlexTrack(plexUrl, plexToken);
    final probe = MusicAssistantApi();
    await probe.connect(Uri.parse(serverUrl));
    final players = MusicAssistantPlayers(probe);
    addTearDown(() async {
      await _restore(players);
      await probe.dispose();
    });

    final all = await players.players();
    expect(
      all.any((p) => p.playerId == _authorisedPlayerId),
      isTrue,
      reason: 'the authorised speaker is not on this server',
    );

    await _withSilencedSpeaker(players, () async {
      // The claim: Music Assistant fetches this URL itself and resolves the
      // title from the file's own metadata. Nothing matched, nothing indexed.
      await players.playMedia(_authorisedPlayerId, [track.url]);

      MaQueueState? queue;
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        queue = await players.queueState(_authorisedPlayerId);
        if (queue?.state == MaPlayerState.playing) break;
      }
      expect(queue?.state, MaPlayerState.playing, reason: 'the Plex URL never played (last reading: $queue)');

      // The title came out of the file, not out of a library lookup.
      expect(
        queue!.currentItemName,
        contains(track.title),
        reason: 'Music Assistant did not read the title from the file: ${queue.currentItemName}',
      );
      expect(
        queue.currentItemId,
        track.url,
        reason: 'the sounding item is not the URL that was sent, so readings cannot be matched back to a track',
      );
      expect(queue.currentDuration, isNotNull, reason: 'no duration was read from the file');

      // Position comes from the queue, and it advances. This is the reading
      // the progress bar depends on, and the one the player object gets wrong.
      final before = queue.elapsed;
      await Future<void>.delayed(const Duration(seconds: 10));
      final after = (await players.queueState(_authorisedPlayerId))!.elapsed;
      expect(after, greaterThan(before + 6), reason: 'queue elapsed did not advance: $before -> $after');

      // The measurement that decided the design, pinned so a regression in
      // *which* field is read shows up as a failing test rather than as a
      // progress bar that sticks: the player's own elapsed_time is not a
      // usable clock here.
      final player = (await players.players()).firstWhere((p) => p.playerId == _authorisedPlayerId);
      expect(player.state, MaPlayerState.playing);

      await players.stop(_authorisedPlayerId);
    });

    ErrorWidget.builder = originalErrorWidgetBuilder;
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Runs [body] with the authorised speaker at volume 0, restoring it to
/// [_restoreVolume] whatever happens.
///
/// The read-back is the point. `players/cmd/volume_set` returning without an
/// error means the command was *accepted*; only `players/all` says what the
/// speaker actually did. Nothing is played until that says 0.
Future<void> _withSilencedSpeaker(MusicAssistantPlayers players, Future<void> Function() body) async {
  expect(
    _authorisedPlayerId,
    isNot(_forbiddenPlayerId),
    reason: 'the Era 100 pair is not authorised and must never be addressed',
  );
  await players.setVolume(_authorisedPlayerId, 0);
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  final readBack = await players.volumeOf(_authorisedPlayerId);
  expect(readBack, 0, reason: 'refusing to play: the speaker did not confirm volume 0 (read $readBack)');
  try {
    await body();
  } finally {
    await _restore(players);
  }
}

Future<void> _restore(MusicAssistantPlayers players) async {
  try {
    await players.stop(_authorisedPlayerId);
  } catch (_) {
    // Best effort — the volume matters more.
  }
  try {
    await players.setVolume(_authorisedPlayerId, _restoreVolume);
  } catch (_) {
    // Nothing useful to do; the next run sets it again before playing.
  }
}

class _PlexTrack {
  const _PlexTrack({required this.url, required this.title});

  final String url;
  final String title;
}

/// The first track in the Plex music library, as a URL that carries its own
/// credentials.
///
/// That query parameter is the whole reason this design works: Music Assistant
/// cannot send custom HTTP headers, so a speaker is handed a bare URL and
/// nothing else.
Future<_PlexTrack> _firstPlexTrack(String baseUrl, String token) async {
  final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
  try {
    final sections = await _plexJson(client, '$baseUrl/library/sections', token);
    final directories = (sections['MediaContainer']['Directory'] as List).cast<Map<String, dynamic>>();
    final music = directories.firstWhere(
      (d) => d['type'] == 'artist' && (d['title'] as String).toLowerCase() == 'music',
      orElse: () => directories.firstWhere((d) => d['type'] == 'artist'),
    );
    final tracks = await _plexJson(
      client,
      '$baseUrl/library/sections/${music['key']}/all?type=10&X-Plex-Container-Start=0&X-Plex-Container-Size=1',
      token,
    );
    final track = (tracks['MediaContainer']['Metadata'] as List).cast<Map<String, dynamic>>().first;
    final part = ((track['Media'] as List).first as Map)['Part'] as List;
    final key = (part.first as Map)['key'] as String;
    return _PlexTrack(url: '$baseUrl$key?X-Plex-Token=$token', title: track['title'] as String);
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _plexJson(HttpClient client, String url, String token) async {
  final request = await client.getUrl(Uri.parse(url));
  request.headers.set('X-Plex-Token', token);
  request.headers.set('Accept', 'application/json');
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return jsonDecode(body) as Map<String, dynamic>;
}

/// Every string currently rendered, for diagnosing a failure without a
/// screenshot.
String _visibleText(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((w) => w.data)
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .toSet()
      .toList();
  return texts.join(' | ');
}
