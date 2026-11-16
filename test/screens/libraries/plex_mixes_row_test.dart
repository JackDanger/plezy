import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/screens/libraries/tabs/plex_mixes_row.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/backend_client_fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });

  tearDown(() => db.close());

  PlexClient client(List<String> mixTitles) => testPlexClient(
    serverId: ServerId('server-id'),
    handler: (request) async => http.Response(
      jsonEncode({
        'MediaContainer': {
          'Hub': [
            if (mixTitles.isNotEmpty)
              {
                'hubIdentifier': 'music.mixes.3',
                'type': 'playlist',
                'Metadata': [
                  for (final (i, title) in mixTitles.indexed)
                    {'type': 'playlist', 'title': title, 'key': '/library/sections/3/all?artist.id=$i'},
                ],
              },
          ],
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );

  Future<void> pump(WidgetTester tester, PlexClient plex, {double textScale = 1}) async {
    addTearDown(plex.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.light),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: ListView(
              children: [PlexMixesRow(client: plex, libraryId: '3')],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a card for each mix', (tester) async {
    await pump(tester, client(['Artist One Mix', 'Artist Two Mix']));

    expect(find.text('Mixes for you'), findsOneWidget);
    expect(find.text('Artist One Mix'), findsOneWidget);
    expect(find.text('Artist Two Mix'), findsOneWidget);
  });

  testWidgets('long titles fit at a large text size', (tester) async {
    await pump(tester, client(['An Artist With A Name Long Enough To Wrap Onto Two Lines Mix']), textScale: 2);

    expect(tester.takeException(), isNull);
  });

  testWidgets('shows nothing when the server has no mixes', (tester) async {
    await pump(tester, client([]));

    expect(find.text('Mixes for you'), findsNothing);
  });
}
