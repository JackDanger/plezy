import '../../database/app_database.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../models/audio_quality_preset.dart';
import '../../models/transcode_quality_preset.dart';
import '../../utils/session_identifier.dart';
import '../multi_server_manager.dart';
import '../playback_initialization_service.dart';

/// Turns a track into something a *server* can fetch.
///
/// Separate from [MusicSourceResolver] because the constraints are different
/// in one decisive way: **Music Assistant cannot send custom HTTP headers.**
/// The local engine gets a URL plus Plex identity headers and opens it itself;
/// a Sonos is handed a bare URL and nothing else, so the URL has to
/// self-authenticate. Plex's `?X-Plex-Token=` query parameter does, which is
/// why a bare Plex URL plays on a Sonos with no matching, no resolver and no
/// second index — verified on real hardware.
abstract class RemoteTrackUrlResolver {
  Future<String> resolve(MediaItem track);
}

/// Production resolver.
///
/// ### Why this always asks for the original file
///
/// [ServerMusicSourceResolver] honours the user's music quality preset, which
/// is right for the phone: it is the thing with the small screen and the
/// metered connection. A speaker on the LAN is neither, and a transcode would
/// cost twice — Plex would open a transcode session that needs keep-alive
/// pings this code is in no position to send, and the speaker would get a
/// worse file than the one sitting on the NAS. Sonos plays FLAC natively.
class ServerRemoteTrackUrlResolver implements RemoteTrackUrlResolver {
  ServerRemoteTrackUrlResolver({required this.serverManager, required this.database});

  final MultiServerManager serverManager;
  final AppDatabase database;

  @override
  Future<String> resolve(MediaItem track) async {
    final serverId = serverIdOrNull(track.serverId);
    final client = serverId == null ? null : serverManager.getClient(serverId);
    if (client == null) {
      throw PlaybackException('No server for ${track.title ?? track.id}');
    }
    // Straight to the server rather than through PlaybackSourceResolver,
    // which prefers a downloaded copy at original quality: that copy is a
    // `file://` path on *this* device, which a speaker cannot open.
    final result = await PlaybackInitializationService(client: client, database: database).getPlaybackData(
      PlaybackInitializationOptions(
        metadata: track,
        selectedMediaIndex: 0,
        qualityPreset: TranscodeQualityPreset.original,
        audioQualityPreset: AudioQualityPreset.original,
        sessionIdentifier: generateSessionIdentifier(),
        transcodeSessionId: generateSessionIdentifier(),
      ),
    );

    final url = result.videoUrl;
    if (url == null) {
      throw PlaybackException('No streamable URL for ${track.title ?? track.id}');
    }
    if (url.startsWith('file:')) {
      throw PlaybackException('${track.title ?? track.id} is only available on this device');
    }
    return url;
  }
}
