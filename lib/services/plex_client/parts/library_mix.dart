part of '../../plex_client.dart';

/// How many tracks a library shuffle queues. A genre can run to tens of
/// thousands of tracks, far more than a queue should hold, so the server picks
/// this many at random from all of them.
const plexLibraryShuffleTrackCount = 500;

/// How many tracks a radio from a library view queues.
const plexLibraryRadioTrackCount = 100;

/// Plex keeps each track's Last.fm listener count. Radio sticks to tracks at
/// least this many people know, which is most of what sets it apart from a
/// shuffle: a shuffle of Folk is a fair share of B-sides and demos.
const plexLibraryRadioMinListeners = 5000;

/// The most tracks one artist gets in a radio queue. A plain random pick of
/// Folk is nearly a tenth Bob Dylan.
const plexLibraryRadioTracksPerArtist = 3;

/// The track query behind playing a music library view of [viewKind] (artists,
/// albums or tracks): every track belonging to what the view shows, in random
/// order, or only well-known ones for [radio]. Null for any other kind.
///
/// [filters] were chosen against the view's own type, so they move onto it:
/// "Electronic" picked while viewing artists means tracks by Electronic artists
/// (`artist.genre`), several times the tracks Plex tags Electronic themselves.
@visibleForTesting
LibraryQuery? plexLibraryMixQuery(MediaKind viewKind, List<LibraryFilter> filters, {bool radio = false}) {
  final prefix = switch (viewKind) {
    MediaKind.artist => 'artist.',
    MediaKind.album => 'album.',
    MediaKind.track => '',
    _ => null,
  };
  if (prefix == null) return null;
  return LibraryQuery(
    kind: MediaKind.track,
    limit: plexLibraryShuffleTrackCount,
    sort: const LibrarySort(field: 'random'),
    filters: [
      for (final filter in filters) filter.copyWith(field: '$prefix${filter.field}'),
      if (radio)
        const LibraryFilter(
          field: 'ratingCount',
          op: LibraryFilterOperator.atLeast,
          values: ['$plexLibraryRadioMinListeners'],
        ),
    ],
  );
}

/// [tracks] with at most [perArtist] from any one artist, the same artist
/// never twice in a row where it can be helped, cut to [count].
@visibleForTesting
List<MediaItem> spreadArtists(
  List<MediaItem> tracks, {
  int perArtist = plexLibraryRadioTracksPerArtist,
  required int count,
}) {
  String artistOf(MediaItem track) => track.grandparentId ?? track.grandparentTitle ?? track.id;
  final perArtistCount = <String, int>{};
  final kept = <MediaItem>[];
  for (final track in tracks) {
    final artist = artistOf(track);
    final seen = perArtistCount[artist] ?? 0;
    if (seen >= perArtist) continue;
    perArtistCount[artist] = seen + 1;
    kept.add(track);
    if (kept.length == count) break;
  }
  final spread = <MediaItem>[];
  while (kept.isNotEmpty) {
    final next = kept.indexWhere((t) => spread.isEmpty || artistOf(t) != artistOf(spread.last));
    spread.add(kept.removeAt(next < 0 ? 0 : next));
  }
  return spread;
}

/// Playing a whole music library view. Plex has no station for a genre or a
/// filtered view, so these are built from library queries.
extension PlexLibraryMix on PlexClient {
  /// Whether a view of [viewKind] can be played this way.
  static bool supports(MediaKind viewKind) => plexLibraryMixQuery(viewKind, const []) != null;

  /// Every track behind the view, shuffled, filters included.
  Future<List<MediaItem>> fetchLibraryShuffle(
    String libraryId, {
    required MediaKind viewKind,
    List<LibraryFilter> filters = const [],
  }) async {
    final query = plexLibraryMixQuery(viewKind, filters);
    if (query == null) return const [];
    return (await fetchLibraryPagedContent(libraryId, query: query)).items;
  }

  /// Well-known tracks behind the view, spread across artists. A genre too
  /// obscure for Last.fm to know falls back to all of its tracks.
  Future<List<MediaItem>> fetchLibraryRadio(
    String libraryId, {
    required MediaKind viewKind,
    List<LibraryFilter> filters = const [],
  }) async {
    final query = plexLibraryMixQuery(viewKind, filters, radio: true);
    if (query == null) return const [];
    var tracks = (await fetchLibraryPagedContent(libraryId, query: query)).items;
    if (tracks.length < plexLibraryRadioTrackCount ~/ 2) {
      tracks = await fetchLibraryShuffle(libraryId, viewKind: viewKind, filters: filters);
    }
    return spreadArtists(tracks, count: plexLibraryRadioTrackCount);
  }
}
