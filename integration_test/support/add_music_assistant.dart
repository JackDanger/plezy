import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/main.dart' as app;
import 'package:plezy/services/music_assistant/music_assistant_api.dart';
import 'package:plezy/services/music_assistant/music_assistant_link.dart';
import 'package:provider/provider.dart';

/// Pumps until [condition] holds or the budget runs out.
///
/// `pumpAndSettle` is unusable against this app: it holds continuous
/// animations and long-lived network work, so it never reaches a settled frame
/// and times out regardless of whether the thing being waited for arrived.
Future<bool> pumpUntilTrue(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (condition()) return true;
  }
  return false;
}

/// Make sure the app has a Music Assistant server to play to.
///
/// A device that already has one (set up in Settings > Playback > Speakers)
/// keeps it, sign-in and all. Otherwise [serverUrl] is probed for its id and
/// saved the way the settings screen saves it. Returns once the socket is up.
Future<MusicAssistantLink> ensureMusicAssistantServer(WidgetTester tester, {required String serverUrl}) async {
  final link = Provider.of<MusicAssistantLink>(tester.element(find.byType(Navigator).first), listen: false);
  await link.load();
  if (link.config == null) {
    final probe = MusicAssistantApi(autoReconnect: false);
    final info = await probe.connect(Uri.parse(serverUrl));
    await probe.dispose();
    await link.save(MusicAssistantServerConfig(baseUrl: serverUrl, serverId: info.serverId));
  }
  expect(
    await pumpUntilTrue(tester, () => link.isConnected, timeout: const Duration(seconds: 30)),
    isTrue,
    reason: 'never connected to the Music Assistant server at ${link.config?.baseUrl}',
  );
  expect(link.needsSignIn, isFalse, reason: 'the Music Assistant server wants a sign-in');
  return link;
}

/// Release the semantics handle `main()` takes in debug builds.
///
/// The app holds it so UI automation can see the accessibility tree, and the
/// test framework fails any test that leaves one alive — so every integration
/// test has to let it go. Eight of them carried the same two lines; the
/// duplication is the reason a change to it would have broken all eight.
void releaseDebugSemantics() {
  app.debugSemanticsHandle?.dispose();
  app.debugSemanticsHandle = null;
}
