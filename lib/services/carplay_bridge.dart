import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals, visibleForTesting;
import 'package:flutter/services.dart';

import '../media/library_query.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_playlist.dart';
import '../media/media_server_client.dart';
import '../utils/app_logger.dart';
import 'music/music_playback_service.dart';
import 'plex_client.dart';

/// Answers CarPlay: what to list on each screen, what to play when a row is
/// tapped, and what the Now Playing buttons do.
///
/// The CarPlay screens are native templates (`CarPlaySceneDelegate.swift`);
/// they know nothing of servers. Each row carries an opaque id that this
/// bridge made, and the native side hands it back to browse into it or play
/// it. Playback goes through the same [MusicPlaybackService] as the phone, so
/// the car's Now Playing screen, the lock screen and the app agree.
///
/// A list comes back as `{sections: [{header?, items: [row…]}], emptyTitle?}`.
/// A row is `{id, title, subtitle?, image?, systemImage?, browsable?,
/// playable?, trackKey?}`, or an image row: `{type: imageRow, id?, title,
/// images: [{id, image?, title, subtitle?}]}`, a strip of covers each played by a tap.
///
/// The bridge also tells the car what is playing (`nowPlaying`), so a list
/// can mark the playing track and the shuffle and repeat buttons show their
/// state.
class CarPlayBridge {
  /// Private-named formal: callers pass `clients:` and `music:`.
  CarPlayBridge({required this._clients, required this._music, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.plezy/carplay';

  /// Rows per list. Cars cap a list well below this (the native side trims
  /// to the car's own limit), and a long list is no use while driving.
  static const int listLimit = 100;

  /// Tracks queued when one in a playlist is tapped, and the most a
  /// playlist's shuffle draws from.
  static const int playlistQueueLimit = 500;

  /// Covers in the Mixes tab's "Recently played" strip.
  static const int recentAlbumCount = 8;

  /// Artists offered a radio station on the Mixes tab.
  static const int artistStationCount = 5;

  static const String _mixes = 'mixes';
  static const String _playlists = 'playlists';
  static const String _recentArtists = 'artists';
  static const String _recentAlbums = 'albums';
  static const String _recentlyPlayed = 'recent';
  static const String _upNext = 'queue';

  final Map<String, MediaServerClient> Function() _clients;
  final MusicPlaybackService _music;
  final MethodChannel _channel;
  Map<String, Object?>? _sentNowPlaying;

  void start() {
    _channel.setMethodCallHandler(_handle);
    _music.addListener(_sendNowPlaying);
    // CarPlay may already be up, showing "open Plezy": it can load now.
    unawaited(
      _channel.invokeMethod<void>('ready').catchError((Object e) {
        appLogger.d('CarPlay ready signal not delivered: $e');
      }),
    );
    _sendNowPlaying();
  }

  void dispose() {
    _music.removeListener(_sendNowPlaying);
    _channel.setMethodCallHandler(null);
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'tabs':
        return tabs();
      case 'browse':
        return browse(args['id']?.toString() ?? '');
      case 'play':
        return play(args['id']?.toString() ?? '');
      case 'nowPlaying':
        return nowPlaying();
      case 'toggleShuffle':
        _music.toggleShuffle();
        return null;
      case 'cycleRepeat':
        _music.setRepeatMode(nextRepeatMode(_music.repeatMode));
        return null;
      case 'radio':
        return radioFromCurrent();
      case 'currentArtist':
        return currentArtist();
      default:
        throw MissingPluginException(call.method);
    }
  }

  /// The tab bar. `systemImage` is an SF Symbol name.
  List<Map<String, String>> tabs() => const [
    {'id': _mixes, 'title': 'Mixes', 'systemImage': 'sparkles'},
    {'id': _playlists, 'title': 'Playlists', 'systemImage': 'music.note.list'},
    {'id': _recentArtists, 'title': 'Artists', 'systemImage': 'music.mic'},
    {'id': _recentAlbums, 'title': 'Albums', 'systemImage': 'square.stack'},
  ];

  /// The rows under [id]: a tab, a playlist, an artist, an album or Up Next.
  Future<Map<String, Object?>> browse(String id) async {
    final node = _Node.parse(id);
    if (_clients().isEmpty && node.kind != _upNext) {
      return {'sections': const <Object>[], 'emptyTitle': 'Plezy is not connected to a server'};
    }
    switch (node.kind) {
      case _mixes:
        return _mixesTab();
      case _upNext:
        return _list(_upNextRows(), empty: 'Nothing is queued');
      case _playlists:
        return _list(await _playlistRows(), empty: 'No music playlists');
      case _recentArtists:
        return _list(await _libraryRows(MediaKind.artist, sort: 'lastViewedAt'), empty: 'No artists');
      case _recentAlbums:
        return _list(await _libraryRows(MediaKind.album, sort: 'addedAt'), empty: 'No albums');
      case _recentlyPlayed:
        return _list(await _recentAlbumItems(listLimit).then(_itemRowsOf), empty: 'Nothing played yet');
      case 'playlist':
        return _list(await _playlistTrackRows(node), empty: 'This playlist is empty');
      case 'artist':
        return _list(await _artistRows(node), empty: 'No albums by this artist');
      case 'album':
        return _list(await _albumTrackRows(node), empty: 'This album has no tracks');
      default:
        throw ArgumentError.value(id, 'id', 'not a CarPlay list');
    }
  }

  static Map<String, Object?> _list(List<Map<String, Object?>> items, {required String empty}) => {
    'sections': [
      if (items.isNotEmpty) {'items': items},
    ],
    'emptyTitle': empty,
  };

  /// Start what [id] names. Returns null once playing, or a reason to show.
  Future<String?> play(String id) async {
    final node = _Node.parse(id);
    if (node.kind == 'qtrack') return _jumpInQueue(node);
    final client = _client(node);
    if (client == null) return 'This server is offline';
    final intent = _music.beginPlayIntent();
    final title = node.title ?? '';
    try {
      switch (node.kind) {
        case 'ptrack':
          final tracks = await _playlistTracks(client, node.itemId, playlistQueueLimit);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          final at = node.position ?? 0;
          if (at >= tracks.length) return 'That track is no longer in the playlist';
          await _playList(tracks, start: tracks[at], title: title, kind: MusicPlayContextKind.playlist);
        case 'pshuffle':
          final tracks = await _playlistTracks(client, node.itemId, playlistQueueLimit);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (tracks.isEmpty) return 'This playlist is empty';
          await _playList(tracks, shuffle: true, title: title, kind: MusicPlayContextKind.playlist);
        case 'atrack':
          final tracks = await client.fetchAlbumTracks(node.itemId);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          final at = node.position ?? 0;
          if (at >= tracks.length) return 'That track is no longer on the album';
          await _playList(tracks, start: tracks[at], title: title, kind: MusicPlayContextKind.album);
        case 'alshuffle':
          final tracks = await client.fetchAlbumTracks(node.itemId);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (tracks.isEmpty) return 'This album has no tracks';
          await _playList(tracks, shuffle: true, title: title, kind: MusicPlayContextKind.album);
        case 'ashuffle':
          final tracks = await client.fetchPlayableDescendants(node.itemId);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (tracks.isEmpty) return 'Nothing to play by this artist';
          await _playList(tracks, shuffle: true, title: title, kind: MusicPlayContextKind.artist);
        case 'radio':
          final seed = await client.fetchItem(node.itemId);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (seed == null) return 'That is no longer on the server';
          return await _startRadio(seed);
        case 'mix':
          if (client is! PlexClient) return 'This cannot be played';
          final mix = PlexMixForYou(title: title, key: node.itemId, librarySectionID: _sectionOf(node.itemId));
          final tracks = await client.fetchMixTracks(mix);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (tracks.isEmpty) return 'This mix is empty right now';
          await _playList(tracks, title: title, kind: MusicPlayContextKind.mix);
        case 'lradio' || 'lshuffle':
          if (client is! PlexClient) return 'This cannot be played';
          final radio = node.kind == 'lradio';
          final tracks = radio
              ? await client.fetchLibraryRadio(node.itemId, viewKind: MediaKind.artist)
              : await client.fetchLibraryShuffle(node.itemId, viewKind: MediaKind.artist);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (tracks.isEmpty) return 'This library has no tracks';
          await _playList(tracks, title: title, kind: radio ? MusicPlayContextKind.mix : MusicPlayContextKind.tracks);
        default:
          return 'This cannot be played';
      }
    } catch (e, st) {
      appLogger.w('CarPlay could not play $id', error: e, stackTrace: st);
      return 'Could not start playback';
    }
    return null;
  }

  Future<void> _playList(
    List<MediaItem> tracks, {
    MediaItem? start,
    bool shuffle = false,
    required String title,
    required MusicPlayContextKind kind,
  }) => _music.playFromList(
    tracks: tracks,
    startTrack: start,
    shuffle: shuffle,
    playContext: MusicPlayContext(title: title, kind: kind),
  );

  Future<String?> _startRadio(MediaItem seed) async {
    try {
      return switch (await _music.playInstantMix(seed)) {
        InstantMixOutcome.empty => 'Plex has no radio for this yet',
        InstantMixOutcome.started || InstantMixOutcome.superseded => null,
      };
    } catch (e, st) {
      appLogger.w('CarPlay could not start radio from ${seed.id}', error: e, stackTrace: st);
      return 'Could not start the radio';
    }
  }

  /// The Now Playing screen's radio button: a station seeded by the song.
  Future<String?> radioFromCurrent() async {
    final track = _music.currentTrack;
    if (track == null) return 'Nothing is playing';
    final client = _clients()[track.serverId];
    if (client == null) return 'This server is offline';
    if (!client.capabilities.instantMix) return 'This server has no radio';
    return _startRadio(track);
  }

  /// The artist of the playing track, for the Now Playing artist button:
  /// `{id, title}`, or null when there is none to show.
  Map<String, String>? currentArtist() {
    final track = _music.currentTrack;
    final serverId = track?.serverId;
    final artistId = track?.grandparentId;
    if (track == null || serverId == null || artistId == null || !_clients().containsKey(serverId)) return null;
    final name = track.grandparentTitle ?? track.albumArtistTitle ?? '';
    return {'id': _Node.make('artist', serverId, artistId, title: name), 'title': name};
  }

  Future<String?> _jumpInQueue(_Node node) async {
    final queue = _music.queue;
    var at = node.position ?? -1;
    if (at < 0 || at >= queue.length || queue[at].id != node.itemId) {
      at = queue.indexWhere((t) => t.id == node.itemId && t.serverId == node.serverId);
    }
    if (at < 0) return 'That track has left the queue';
    await _music.jumpTo(at);
    return null;
  }

  /// What the car shows of the playing session. Sent on every change, and
  /// asked for when the car connects.
  Map<String, Object?> nowPlaying() {
    final track = _music.currentTrack;
    return {
      'trackKey': track == null ? null : trackKey(track),
      'shuffled': _music.shuffled,
      'repeat': _music.repeatMode.name,
      'radio': track != null && (_clients()[track.serverId]?.capabilities.instantMix ?? false),
      'artist': track?.grandparentId != null,
    };
  }

  void _sendNowPlaying() {
    final state = nowPlaying();
    if (mapEquals(state, _sentNowPlaying)) return;
    _sentNowPlaying = state;
    unawaited(_channel.invokeMethod<void>('nowPlaying', state).catchError((Object _) {}));
  }

  /// A track's identity across lists, for marking the one playing.
  @visibleForTesting
  static String trackKey(MediaItem track) => '${track.serverId}:${track.id}';

  @visibleForTesting
  static MusicRepeatMode nextRepeatMode(MusicRepeatMode mode) => switch (mode) {
    MusicRepeatMode.off => MusicRepeatMode.all,
    MusicRepeatMode.all => MusicRepeatMode.one,
    MusicRepeatMode.one => MusicRepeatMode.off,
  };

  MediaServerClient? _client(_Node node) => node.serverId == null ? null : _clients()[node.serverId];

  // MARK: - The Mixes tab

  /// Recently played covers, Plex's mixes for you, then radio: the library's,
  /// and stations for the artists played last.
  Future<Map<String, Object?>> _mixesTab() async {
    final libraries = await _musicLibraries();
    // Each server request on its own: the car is waiting on all of them.
    final recentFuture = _recentAlbumItems(recentAlbumCount, libraries);
    final stationsFuture = _artistStations(libraries);
    final mixesFuture = Future.wait([
      for (final (serverId, client, library) in libraries)
        if (client is PlexClient)
          client.fetchMixesForYou(library.id).catchError((Object e) {
            appLogger.w('CarPlay: no mixes from $serverId', error: e);
            return const <PlexMixForYou>[];
          })
        else
          Future.value(const <PlexMixForYou>[]),
    ]);
    final mixesByLibrary = await mixesFuture;
    final recent = await recentFuture;
    final stations = await stationsFuture;

    final mixes = <Map<String, Object?>>[];
    final radio = <Map<String, Object?>>[];
    final several = libraries.length > 1;
    for (final (i, (serverId, client, library)) in libraries.indexed) {
      if (client is! PlexClient) continue;
      for (final mix in mixesByLibrary[i]) {
        mixes.add({
          'id': _Node.make('mix', serverId, mix.key, title: mix.title),
          'title': mix.title,
          if (mix.artistTitle case final artist? when !mix.title.contains(artist)) 'subtitle': 'Around $artist',
          'image': _image(client, mix.thumb),
          'systemImage': 'sparkles',
          'playable': true,
        });
      }
      final suffix = several ? ' · ${library.title}' : '';
      radio
        ..add({
          'id': _Node.make('lradio', serverId, library.id, title: '${library.title} Radio'),
          'title': 'Library Radio$suffix',
          'subtitle': 'Favorites from across the library',
          'systemImage': 'dot.radiowaves.left.and.right',
          'playable': true,
        })
        ..add({
          'id': _Node.make('lshuffle', serverId, library.id, title: library.title),
          'title': 'Shuffle Everything$suffix',
          'systemImage': 'shuffle',
          'playable': true,
        });
    }
    radio.addAll(stations);
    return {
      'sections': [
        if (recent.isNotEmpty)
          {
            'items': [
              {
                'type': 'imageRow',
                'id': _recentlyPlayed,
                'title': 'Recently Played',
                'images': [
                  for (final (serverId, client, album) in recent)
                    {
                      'id': _Node.make('atrack', serverId, album.id, title: album.displayTitle, position: 0),
                      'title': album.displayTitle,
                      'subtitle': ?album.albumArtistTitle,
                      'image': _image(client, album.thumbPath),
                    },
                ],
              },
            ],
          },
        if (mixes.isNotEmpty) {'header': 'Mixes for You', 'items': mixes.take(listLimit).toList()},
        if (radio.isNotEmpty) {'header': 'Radio', 'items': radio},
      ],
      'emptyTitle': 'No music library',
    };
  }

  /// "`Artist` Radio" for the artists played last, where the server can
  /// make a station.
  Future<List<Map<String, Object?>>> _artistStations(List<(String, MediaServerClient, MediaLibrary)> libraries) async {
    final rows = <Map<String, Object?>>[];
    for (final (serverId, client, library) in libraries) {
      if (!client.capabilities.instantMix) continue;
      try {
        final page = await client.fetchLibraryPagedContent(
          library.id,
          query: const LibraryQuery(
            kind: MediaKind.artist,
            limit: artistStationCount,
            sort: LibrarySort(field: 'lastViewedAt'),
          ),
          libraryKind: library.kind,
        );
        for (final artist in page.items.where((a) => a.lastViewedAt != null)) {
          rows.add({
            'id': _Node.make('radio', serverId, artist.id, title: artist.displayTitle),
            'title': '${artist.displayTitle} Radio',
            'image': _image(client, artist.thumbPath),
            'systemImage': 'dot.radiowaves.left.and.right',
            'playable': true,
          });
        }
      } catch (e) {
        appLogger.w('CarPlay: no artist stations from $serverId', error: e);
      }
    }
    return rows.take(artistStationCount).toList();
  }

  /// Albums played most recently, newest first, across libraries.
  Future<List<(String, MediaServerClient, MediaItem)>> _recentAlbumItems(
    int count, [
    List<(String, MediaServerClient, MediaLibrary)>? libraries,
  ]) async {
    final albums = <(String, MediaServerClient, MediaItem)>[];
    for (final (serverId, client, library) in libraries ?? await _musicLibraries()) {
      try {
        final page = await client.fetchLibraryPagedContent(
          library.id,
          query: LibraryQuery(
            kind: MediaKind.album,
            limit: count,
            sort: const LibrarySort(field: 'lastViewedAt'),
          ),
          libraryKind: library.kind,
        );
        albums.addAll(page.items.where((a) => a.lastViewedAt != null).map((a) => (serverId, client, a)));
      } catch (e) {
        appLogger.w('CarPlay: no recent albums from $serverId', error: e);
      }
    }
    albums.sort((a, b) => (b.$3.lastViewedAt ?? 0).compareTo(a.$3.lastViewedAt ?? 0));
    return albums.take(count).toList();
  }

  List<Map<String, Object?>> _itemRowsOf(List<(String, MediaServerClient, MediaItem)> items) => [
    for (final (serverId, client, item) in items) _itemRow(serverId, client, item),
  ];

  Future<List<(String, MediaServerClient, MediaLibrary)>> _musicLibraries() async {
    final found = <(String, MediaServerClient, MediaLibrary)>[];
    for (final MapEntry(key: serverId, value: client) in _clients().entries) {
      try {
        for (final library in (await client.fetchLibraries()).where(_isMusicLibrary)) {
          found.add((serverId, client, library));
        }
      } catch (e) {
        appLogger.w('CarPlay: no libraries from $serverId', error: e);
      }
    }
    return found;
  }

  /// The library a mix filters, from its key (`/library/sections/{id}/all?…`).
  static int? _sectionOf(String mixKey) =>
      int.tryParse(RegExp(r'^/library/sections/(\d+)/').firstMatch(mixKey)?.group(1) ?? '');

  // MARK: - Lists

  List<Map<String, Object?>> _upNextRows() {
    final queue = _music.queue;
    final current = _music.currentIndex;
    if (current < 0 || queue.isEmpty) return const [];
    final rows = <Map<String, Object?>>[];
    for (var i = current; i < queue.length && rows.length < listLimit; i++) {
      final track = queue[i];
      final client = _clients()[track.serverId];
      rows.add({
        'id': _Node.make('qtrack', track.serverId ?? '', track.id, position: i),
        'title': track.displayTitle,
        if (track.trackArtistTitle != null) 'subtitle': track.trackArtistTitle,
        if (client != null) 'image': _image(client, track.thumbPath ?? track.parentThumbPath),
        'trackKey': trackKey(track),
        'playable': true,
      });
    }
    return rows;
  }

  Future<List<Map<String, Object?>>> _playlistRows() async {
    final rows = <Map<String, Object?>>[];
    for (final MapEntry(key: serverId, value: client) in _clients().entries) {
      try {
        final page = await client.fetchPlaylistsPage(playlistType: 'audio', size: listLimit);
        for (final playlist in page.items) {
          rows.add(_playlistRow(serverId, client, playlist));
        }
      } catch (e) {
        appLogger.w('CarPlay: no playlists from $serverId', error: e);
      }
    }
    return rows.take(listLimit).toList();
  }

  Map<String, Object?> _playlistRow(String serverId, MediaServerClient client, MediaPlaylist playlist) => {
    'id': _Node.make('playlist', serverId, playlist.id, title: playlist.title),
    'title': playlist.title,
    if (playlist.leafCount != null) 'subtitle': '${playlist.leafCount} tracks',
    'image': _image(client, playlist.compositeImagePath ?? playlist.thumbPath),
    'browsable': true,
  };

  /// [kind] from each music library, most recent by [sort] first.
  Future<List<Map<String, Object?>>> _libraryRows(MediaKind kind, {required String sort}) async {
    final rows = <Map<String, Object?>>[];
    for (final (serverId, client, library) in await _musicLibraries()) {
      try {
        final page = await client.fetchLibraryPagedContent(
          library.id,
          query: LibraryQuery(
            kind: kind,
            limit: listLimit,
            sort: LibrarySort(field: sort),
          ),
          libraryKind: library.kind,
        );
        for (final item in page.items) {
          rows.add(_itemRow(serverId, client, item));
        }
      } catch (e) {
        appLogger.w('CarPlay: no ${kind.name}s from $serverId', error: e);
      }
    }
    return rows.take(listLimit).toList();
  }

  static bool _isMusicLibrary(MediaLibrary library) =>
      library.kind == MediaKind.artist || library.defaultBrowseKinds.contains(MediaKind.artist);

  Map<String, Object?> _itemRow(String serverId, MediaServerClient client, MediaItem item) => {
    'id': _Node.make(item.kind == MediaKind.artist ? 'artist' : 'album', serverId, item.id, title: item.displayTitle),
    'title': item.displayTitle,
    if (item.kind == MediaKind.album && item.albumArtistTitle != null) 'subtitle': item.albumArtistTitle,
    'image': _image(client, item.thumbPath),
    'browsable': true,
  };

  Future<List<Map<String, Object?>>> _playlistTrackRows(_Node node) async {
    final client = _client(node);
    if (client == null) return const [];
    final tracks = await _playlistTracks(client, node.itemId, listLimit);
    if (tracks.isEmpty) return const [];
    return [
      _actionRow('pshuffle', node, 'Shuffle', 'shuffle'),
      for (final (i, track) in tracks.indexed) _trackRow('ptrack', node, client, track, i),
    ];
  }

  Future<List<Map<String, Object?>>> _artistRows(_Node node) async {
    final client = _client(node);
    if (client == null) return const [];
    final artist = await client.fetchItem(node.itemId);
    if (artist == null) return const [];
    final albums = await client.fetchArtistAlbums(artist);
    return [
      _actionRow('ashuffle', node, 'Shuffle', 'shuffle'),
      if (client.capabilities.instantMix)
        _actionRow('radio', node, '${artist.displayTitle} Radio', 'dot.radiowaves.left.and.right'),
      for (final album in albums.take(listLimit - 2)) _itemRow(node.serverId!, client, album),
    ];
  }

  Future<List<Map<String, Object?>>> _albumTrackRows(_Node node) async {
    final client = _client(node);
    if (client == null) return const [];
    final tracks = await client.fetchAlbumTracks(node.itemId);
    if (tracks.isEmpty) return const [];
    return [
      if (tracks.length > 1) _actionRow('alshuffle', node, 'Shuffle', 'shuffle'),
      for (final (i, track) in tracks.take(listLimit - 1).indexed) _trackRow('atrack', node, client, track, i),
    ];
  }

  Map<String, Object?> _actionRow(String kind, _Node parent, String title, String systemImage) => {
    'id': _Node.make(kind, parent.serverId!, parent.itemId, title: parent.title),
    'title': title,
    'systemImage': systemImage,
    'playable': true,
  };

  Map<String, Object?> _trackRow(String kind, _Node parent, MediaServerClient client, MediaItem track, int i) => {
    'id': _Node.make(kind, parent.serverId!, parent.itemId, title: parent.title, position: i),
    'title': track.displayTitle,
    if (track.trackArtistTitle != null) 'subtitle': track.trackArtistTitle,
    'image': _image(client, track.thumbPath ?? track.parentThumbPath),
    'trackKey': trackKey(track),
    'playable': true,
  };

  static Future<List<MediaItem>> _playlistTracks(MediaServerClient client, String playlistId, int limit) async {
    final tracks = <MediaItem>[];
    while (tracks.length < limit) {
      final page = await client.fetchPlaylistPage(playlistId, start: tracks.length, size: limit - tracks.length);
      if (page.items.isEmpty) break;
      tracks.addAll(page.items.where((t) => t.kind == MediaKind.track));
      if (tracks.length >= page.totalCount || page.offset + page.items.length >= page.totalCount) break;
    }
    return tracks;
  }

  static String? _image(MediaServerClient client, String? path) {
    if (path == null || path.isEmpty) return null;
    final url = client.thumbnailUrl(path, width: 200, height: 200);
    return url.isEmpty ? null : url;
  }
}

/// A row id: `kind|serverId|itemId|position|title`. The title rides along so
/// playback can name its source without another round trip.
class _Node {
  const _Node(this.kind, this.serverId, this.itemId, this.position, this.title);

  final String kind;
  final String? serverId;
  final String itemId;
  final int? position;
  final String? title;

  static String make(String kind, String serverId, String itemId, {String? title, int? position}) =>
      [kind, serverId, itemId, position?.toString() ?? '', title ?? ''].map(Uri.encodeComponent).join('|');

  static _Node parse(String id) {
    final parts = id.split('|').map(Uri.decodeComponent).toList();
    if (parts.length == 1) return _Node(parts[0], null, '', null, null);
    if (parts.length != 5) throw ArgumentError.value(id, 'id', 'not a CarPlay row');
    return _Node(parts[0], parts[1], parts[2], int.tryParse(parts[3]), parts[4].isEmpty ? null : parts[4]);
  }
}
