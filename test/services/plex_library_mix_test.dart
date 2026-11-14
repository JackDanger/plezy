import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/library_query_translator.dart';
import 'package:plezy/services/plex_client.dart';

void main() {
  group('plexLibraryMixQuery', () {
    const electronic = LibraryFilter(field: 'genre', values: ['5194']);
    Map<String, dynamic> wire(LibraryQuery query) => const PlexLibraryQueryTranslator().toQueryParameters(query);

    test('a genre picked among artists shuffles tracks by those artists', () {
      expect(wire(plexLibraryMixQuery(MediaKind.artist, [electronic])!), {
        'type': '10',
        'sort': 'random:desc',
        'artist.genre': '5194',
      });
    });

    test('a genre picked among albums shuffles tracks on those albums', () {
      expect(wire(plexLibraryMixQuery(MediaKind.album, [electronic])!)['album.genre'], '5194');
    });

    test('a genre picked among tracks filters the tracks themselves', () {
      expect(wire(plexLibraryMixQuery(MediaKind.track, [electronic])!)['genre'], '5194');
    });

    test('an unfiltered view shuffles the whole library, a queue at a time', () {
      final query = plexLibraryMixQuery(MediaKind.artist, const [])!;
      expect(wire(query), {'type': '10', 'sort': 'random:desc'});
      expect(query.limit, plexLibraryShuffleTrackCount);
    });

    test('only artists, albums and tracks have a set of tracks to shuffle', () {
      expect(plexLibraryMixQuery(MediaKind.folder, const [electronic]), isNull);
    });
  });

  group('plexLibraryMixQuery radio', () {
    test('sticks to tracks people know', () {
      final query = plexLibraryMixQuery(MediaKind.artist, const [
        LibraryFilter(field: 'genre', values: ['9354']),
      ], radio: true)!;
      expect(const PlexLibraryQueryTranslator().toQueryParameters(query), {
        'type': '10',
        'sort': 'random:desc',
        'artist.genre': '9354',
        'ratingCount>>': '$plexLibraryRadioMinListeners',
      });
    });
  });

  group('spreadArtists', () {
    MediaItem track(String id, String artist) =>
        MediaItem.plex(id: id, serverId: 's', kind: MediaKind.track, grandparentId: artist, grandparentTitle: artist);
    List<String?> artists(List<MediaItem> tracks) => [for (final t in tracks) t.grandparentId];

    test('no artist gets more than its share', () {
      final tracks = [for (var i = 0; i < 10; i++) track('d$i', 'Dylan'), track('j', 'Joni'), track('n', 'Nick')];
      final spread = spreadArtists(tracks, count: 100);
      expect(artists(spread).where((a) => a == 'Dylan'), hasLength(plexLibraryRadioTracksPerArtist));
      expect(spread, hasLength(plexLibraryRadioTracksPerArtist + 2));
    });

    test('the same artist is not played twice in a row where it can be helped', () {
      final tracks = [track('d1', 'Dylan'), track('d2', 'Dylan'), track('j1', 'Joni'), track('j2', 'Joni')];
      expect(artists(spreadArtists(tracks, count: 100)), ['Dylan', 'Joni', 'Dylan', 'Joni']);
    });

    test('stops at count', () {
      final tracks = [for (var i = 0; i < 10; i++) track('$i', 'artist $i')];
      expect(spreadArtists(tracks, count: 4).map((t) => t.id), ['0', '1', '2', '3']);
    });
  });
}
