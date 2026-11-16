import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../media/library_query.dart';
import '../media/media_item.dart';
import '../media/media_playlist.dart';
import '../media/media_server_client.dart';
import '../navigation/profile_navigation_scope.dart';
import '../screens/music/album_detail_screen.dart';
import '../screens/music/artist_detail_screen.dart';
import '../screens/music/now_playing_screen.dart';
import '../services/device_performance.dart';
import '../services/music/music_playback_service.dart';
import '../services/playlist_items_loader.dart';
import '../services/playback_initialization_types.dart';
import '../theme/mono_motion.dart';
import '../theme/mono_tokens.dart';
import '../i18n/strings.g.dart';
import 'app_logger.dart';
import 'platform_detector.dart';
import 'provider_extensions.dart';
import 'snackbar_helper.dart';

/// Route name of the now-playing screen — the mini-player's route observer
/// suppresses itself while this (or the video player) is in the stack.
const String kNowPlayingRouteName = '/now_playing';

/// Content routes belong on the profile-session navigator. For contexts
/// inside it this is exactly `Navigator.of(context)`; the mini-player overlay
/// sits *above* that navigator (its nearest navigator is the root one), so it
/// resolves the profile navigator through [ProfileNavigationScope] instead.
NavigatorState _contentNavigatorOf(BuildContext context) {
  return ProfileNavigationScope.maybeOf(context)?.navigatorKey.currentState ?? Navigator.of(context);
}

/// Push the artist detail screen for [artist] on the profile navigator.
Future<void> navigateToArtist(BuildContext context, MediaItem artist) async {
  await _contentNavigatorOf(context).push(MaterialPageRoute(builder: (context) => ArtistDetailScreen(artist: artist)));
}

/// Fetch the artist [artistId] with [client], then push its detail screen on
/// the profile navigator. Soft-fails: a failed fetch is logged and skipped,
/// as is navigation after [context] unmounts during the fetch.
Future<void> openArtistById(BuildContext context, MediaServerClient client, String artistId) async {
  MediaItem? artist;
  try {
    artist = await client.fetchItem(artistId);
  } catch (e) {
    appLogger.w('Failed to fetch artist $artistId', error: e);
  }
  if (artist == null || !context.mounted) return;
  await navigateToArtist(context, artist);
}

/// Push the album detail screen for [album] on the profile navigator.
/// [isOffline] makes the screen read its track list from downloads.
Future<void> navigateToAlbum(BuildContext context, MediaItem album, {bool isOffline = false}) async {
  await _contentNavigatorOf(context).push(
    MaterialPageRoute(
      builder: (context) => AlbumDetailScreen(album: album, isOffline: isOffline),
    ),
  );
}

/// Push the now-playing screen (slide-up + fade) on the profile navigator.
/// No-op when it is already on top (e.g. TV auto-push while open). Popping
/// it never touches playback — audio continues under the mini-player.
Future<void> openNowPlaying(BuildContext context) async {
  final navigator = _contentNavigatorOf(context);
  if (_isRouteOnTop(navigator, kNowPlayingRouteName)) return;
  final duration = DevicePerformance.reducedDuration(tokens(context).expressive);
  await navigator.push(
    PageRouteBuilder<void>(
      settings: const RouteSettings(name: kNowPlayingRouteName),
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (context, animation, secondaryAnimation) => const NowPlayingScreen(),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: MonoMotion.emphasized,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

bool _isRouteOnTop(NavigatorState navigator, String name) {
  var onTop = false;
  navigator.popUntil((route) {
    if (route.isCurrent) onTop = route.settings.name == name;
    return true; // inspect only — never pops
  });
  return onTop;
}

/// TV has no persistent mini-player, so starting playback lands the user on
/// the now-playing screen directly.
void _autoOpenNowPlayingOnTv(BuildContext context) {
  if (!PlatformDetector.isTV() || !context.mounted) return;
  // A failed start (error surfaced on the service's errors stream) leaves no
  // current track — nothing to show.
  if (context.read<MusicPlaybackService>().currentTrack == null) return;
  openNowPlaying(context).catchError((Object e) {
    appLogger.w('Failed to auto-open now playing', error: e);
  });
}

/// Start playback of [tracks] via the session [MusicPlaybackService].
Future<void> playTracks(
  BuildContext context, {
  required List<MediaItem> tracks,
  MediaItem? startTrack,
  required MusicPlayContext playContext,
  bool shuffle = false,
}) async {
  await context.read<MusicPlaybackService>().playFromList(
    tracks: tracks,
    startTrack: startTrack,
    playContext: playContext,
    shuffle: shuffle,
  );
  if (context.mounted) _autoOpenNowPlayingOnTv(context);
}

/// Fetch a track list with [fetch], then play it — the shape every music
/// entry point that needs a server round-trip before playback repeats:
/// [MusicPlaybackService.beginPlayIntent] → fetch → mounted/intent re-check →
/// [playTracks]. Guarding the round-trip with the intent keeps a slow fetch
/// from replacing a queue the user started later.
///
/// [onError] reports a failed fetch and runs only while the intent is still
/// current and [context] mounted; passing null instead lets the failure
/// propagate to the caller's own error boundary. [onEmpty] handles a
/// successful but empty fetch; passing null hands the empty list to
/// [playTracks] unchanged.
Future<void> playFetchedTracks(
  BuildContext context, {
  required Future<List<MediaItem>> Function() fetch,
  required MusicPlayContext playContext,
  void Function(Object error, StackTrace stackTrace)? onError,
  VoidCallback? onEmpty,
  MediaItem? startTrack,
  bool shuffle = false,
}) async {
  final service = context.read<MusicPlaybackService>();
  final intent = service.beginPlayIntent();
  final List<MediaItem> tracks;
  try {
    tracks = await fetch();
  } catch (error, stackTrace) {
    if (!service.isPlayIntentCurrent(intent)) return;
    if (onError == null) rethrow;
    if (!context.mounted) return;
    onError(error, stackTrace);
    return;
  }
  if (!context.mounted || !service.isPlayIntentCurrent(intent)) return;
  if (tracks.isEmpty && onEmpty != null) {
    onEmpty();
    return;
  }
  await playTracks(context, tracks: tracks, startTrack: startTrack, playContext: playContext, shuffle: shuffle);
}

/// A playlist longer than this plays from a window of it instead of being
/// fetched whole first: Plex's built-in smart playlists ("Recently Added",
/// "All Music") run to tens or hundreds of thousands of tracks, and paging
/// through all of them before the first note left a tap looking dead.
const int largePlaylistThreshold = 1000;

/// How many tracks past the starting one a large playlist queues.
const int largePlaylistQueueLength = 1000;

/// Random pages a large playlist's shuffle draws from.
const int _shufflePageCount = 5;
const int _shufflePageSize = 100;

/// Play an audio [playlist] through the music session under a playlist
/// play-context. Callers that already hold the full track list pass it as
/// [preloadedItems] to skip the server round-trip; [onError] and [onEmpty]
/// carry each caller's own snackbar strings. Shared by the playlist detail
/// screen and the media context menu.
///
/// A playlist over [largePlaylistThreshold] tracks starts at once from
/// [loadedItems] (what the screen has paged in so far, or the first page),
/// and the rest of a [largePlaylistQueueLength]-track window is added to the
/// queue while it plays. Shuffling one draws from random pages across it.
Future<void> playAudioPlaylist(
  BuildContext context, {
  required MediaServerClient client,
  required MediaPlaylist playlist,
  bool shuffle = false,
  MediaItem? startTrack,
  List<MediaItem>? preloadedItems,
  List<MediaItem>? loadedItems,
  void Function(Object error, StackTrace stackTrace)? onError,
  VoidCallback? onEmpty,
  Random? random,
}) async {
  final playContext = MusicPlayContext(title: playlist.title, kind: MusicPlayContextKind.playlist);
  final total = playlist.leafCount;
  if (preloadedItems != null || total == null || total <= largePlaylistThreshold) {
    return playFetchedTracks(
      context,
      fetch: () async => preloadedItems ?? await fetchAllPlaylistItems(client, playlist.id),
      playContext: playContext,
      onError: onError,
      onEmpty: onEmpty,
      startTrack: startTrack,
      shuffle: shuffle,
    );
  }

  if (shuffle) {
    return playFetchedTracks(
      context,
      fetch: () => _randomPlaylistSample(client, playlist.id, total, random ?? Random()),
      playContext: playContext,
      onError: onError,
      onEmpty: onEmpty,
      startTrack: startTrack,
      shuffle: true,
    );
  }

  final service = context.read<MusicPlaybackService>();
  var fetchedThrough = 0;
  var startIndex = 0;
  await playFetchedTracks(
    context,
    fetch: () async {
      final initial = loadedItems != null && loadedItems.isNotEmpty
          ? List<MediaItem>.of(loadedItems)
          : (await client.fetchPlaylistPage(playlist.id, start: 0, size: playlistItemsPageSize)).items;
      fetchedThrough = initial.length;
      if (startTrack != null) startIndex = initial.indexWhere((t) => t.id == startTrack.id).clamp(0, initial.length);
      return initial;
    },
    playContext: playContext,
    onError: onError,
    onEmpty: onEmpty,
    startTrack: startTrack,
  );
  if (fetchedThrough == 0 || !identical(service.playContext, playContext)) return;
  await _extendPlaylistQueue(
    service,
    client: client,
    playlistId: playlist.id,
    playContext: playContext,
    from: fetchedThrough,
    until: (startIndex + 1 + largePlaylistQueueLength).clamp(0, total),
  );
}

/// Page the rest of a large playlist's window onto the queue, stopping as soon
/// as anything else takes over the session.
Future<void> _extendPlaylistQueue(
  MusicPlaybackService service, {
  required MediaServerClient client,
  required String playlistId,
  required MusicPlayContext playContext,
  required int from,
  required int until,
}) async {
  final revision = service.queueSessionRevision;
  bool stillOurs() => service.queueSessionRevision == revision && identical(service.playContext, playContext);
  var start = from;
  while (start < until && stillOurs()) {
    final LibraryPage<MediaItem> page;
    try {
      page = await client.fetchPlaylistPage(
        playlistId,
        start: start,
        size: (until - start).clamp(1, playlistItemsPageSize),
      );
    } catch (e, st) {
      appLogger.w('Could not add more of playlist $playlistId to the queue', error: e, stackTrace: st);
      return;
    }
    if (page.items.isEmpty || !stillOurs()) return;
    service.addToEnd(page.items);
    start += page.items.length;
  }
}

/// A few random pages from across a playlist too long to fetch whole, without
/// duplicates.
Future<List<MediaItem>> _randomPlaylistSample(
  MediaServerClient client,
  String playlistId,
  int total,
  Random random,
) async {
  final lastStart = (total - _shufflePageSize).clamp(0, total);
  final starts = {for (var i = 0; i < _shufflePageCount; i++) random.nextInt(lastStart + 1)};
  final pages = await Future.wait(
    starts.map((start) => client.fetchPlaylistPage(playlistId, start: start, size: _shufflePageSize)),
  );
  final seen = <String>{};
  return [
    for (final page in pages)
      for (final item in page.items)
        if (seen.add(item.id)) item,
  ];
}

/// Play [track] within its album queue: fetch the album's tracks and start
/// at [track]. Falls back to single-track playback when the track has no
/// album, isn't found in it, or the album fetch fails.
///
/// Hand-written rather than routed through [playFetchedTracks]: the fallback
/// must play under the *same* intent as the album fetch, so a stale fallback
/// can never supersede a newer request.
Future<void> playTrackWithAlbumContext(BuildContext context, MediaItem track) async {
  final service = context.read<MusicPlaybackService>();
  final intent = service.beginPlayIntent();

  final albumId = track.parentId;
  final client = context.getMediaClientForItemOrNull(track);
  if (albumId != null && client != null) {
    try {
      final tracks = await client.fetchAlbumTracks(albumId);
      final startIndex = tracks.indexWhere((item) => item.id == track.id);
      if (!context.mounted || !service.isPlayIntentCurrent(intent)) return;
      if (startIndex != -1) {
        await playTracks(
          context,
          tracks: tracks,
          startTrack: tracks[startIndex],
          playContext: MusicPlayContext(title: track.albumTitle ?? '', kind: MusicPlayContextKind.album),
        );
        return;
      }
    } catch (e) {
      if (!service.isPlayIntentCurrent(intent)) return;
      appLogger.w('Failed to fetch album context for track ${track.id}; playing single track', error: e);
      if (!context.mounted) return;
    }
  }

  if (!context.mounted || !service.isPlayIntentCurrent(intent)) return;
  await playTracks(
    context,
    tracks: [track],
    playContext: MusicPlayContext(title: track.title ?? '', kind: MusicPlayContextKind.tracks),
  );
}

/// Fetch and play an instant mix seeded from [seed] (track/album/artist).
/// Only call when the seed's server advertises
/// `ServerCapabilities.instantMix`.
///
/// Owns the user feedback for a failed or empty mix (#2141): the tap site is
/// the only surface guaranteed to be mounted while the mix loads, so the
/// snackbar shows here. No double-snackbar with the now-playing screen's
/// `errors`-stream listener — the service throws fetch failures to this
/// caller instead of emitting them there, keeping the stream for
/// mid-playback errors.
Future<void> playInstantMix(BuildContext context, MediaItem seed) async {
  final InstantMixOutcome outcome;
  try {
    outcome = await context.read<MusicPlaybackService>().playInstantMix(seed);
  } catch (error) {
    if (!context.mounted) return;
    showErrorSnackBar(context, error is PlaybackException ? error.message : t.music.instantMixFailed);
    return;
  }
  if (!context.mounted) return;
  switch (outcome) {
    case InstantMixOutcome.started:
      _autoOpenNowPlayingOnTv(context);
    case InstantMixOutcome.empty:
      showErrorSnackBar(context, t.music.instantMixEmpty);
    case InstantMixOutcome.superseded:
      break;
  }
}
