import 'dart:async';

import 'package:flutter/services.dart';

import '../media/library_query.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_playlist.dart';
import '../media/media_server_client.dart';
import '../utils/app_logger.dart';
import 'music/music_playback_service.dart';

/// Answers CarPlay: what to list on each screen, and what to play when a row
/// is tapped.
///
/// The CarPlay screens are native templates (`CarPlaySceneDelegate.swift`);
/// they know nothing of servers. Each row carries an opaque id that this
/// bridge made, and the native side hands it back to browse into it or play
/// it. Playback goes through the same [MusicPlaybackService] as the phone, so
/// the car's Now Playing screen, the lock screen and the app agree.
///
/// Ids are `kind|serverId|itemId`, plus a position for a track in a list.
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

  static const String _playlists = 'playlists';
  static const String _recentArtists = 'artists';
  static const String _recentAlbums = 'albums';

  final Map<String, MediaServerClient> Function() _clients;
  final MusicPlaybackService _music;
  final MethodChannel _channel;

  void start() {
    _channel.setMethodCallHandler(_handle);
    // CarPlay may already be up, showing "open Plezy": it can load now.
    unawaited(
      _channel.invokeMethod<void>('ready').catchError((Object e) {
        appLogger.d('CarPlay ready signal not delivered: $e');
      }),
    );
  }

  void dispose() {
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
      default:
        throw MissingPluginException(call.method);
    }
  }

  /// The tab bar. `systemImage` is an SF Symbol name.
  List<Map<String, String>> tabs() => const [
    {'id': _playlists, 'title': 'Playlists', 'systemImage': 'music.note.list'},
    {'id': _recentArtists, 'title': 'Artists', 'systemImage': 'music.mic'},
    {'id': _recentAlbums, 'title': 'Albums', 'systemImage': 'square.stack'},
  ];

  /// The rows under [id]: a tab, a playlist, an artist or an album.
  Future<Map<String, Object?>> browse(String id) async {
    final node = _Node.parse(id);
    final List<Map<String, Object?>> items;
    switch (node.kind) {
      case _playlists:
        items = await _playlistRows();
      case _recentArtists:
        items = await _libraryRows(MediaKind.artist, sort: 'lastViewedAt');
      case _recentAlbums:
        items = await _libraryRows(MediaKind.album, sort: 'addedAt');
      case 'playlist':
        items = await _playlistTrackRows(node);
      case 'artist':
        items = await _artistRows(node);
      case 'album':
        items = await _albumTrackRows(node);
      default:
        throw ArgumentError.value(id, 'id', 'not a CarPlay list');
    }
    return {'items': items};
  }

  /// Start what [id] names. Returns null once playing, or a reason to show.
  Future<String?> play(String id) async {
    final node = _Node.parse(id);
    final client = _client(node);
    if (client == null) return 'This server is offline';
    final intent = _music.beginPlayIntent();
    try {
      switch (node.kind) {
        case 'ptrack':
          final tracks = await _playlistTracks(client, node.itemId, playlistQueueLimit);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          final at = node.position ?? 0;
          if (at >= tracks.length) return 'That track is no longer in the playlist';
          await _music.playFromList(
            tracks: tracks,
            startTrack: tracks[at],
            playContext: MusicPlayContext(title: node.title ?? '', kind: MusicPlayContextKind.playlist),
          );
        case 'pshuffle':
          final tracks = await _playlistTracks(client, node.itemId, playlistQueueLimit);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (tracks.isEmpty) return 'This playlist is empty';
          await _music.playFromList(
            tracks: tracks,
            shuffle: true,
            playContext: MusicPlayContext(title: node.title ?? '', kind: MusicPlayContextKind.playlist),
          );
        case 'atrack':
          final tracks = await client.fetchAlbumTracks(node.itemId);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          final at = node.position ?? 0;
          if (at >= tracks.length) return 'That track is no longer on the album';
          await _music.playFromList(
            tracks: tracks,
            startTrack: tracks[at],
            playContext: MusicPlayContext(title: node.title ?? '', kind: MusicPlayContextKind.album),
          );
        case 'ashuffle':
          final tracks = await client.fetchPlayableDescendants(node.itemId);
          if (!_music.isPlayIntentCurrent(intent)) return null;
          if (tracks.isEmpty) return 'Nothing to play by this artist';
          await _music.playFromList(
            tracks: tracks,
            shuffle: true,
            playContext: MusicPlayContext(title: node.title ?? '', kind: MusicPlayContextKind.artist),
          );
        default:
          return 'This cannot be played';
      }
    } catch (e, st) {
      appLogger.w('CarPlay could not play $id', error: e, stackTrace: st);
      return 'Could not start playback';
    }
    return null;
  }

  MediaServerClient? _client(_Node node) => node.serverId == null ? null : _clients()[node.serverId];

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
    for (final MapEntry(key: serverId, value: client) in _clients().entries) {
      try {
        final libraries = (await client.fetchLibraries()).where(_isMusicLibrary);
        for (final library in libraries) {
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
      for (final album in albums.take(listLimit - 1)) _itemRow(node.serverId!, client, album),
    ];
  }

  Future<List<Map<String, Object?>>> _albumTrackRows(_Node node) async {
    final client = _client(node);
    if (client == null) return const [];
    final tracks = await client.fetchAlbumTracks(node.itemId);
    return [for (final (i, track) in tracks.take(listLimit).indexed) _trackRow('atrack', node, client, track, i)];
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
    'image': _image(client, track.thumbPath),
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
