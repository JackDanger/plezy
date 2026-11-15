/// Plain data models for the Music Assistant WebSocket API.
///
/// Hand-written rather than code-generated: the server is loosely typed (a
/// `volume_level` observed as `null` on a registered player, `metadata.images`
/// absent on nested items) and every parser here has to tolerate that without a
/// build step. See `docs/music_assistant_protocol.md`.
library;

import '../../utils/json_utils.dart';

/// Greeting frame the server pushes unsolicited immediately after the socket
/// opens, before any command is sent.
/// Only the four fields anything reads. The greeting also carries
/// `min_supported_schema_version`, `homeassistant_addon` and `onboard_done`;
/// they are left unparsed rather than parsed and ignored, so a field appearing
/// here means something depends on it.
class MaServerInfo {
  final String serverId;
  final String serverVersion;
  final int schemaVersion;

  /// Server-advertised HTTP base, e.g. `http://10.0.2.107:8095`. May be empty.
  final String baseUrl;

  const MaServerInfo({
    required this.serverId,
    required this.serverVersion,
    required this.schemaVersion,
    required this.baseUrl,
  });

  factory MaServerInfo.fromJson(Map<String, dynamic> json) => MaServerInfo(
    serverId: json['server_id']?.toString() ?? '',
    serverVersion: json['server_version']?.toString() ?? '',
    schemaVersion: flexibleInt(json['schema_version']) ?? 0,
    baseUrl: json['base_url']?.toString() ?? '',
  );

  @override
  String toString() => 'MaServerInfo($serverVersion, schema $schemaVersion)';
}
