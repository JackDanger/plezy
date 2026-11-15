import 'package:plezy/services/music_assistant/music_assistant_api.dart';
import 'package:plezy/services/music_assistant/music_assistant_link.dart';

import 'fake_ma_server.dart';

/// The server id [FakeMaServer] greets with.
const fakeMaServerId = 'fe2f5b6fd78e4608bb8b075a6c269fbf';

class MemoryMusicAssistantConfigStore implements MusicAssistantConfigStore {
  MemoryMusicAssistantConfigStore([this.value]);

  MusicAssistantServerConfig? value;

  @override
  Future<MusicAssistantServerConfig?> read() async => value;

  @override
  Future<void> write(MusicAssistantServerConfig? config) async => value = config;
}

/// A link with no server set.
MusicAssistantLink emptyTestLink() => MusicAssistantLink(store: MemoryMusicAssistantConfigStore());

/// A link connected to [server].
Future<MusicAssistantLink> connectedTestLink(FakeMaServer server) async {
  final link = MusicAssistantLink(
    store: MemoryMusicAssistantConfigStore(),
    apiFactory: () => MusicAssistantApi(channelFactory: server.open, autoReconnect: false),
  );
  await link.save(const MusicAssistantServerConfig(baseUrl: 'http://10.0.2.107:8095', serverId: fakeMaServerId));
  return link;
}
