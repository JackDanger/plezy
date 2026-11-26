import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/services/carplay_bridge.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/paged_fakes.dart';
import '../test_helpers/stub_music_playback_service.dart';

class _RecordingMusic extends StubMusicPlaybackService {
  List<MediaItem>? tracks;
  MediaItem? startTrack;
  bool? shuffledStart;
  MusicPlayContext? context;
  MediaItem? radioSeed;
  int? jumpedTo;
  List<MediaItem> playingQueue = const [];
  int playingIndex = -1;
  bool shuffleOn = false;
  MusicRepeatMode repeat = MusicRepeatMode.off;

  @override
  List<MediaItem> get queue => playingQueue;

  @override
  int get currentIndex => playingIndex;

  @override
  MediaItem? get currentTrack => playingIndex < 0 ? null : playingQueue[playingIndex];

  @override
  bool get shuffled => shuffleOn;

  @override
  MusicRepeatMode get repeatMode => repeat;

  @override
  void setRepeatMode(MusicRepeatMode mode) {
    repeat = mode;
    notifyListeners();
  }

  @override
  Future<InstantMixOutcome> playInstantMix(MediaItem seed) async {
    radioSeed = seed;
    return InstantMixOutcome.started;
  }

  @override
  Future<void> jumpTo(int index) async => jumpedTo = index;

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
  _FakeClient({
    this.playlistTracks = const [],
    this.albumTracks = const [],
    this.libraryItems = const [],
    this.instantMix = false,
  });

  final List<MediaItem> playlistTracks;
  final List<MediaItem> albumTracks;
  final List<MediaItem> libraryItems;
  final bool instantMix;
  LibraryQuery? lastQuery;

  @override
  ServerCapabilities get capabilities => ServerCapabilities(instantMix: instantMix);

  @override
  Future<MediaItem?> fetchItem(String id) async => libraryItems.where((i) => i.id == id).firstOrNull;

  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) async =>
      libraryItems.where((i) => i.kind == MediaKind.album).toList();

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
    final items = libraryItems.where((i) => i.kind == query.kind).toList();
    if (query.sort?.field == 'lastViewedAt') {
      items.sort((a, b) => (b.lastViewedAt ?? 0).compareTo(a.lastViewedAt ?? 0));
    }
    return fakeLibraryPage(items.take(query.limit).toList());
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

  List<Map<String, Object?>> sections(Map<String, Object?> reply) =>
      (reply['sections']! as List).cast<Map<String, Object?>>();
  List<Map<String, Object?>> rows(Map<String, Object?> reply) => [
    for (final section in sections(reply)) ...(section['items']! as List).cast<Map<String, Object?>>(),
  ];

  test('the tabs are mixes, playlists, artists and albums', () {
    final ids = bridge(_FakeClient(), _RecordingMusic()).tabs().map((t) => t['id']);
    expect(ids, ['mixes', 'playlists', 'artists', 'albums']);
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
    expect(tracks.map((r) => r['title']), ['Shuffle', 'Track 0', 'Track 1']);
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
    final track = rows(await b.browse(albumId)).last['id']! as String;
    await b.play(track);
    expect(music.context!.title, 'A|B');
  });

  test('with no server connected, a list says so', () async {
    final b = CarPlayBridge(clients: () => {}, music: _RecordingMusic(), channel: const MethodChannel('carplay-test'));
    final reply = await b.browse('mixes');
    expect(sections(reply), isEmpty);
    expect(reply['emptyTitle'], 'Plezy is not connected to a server');
  });

  group('the Mixes tab', () {
    final played = testMediaItem(
      id: 'al-played',
      kind: MediaKind.album,
      title: 'Blue',
      serverId: 'srv',
      lastViewedAt: 200,
      thumbPath: '/blue',
    );
    final older = testMediaItem(
      id: 'al-older',
      kind: MediaKind.album,
      title: 'Court',
      serverId: 'srv',
      lastViewedAt: 100,
    );
    final unplayed = testMediaItem(id: 'al-new', kind: MediaKind.album, title: 'Hejira', serverId: 'srv');
    final artist = testMediaItem(id: 'ar1', kind: MediaKind.artist, title: 'Joni', serverId: 'srv', lastViewedAt: 300);

    test('leads with covers of what was played last, which play from the top', () async {
      final music = _RecordingMusic();
      final b = bridge(_FakeClient(libraryItems: [unplayed, older, played], albumTracks: _tracks(3, 'a')), music);

      final strip = sections(await b.browse('mixes')).first;
      final row = (strip['items']! as List).single as Map<String, Object?>;
      expect(row['type'], 'imageRow');
      expect(row['title'], 'Recently Played');
      final covers = (row['images']! as List).cast<Map<String, Object?>>();
      expect(covers.map((c) => c['title']), ['Blue', 'Court'], reason: 'unplayed albums stay out');
      expect(covers.first['image'], contains('/blue'));

      expect(await b.play(covers.first['id']! as String), isNull);
      expect(music.startTrack!.id, 'a0');
      expect(music.context!.title, 'Blue');

      final all = rows(await b.browse(row['id']! as String));
      expect(all.map((r) => r['title']), ['Blue', 'Court']);
      expect(all.every((r) => r['browsable'] == true), isTrue);
    });

    test('offers a radio station for artists played lately, where the server makes them', () async {
      final music = _RecordingMusic();
      final b = bridge(_FakeClient(libraryItems: [artist], instantMix: true), music);

      final radio = sections(await b.browse('mixes')).singleWhere((s) => s['header'] == 'Radio');
      final station = (radio['items']! as List).cast<Map<String, Object?>>().single;
      expect(station['title'], 'Joni Radio');

      expect(await b.play(station['id']! as String), isNull);
      expect(music.radioSeed!.id, 'ar1');

      final noRadio = bridge(_FakeClient(libraryItems: [artist]), _RecordingMusic());
      expect(sections(await noRadio.browse('mixes')).where((s) => s['header'] == 'Radio'), isEmpty);
    });

    group('on Plex', () {
      late AppDatabase db;
      setUp(() {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        PlexApiCache.initialize(db);
      });
      tearDown(() => db.close());

      final requests = <Uri>[];
      Map<String, Object?> container(Map<String, Object?> body) => {'MediaContainer': body};
      Map<String, Object?> track(int i) => {
        'ratingKey': 'mt$i',
        'key': '/library/metadata/mt$i',
        'type': 'track',
        'title': 'Mix track $i',
        'grandparentTitle': 'Joni',
      };

      Future<http.Response> plex(http.Request request) async {
        requests.add(request.url);
        final path = request.url.path;
        final q = request.url.queryParameters;
        final Map<String, Object?> body = switch (path) {
          '/library/sections' => container({
            'Directory': [
              {'key': '3', 'type': 'artist', 'title': 'Music'},
            ],
          }),
          '/hubs/sections/3' => container({
            'Hub': [
              {
                'hubIdentifier': 'music.mixes.3',
                'type': 'playlist',
                'Metadata': [
                  {
                    'type': 'playlist',
                    'title': 'Joni Mitchell Mix',
                    'key': '/library/sections/3/all?artist.id=7',
                    'Metadata': [
                      {'title': 'Joni Mitchell', 'thumb': '/joni', 'centroid': true},
                    ],
                  },
                ],
              },
            ],
          }),
          '/library/sections/3/all' when q.containsKey('artist.id') => container({
            'size': 2,
            'totalSize': 2,
            'Metadata': [track(0), track(1)],
          }),
          _ => container({'size': 0, 'Metadata': <Object>[]}),
        };
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      }

      test('lists Plex\'s mixes for you, and a tap plays the mix', () async {
        final client = testPlexClient(serverId: ServerId('srv'), handler: plex);
        addTearDown(client.close);
        final music = _RecordingMusic();
        final b = CarPlayBridge(
          clients: () => {'srv': client},
          music: music,
          channel: const MethodChannel('carplay-test'),
        );

        final tab = sections(await b.browse('mixes'));
        final mixes = (tab.singleWhere((s) => s['header'] == 'Mixes for You')['items']! as List)
            .cast<Map<String, Object?>>();
        expect(mixes.single['title'], 'Joni Mitchell Mix');
        expect(mixes.single.containsKey('subtitle'), isFalse, reason: 'the title already names the artist');
        expect(mixes.single['image'], contains('joni'));

        final radio = (tab.singleWhere((s) => s['header'] == 'Radio')['items']! as List).cast<Map<String, Object?>>();
        expect(radio.map((r) => r['title']).take(2), ['Library Radio', 'Shuffle Everything']);

        requests.clear();
        expect(await b.play(mixes.single['id']! as String), isNull);
        expect(music.tracks!.map((t) => t.title), ['Mix track 0', 'Mix track 1']);
        expect(music.context!.kind, MusicPlayContextKind.mix);
        expect(music.context!.title, 'Joni Mitchell Mix');
        expect(requests.single.queryParameters['artist.id'], '7');
      });
    });
  });

  test('an artist offers shuffle and radio above their albums', () async {
    final artist = testMediaItem(id: 'ar1', kind: MediaKind.artist, title: 'Joni', serverId: 'srv');
    final album = testMediaItem(id: 'al1', kind: MediaKind.album, title: 'Blue', serverId: 'srv');
    final b = bridge(_FakeClient(libraryItems: [artist, album], instantMix: true), _RecordingMusic());
    final artistId = rows(await b.browse('artists')).single['id']! as String;
    expect(rows(await b.browse(artistId)).map((r) => r['title']), ['Shuffle', 'Joni Radio', 'Blue']);
  });

  group('Now Playing', () {
    _RecordingMusic playing() => _RecordingMusic()
      ..playingQueue = [
        for (var i = 0; i < 4; i++)
          testMediaItem(
            id: 't$i',
            kind: MediaKind.track,
            title: 'Song $i',
            serverId: 'srv',
            grandparentId: 'ar1',
            grandparentTitle: 'Joni',
          ),
      ]
      ..playingIndex = 1;

    test('Up Next lists the queue from the playing track, and a tap jumps there', () async {
      final music = playing();
      final b = bridge(_FakeClient(), music);
      final upNext = rows(await b.browse('queue'));
      expect(upNext.map((r) => r['title']), ['Song 1', 'Song 2', 'Song 3']);
      expect(upNext.first['trackKey'], b.nowPlaying()['trackKey']);

      expect(await b.play(upNext[2]['id']! as String), isNull);
      expect(music.jumpedTo, 3);

      music.playingQueue = music.playingQueue.reversed.toList();
      expect(await b.play(upNext[2]['id']! as String), isNull, reason: 'found again after the queue moved');
      expect(music.jumpedTo, 0);
      music.playingQueue = const [];
      expect(await b.play(upNext[2]['id']! as String), 'That track has left the queue');
    });

    test('reports shuffle, repeat, and whether radio and the artist button apply', () {
      final music = playing()..shuffleOn = true;
      final state = bridge(_FakeClient(instantMix: true), music).nowPlaying();
      expect(state, {'trackKey': 'srv:t1', 'shuffled': true, 'repeat': 'off', 'radio': true, 'artist': true});
      expect(bridge(_FakeClient(), _RecordingMusic()).nowPlaying()['trackKey'], isNull);
    });

    test('tells the car when the session changes, once per change', () async {
      const channel = MethodChannel('carplay-notify-test');
      final sent = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        sent.add(call);
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
      );
      final music = playing();
      final b = CarPlayBridge(clients: () => {'srv': _FakeClient()}, music: music, channel: channel)..start();
      addTearDown(b.dispose);

      music.setRepeatMode(MusicRepeatMode.all);
      music.notifyListeners();
      final states = sent.where((c) => c.method == 'nowPlaying').map((c) => (c.arguments as Map)['repeat']);
      expect(states, ['off', 'all']);
      expect(sent.first.method, 'ready');
    });

    test('the repeat button goes off, all, one, and around again', () {
      expect(CarPlayBridge.nextRepeatMode(MusicRepeatMode.off), MusicRepeatMode.all);
      expect(CarPlayBridge.nextRepeatMode(MusicRepeatMode.all), MusicRepeatMode.one);
      expect(CarPlayBridge.nextRepeatMode(MusicRepeatMode.one), MusicRepeatMode.off);
    });

    test('the radio button starts a station from the playing song', () async {
      final music = playing();
      expect(await bridge(_FakeClient(instantMix: true), music).radioFromCurrent(), isNull);
      expect(music.radioSeed!.id, 't1');
      expect(await bridge(_FakeClient(), playing()).radioFromCurrent(), 'This server has no radio');
    });

    test('the artist button opens the playing song\'s artist', () {
      final artist = bridge(_FakeClient(), playing()).currentArtist()!;
      expect(artist['title'], 'Joni');
      expect(artist['id'], startsWith('artist|srv|ar1'));
    });
  });
}
