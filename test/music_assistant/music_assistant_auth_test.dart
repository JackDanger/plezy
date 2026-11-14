import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music_assistant/music_assistant_api.dart';
import 'package:plezy/services/music_assistant/music_assistant_link.dart';

import 'fake_ma_server.dart';
import 'test_link.dart';

/// Answers the way 2.10.9 does, with every code taken from a live server:
/// authenticated commands are refused with `20` until `auth` has succeeded, a
/// bad token is `23`, and `auth/login` reports bad credentials as a successful
/// reply saying `success: false`.
class _AccountServer {
  bool signedIn = false;

  Object? respond(String command, Map<String, dynamic> args) {
    switch (command) {
      case 'auth':
        if (args['token'] == 'session-token' || args['token'] == 'stored-token') {
          signedIn = true;
          return {'authenticated': true};
        }
        return const MaErrorReply(23, 'The access token is invalid or has expired.');
      case 'auth/login':
        return args['password'] == 'right'
            ? {'success': true, 'access_token': 'session-token'}
            : {'success': false, 'error': 'Invalid username or password'};
    }
    if (!signedIn) return const MaErrorReply(20, 'Authentication is required.');
    return switch (command) {
      'auth/token/create' => 'long-lived-token',
      'music/artists/count' => 7,
      _ => const <dynamic>[],
    };
  }
}

void main() {
  final baseUrl = Uri.parse('http://127.0.0.1:8095');

  MusicAssistantApi apiFor(FakeMaServer server) {
    final api = MusicAssistantApi(channelFactory: server.open, autoReconnect: false);
    addTearDown(api.dispose);
    return api;
  }

  group('signing a socket in', () {
    test('the token goes out before anything can see the socket as connected', () async {
      final account = _AccountServer();
      final server = FakeMaServer(responder: account.respond);
      final api = apiFor(server);

      // The connected listener is the builtin player and the speaker list, and
      // both send commands the moment they hear it. A sign-in that lands after
      // them is the original bug with extra steps.
      final seenAtConnected = <String>[];
      api.connectionStates.listen((state) {
        if (state == MaConnectionState.connected) seenAtConnected.addAll(server.commands);
      });

      await api.connect(baseUrl, accessToken: 'stored-token');
      await pumpEventQueue();

      expect(server.commands.first, 'auth');
      expect(server.argsFor('auth'), {'token': 'stored-token'});
      expect(seenAtConnected, ['auth']);
      await expectLater(api.sendCommand('players/all'), completes);
    });

    test('a later connect without a token stays signed in', () async {
      // One fake per socket, as a real server has: a closed one cannot be reused.
      final sockets = <FakeMaServer>[];
      final api = MusicAssistantApi(
        channelFactory: (url) {
          sockets.add(FakeMaServer(responder: _AccountServer().respond));
          return sockets.last.open(url);
        },
        autoReconnect: false,
      );
      addTearDown(api.dispose);

      await api.connect(baseUrl, accessToken: 'stored-token');
      // `_reconnectMusicAssistantServer` reconnects with the URL alone. The
      // server forgets a socket's sign-in with the socket, so dropping the
      // token here would lose every speaker on the first network blip.
      await api.connect(baseUrl);

      expect(sockets, hasLength(2));
      expect(sockets.last.argsFor('auth'), {'token': 'stored-token'});
      await expectLater(api.sendCommand('players/all'), completes);
    });

    test('no token sends no auth, so a server without accounts sees no change', () async {
      final server = FakeMaServer();
      await apiFor(server).connect(baseUrl);

      expect(server.commands, isNot(contains('auth')));
    });

    test('a refused token leaves the socket up rather than reconnecting forever', () async {
      final server = FakeMaServer(responder: _AccountServer().respond);
      final api = apiFor(server);

      await api.connect(baseUrl, accessToken: 'revoked');

      expect(api.isConnected, isTrue);
      await expectLater(
        api.sendCommand('players/all'),
        throwsA(isA<MaRequestException>().having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );
    });
  });

  group('requiresSignIn', () {
    test('is true when the server refuses an unsigned socket', () async {
      final api = apiFor(FakeMaServer(responder: _AccountServer().respond));
      await api.connect(baseUrl);

      expect(await api.requiresSignIn(), isTrue);
    });

    test('is false once the token has been accepted', () async {
      final api = apiFor(FakeMaServer(responder: _AccountServer().respond));
      await api.connect(baseUrl, accessToken: 'stored-token');

      expect(await api.requiresSignIn(), isFalse);
    });

    test('is false on a server from before accounts, which has no auth/me', () async {
      final api = apiFor(FakeMaServer(responder: (_, _) => const MaErrorReply(12, 'Invalid command')));
      await api.connect(baseUrl);

      expect(await api.requiresSignIn(), isFalse);
    });
  });

  group('signIn', () {
    test('trades a password for a long-lived token, using the session to ask', () async {
      final server = FakeMaServer(responder: _AccountServer().respond);
      final api = apiFor(server);
      await api.connect(baseUrl);

      final token = await api.signIn(username: 'jack', password: 'right', tokenName: 'Plezy (iPhone)');

      // Not the session token: that one dies after 90 days however often it is
      // used, and the password is not kept to get another.
      expect(token, 'long-lived-token');
      expect(server.commands, ['auth/login', 'auth', 'auth/token/create']);
      expect(server.argsFor('auth/token/create'), {'name': 'Plezy (iPhone)'});
    });

    test('a wrong password is an auth failure, despite arriving as a success', () async {
      final api = apiFor(FakeMaServer(responder: _AccountServer().respond));
      await api.connect(baseUrl);

      await expectLater(
        api.signIn(username: 'jack', password: 'wrong', tokenName: 'Plezy'),
        throwsA(
          isA<MaRequestException>()
              .having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)
              .having((e) => e.message, 'message', 'Invalid username or password'),
        ),
      );
    });
  });

  group('the saved server', () {
    Future<MusicAssistantLink> linkFor(FakeMaServer server, {String? token}) async {
      final link = MusicAssistantLink(
        store: MemoryMusicAssistantConfigStore(),
        apiFactory: () => MusicAssistantApi(channelFactory: server.open, autoReconnect: false),
      );
      addTearDown(link.dispose);
      await link.save(
        MusicAssistantServerConfig(baseUrl: baseUrl.toString(), serverId: fakeMaServerId, accessToken: token),
      );
      return link;
    }

    test('a server that greets but refuses needs a sign-in', () async {
      final link = await linkFor(FakeMaServer(responder: _AccountServer().respond));

      expect(link.isConnected, isTrue);
      expect(link.needsSignIn, isTrue);
    });

    test('the stored token reaches the socket and nothing more is asked', () async {
      final link = await linkFor(FakeMaServer(responder: _AccountServer().respond), token: 'stored-token');

      expect(link.needsSignIn, isFalse);
    });

    test('any other refusal is not a reason to ask the user to sign in', () async {
      final link = await linkFor(FakeMaServer(responder: (_, _) => const MaErrorReply(17, 'Busy')));

      expect(link.needsSignIn, isFalse);
    });

    test('forgetting the server closes it and clears what was stored', () async {
      final store = MemoryMusicAssistantConfigStore();
      final server = FakeMaServer(responder: _AccountServer().respond);
      final link = MusicAssistantLink(
        store: store,
        apiFactory: () => MusicAssistantApi(channelFactory: server.open, autoReconnect: false),
      );
      addTearDown(link.dispose);
      await link.save(
        MusicAssistantServerConfig(baseUrl: baseUrl.toString(), serverId: fakeMaServerId, accessToken: 'stored-token'),
      );

      await link.forget();

      expect(link.api, isNull);
      expect(link.config, isNull);
      expect(store.value, isNull);
    });
  });
}
