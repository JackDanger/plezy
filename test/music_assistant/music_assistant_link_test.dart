import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/music_assistant/music_assistant_link.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('the token is stored encrypted and read back in the clear', () async {
    final store = SettingsMusicAssistantConfigStore();
    await store.write(
      const MusicAssistantServerConfig(baseUrl: 'http://10.0.2.107:8095', serverId: 'srv', accessToken: 'secret'),
    );

    final raw = (await SettingsService.getInstance()).read(SettingsService.musicAssistantServer);
    expect(raw, isNot(contains('secret')));
    final read = await store.read();
    expect(read?.baseUrl, 'http://10.0.2.107:8095');
    expect(read?.serverId, 'srv');
    expect(read?.accessToken, 'secret');
  });

  test('a server saved by an earlier build as a connection row moves over once', () async {
    final token = await CredentialVault.protect('old-token');
    await db
        .into(db.connections)
        .insert(
          ConnectionsCompanion.insert(
            id: 'ma-srv',
            kind: 'music_assistant',
            displayName: 'Music Assistant',
            configJson: jsonEncode({
              'displayName': 'Music Assistant',
              'baseUrl': 'http://10.0.2.107:8095',
              'serverId': 'srv',
              'accessToken': token,
            }),
            createdAt: 0,
          ),
        );
    await db
        .into(db.connections)
        .insert(
          ConnectionsCompanion.insert(id: 'plex-1', kind: 'plex', displayName: 'P', configJson: '{}', createdAt: 0),
        );

    final store = SettingsMusicAssistantConfigStore(database: db);
    final imported = await store.read();

    expect(imported?.baseUrl, 'http://10.0.2.107:8095');
    expect(imported?.serverId, 'srv');
    expect(imported?.accessToken, 'old-token');
    final kinds = (await db.select(db.connections).get()).map((row) => row.kind);
    expect(kinds, ['plex'], reason: 'the old row goes, the Plex one stays');
    expect((await store.read())?.serverId, 'srv', reason: 'and the setting is what is read from now on');
  });

  test('nothing saved, nothing to connect to', () async {
    expect(await SettingsMusicAssistantConfigStore(database: db).read(), isNull);
  });
}
