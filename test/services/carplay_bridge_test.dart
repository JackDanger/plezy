import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/carplay_bridge.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

import '../test_helpers/media_items.dart';
import '../test_helpers/paged_fakes.dart';
import '../test_helpers/stub_music_playback_service.dart';

class _RecordingMusic extends StubMusicPlaybackService {
  List<MediaItem>? tracks;
  MediaItem? startTrack;
  bool? shuffledStart;
  MusicPlayContext? context;

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
    this.tracks = tracks;
    this.startTrack = startTrack;
    shuffledStart = shuffle;
    context = playContext;
  }
}

class _FakeClient implements MediaServerClient {
  _FakeClient({this.playlistTracks = const [], this.albumTracks = const [], this.libraryItems = const []});

  final List<MediaItem> playlistTracks;
  final List<MediaItem> albumTracks;
  final List<MediaItem> libraryItems;
  LibraryQuery? lastQuery;

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final all = playlistType == 'audio'
        ? [
            const MediaPlaylist(
              id: 'pl1',
              backend: MediaBackend.plex,
              title: 'Running',
              playlistType: 'audio',
              smart: false,
              leafCount: 3,
              thumbPath: '/playlists/pl1/thumb',
            ),
          ]
        : <MediaPlaylist>[];
    return fakeLibraryPage(all, start: start, size: size);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async =>
      fakeLibraryPage(playlistTracks, start: start, size: size);

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) async => albumTracks;

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => [
    const MediaLibrary(id: '3', backend: MediaBackend.plex, title: 'Music', kind: MediaKind.artist),
    const MediaLibrary(id: '1', backend: MediaBackend.plex, title: 'Movies', kind: MediaKind.movie),
  ];

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    expect(libraryId, '3', reason: 'only the music library is asked');
    lastQuery = query;
    return fakeLibraryPage(libraryItems.where((i) => i.kind == query.kind).toList());
  }

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) =>
      path == null ? '' : 'https://img$path?w=$width';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<MediaItem> _tracks(int n, String prefix) => [
  for (var i = 0; i < n; i++) testMediaItem(id: '$prefix$i', kind: MediaKind.track, title: 'Track $i', serverId: 'srv'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CarPlayBridge bridge(_FakeClient client, _RecordingMusic music) =>
      CarPlayBridge(clients: () => {'srv': client}, music: music, channel: const MethodChannel('carplay-test'));

  List<Map<String, Object?>> rows(Map<String, Object?> reply) => (reply['items']! as List).cast<Map<String, Object?>>();

  test('the tabs are playlists, artists and albums', () {
    final ids = bridge(_FakeClient(), _RecordingMusic()).tabs().map((t) => t['id']);
    expect(ids, ['playlists', 'artists', 'albums']);
  });

  test('a playlist row opens a list with shuffle first, then its tracks', () async {
    final client = _FakeClient(playlistTracks: _tracks(3, 'p'));
    final b = bridge(client, _RecordingMusic());

    final playlists = rows(await b.browse('playlists'));
    expect(playlists.single['title'], 'Running');
    expect(playlists.single['browsable'], isTrue);
    expect(playlists.single['image'], contains('/playlists/pl1/thumb'));

    final inside = rows(await b.browse(playlists.single['id']! as String));
    expect(inside.map((r) => r['title']), ['Shuffle', 'Track 0', 'Track 1', 'Track 2']);
    expect(inside.every((r) => r['playable'] == true), isTrue);
  });

  test('tapping a playlist track queues the playlist from that track', () async {
    final client = _FakeClient(playlistTracks: _tracks(3, 'p'));
    final music = _RecordingMusic();
    final b = bridge(client, music);
    final playlist = rows(await b.browse('playlists')).single['id']! as String;
    final trackRow = rows(await b.browse(playlist))[2];

    expect(await b.play(trackRow['id']! as String), isNull);

    expect(music.tracks!.map((t) => t.id), ['p0', 'p1', 'p2']);
    expect(music.startTrack!.id, 'p1');
    expect(music.shuffledStart, isFalse);
    expect(music.context!.title, 'Running');
    expect(music.context!.kind, MusicPlayContextKind.playlist);
  });

  test('shuffle plays the whole playlist shuffled', () async {
    final music = _RecordingMusic();
    final b = bridge(_FakeClient(playlistTracks: _tracks(3, 'p')), music);
    final playlist = rows(await b.browse('playlists')).single['id']! as String;
    final shuffle = rows(await b.browse(playlist)).first['id']! as String;

    expect(await b.play(shuffle), isNull);
    expect(music.shuffledStart, isTrue);
    expect(music.tracks!.length, 3);
  });

  test('albums lists the newest additions from the music library, and opens to tracks', () async {
    final album = testMediaItem(id: 'al1', kind: MediaKind.album, title: 'Discovery', serverId: 'srv');
    final client = _FakeClient(libraryItems: [album], albumTracks: _tracks(2, 'a'));
    final music = _RecordingMusic();
    final b = bridge(client, music);

    final albums = rows(await b.browse('albums'));
    expect(albums.single['title'], 'Discovery');
    expect(client.lastQuery!.sort!.field, 'addedAt');

    final tracks = rows(await b.browse(albums.single['id']! as String));
    expect(tracks.map((r) => r['title']), ['Track 0', 'Track 1']);
    await b.play(tracks.last['id']! as String);
    expect(music.startTrack!.id, 'a1');
    expect(music.context!.kind, MusicPlayContextKind.album);
  });

  test('a server that went offline says so instead of playing', () async {
    final music = _RecordingMusic();
    final client = _FakeClient(playlistTracks: _tracks(1, 'p'));
    final servers = <String, MediaServerClient>{'srv': client};
    final b = CarPlayBridge(clients: () => servers, music: music, channel: const MethodChannel('carplay-test'));
    final playlist = rows(await b.browse('playlists')).single['id']! as String;
    final track = rows(await b.browse(playlist)).last['id']! as String;

    servers.clear();
    expect(await b.play(track), 'This server is offline');
    expect(music.tracks, isNull);
  });

  test('titles with the separator in them survive the round trip', () async {
    final album = testMediaItem(id: 'al|1', kind: MediaKind.album, title: 'A|B', serverId: 'srv');
    final client = _FakeClient(libraryItems: [album], albumTracks: _tracks(1, 'a'));
    final music = _RecordingMusic();
    final b = bridge(client, music);
    final albumId = rows(await b.browse('albums')).single['id']! as String;
    final track = rows(await b.browse(albumId)).single['id']! as String;
    await b.play(track);
    expect(music.context!.title, 'A|B');
  });
}
