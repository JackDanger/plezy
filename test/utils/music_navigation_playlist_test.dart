import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:plezy/utils/music_navigation.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/paged_fakes.dart';
import '../test_helpers/stub_music_playback_service.dart';

/// Records what was played and appended, and remembers the play context the
/// way the real services do.
class _RecordingMusicService extends StubMusicPlaybackService {
  List<MediaItem> queued = [];
  MediaItem? startedAt;
  bool? shuffledStart;
  MusicPlayContext? _context;

  @override
  MusicPlayContext? get playContext => _context;

  @override
  Future<void> playFromList({
    required List<MediaItem> tracks,
    MediaItem? startTrack,
    required MusicPlayContext playContext,
    bool shuffle = false,
    Duration? initialPosition,
    bool offline = false,
    PlaybackLaunchObserver? launchObserver,
  }) async {
    await super.playFromList(tracks: tracks, startTrack: startTrack, playContext: playContext, shuffle: shuffle);
    queued = List.of(tracks);
    startedAt = startTrack;
    shuffledStart = shuffle;
    _context = playContext;
  }

  @override
  void addToEnd(List<MediaItem> tracks) => queued.addAll(tracks);
}

class _PlaylistClient implements MediaServerClient {
  _PlaylistClient(this.items);

  final List<MediaItem> items;
  final List<(int?, int?)> requests = [];

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async {
    requests.add((start, size));
    return fakeLibraryPage(items, start: start, size: size);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  Future<BuildContext> pump(WidgetTester tester, MusicPlaybackService service) async {
    late BuildContext captured;
    await tester.pumpWidget(
      ChangeNotifierProvider<MusicPlaybackService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  List<MediaItem> tracks(int n) => [
    for (var i = 0; i < n; i++) testMediaItem(id: 't$i', backend: MediaBackend.plex, kind: MediaKind.track),
  ];

  MediaPlaylist playlist(int count) => MediaPlaylist(
    id: 'pl',
    backend: MediaBackend.plex,
    title: 'Recently Added',
    playlistType: 'audio',
    smart: true,
    leafCount: count,
  );

  testWidgets('a short playlist is fetched whole and played', (tester) async {
    final all = tracks(250);
    final client = _PlaylistClient(all);
    final service = _RecordingMusicService();
    final context = await pump(tester, service);

    await playAudioPlaylist(context, client: client, playlist: playlist(250), startTrack: all[3]);

    expect(service.queued.map((t) => t.id), all.map((t) => t.id));
    expect(service.startedAt?.id, 't3');
  });

  testWidgets('a long playlist starts from what is loaded, then queues a window past the tapped track', (tester) async {
    final all = tracks(5000);
    final client = _PlaylistClient(all);
    final service = _RecordingMusicService();
    final context = await pump(tester, service);

    await playAudioPlaylist(
      context,
      client: client,
      playlist: playlist(5000),
      startTrack: all[150],
      loadedItems: all.sublist(0, 200),
    );

    expect(service.startedAt?.id, 't150');
    // Through the tapped track and the window after it, no further.
    expect(service.queued.length, 150 + 1 + largePlaylistQueueLength);
    expect(service.queued.last.id, 't${150 + largePlaylistQueueLength}');
    expect(service.queued.map((t) => t.id).toSet().length, service.queued.length, reason: 'no duplicates');
    // Nothing before the start of the queue was refetched.
    expect(client.requests.every((r) => (r.$1 ?? 0) >= 200), isTrue);
  });

  testWidgets('a long playlist stops filling once something else is playing', (tester) async {
    final all = tracks(5000);
    final client = _PlaylistClient(all);
    var appended = 0;
    final service = _HijackingMusicService(onFirstAppend: () => appended++);
    final context = await pump(tester, service);

    await playAudioPlaylist(
      context,
      client: client,
      playlist: playlist(5000),
      startTrack: all[0],
      loadedItems: all.sublist(0, 200),
    );

    expect(appended, 1);
    expect(service.queued.length, 400, reason: 'the 200 loaded plus the one page that landed before the switch');
    expect(client.requests.length, 1);
  });

  testWidgets('shuffling a long playlist draws random pages instead of fetching it all', (tester) async {
    final all = tracks(50000);
    final client = _PlaylistClient(all);
    final service = _RecordingMusicService();
    final context = await pump(tester, service);

    await playAudioPlaylist(context, client: client, playlist: playlist(50000), shuffle: true, random: Random(7));

    expect(service.shuffledStart, isTrue);
    expect(client.requests.length, lessThanOrEqualTo(5));
    expect(service.queued.length, greaterThan(100));
    expect(service.queued.length, lessThanOrEqualTo(500));
    expect(service.queued.map((t) => t.id).toSet().length, service.queued.length);
  });
}

/// Starts a different queue (a new session) right after the first append.
class _HijackingMusicService extends _RecordingMusicService {
  _HijackingMusicService({required this.onFirstAppend});

  final VoidCallback onFirstAppend;
  bool _hijacked = false;

  @override
  void addToEnd(List<MediaItem> tracks) {
    super.addToEnd(tracks);
    if (_hijacked) return;
    _hijacked = true;
    onFirstAppend();
    // What starting anything else does: a new session and a new context.
    _context = const MusicPlayContext(title: 'something else', kind: MusicPlayContextKind.album);
  }
}
