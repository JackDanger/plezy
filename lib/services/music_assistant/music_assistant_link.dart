import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import '../../utils/app_logger.dart';
import '../../utils/log_redaction_manager.dart';
import '../credential_vault.dart';
import '../settings_service.dart';
import 'music_assistant_api.dart';

/// The Music Assistant server this device plays to.
class MusicAssistantServerConfig {
  /// `http://host:port`, no trailing slash.
  final String baseUrl;

  /// `server_id` from the server's greeting. Speaker ids are only unique
  /// within one server, so a chosen speaker is stored as `<serverId>|<playerId>`.
  final String serverId;

  /// Null when the server accepts commands without a sign-in.
  final String? accessToken;

  const MusicAssistantServerConfig({required this.baseUrl, required this.serverId, this.accessToken});

  Map<String, Object?> toJson() => {'baseUrl': baseUrl, 'serverId': serverId, 'accessToken': accessToken};

  static MusicAssistantServerConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    final baseUrl = json['baseUrl'];
    final serverId = json['serverId'];
    if (baseUrl is! String || baseUrl.isEmpty || serverId is! String || serverId.isEmpty) return null;
    final token = json['accessToken'];
    return MusicAssistantServerConfig(
      baseUrl: baseUrl,
      serverId: serverId,
      accessToken: token is String && token.isNotEmpty ? token : null,
    );
  }
}

/// Where the config lives. Separate so tests need no shared preferences.
abstract class MusicAssistantConfigStore {
  Future<MusicAssistantServerConfig?> read();
  Future<void> write(MusicAssistantServerConfig? config);
}

/// Keeps the config in [SettingsService], with the token encrypted by
/// [CredentialVault] like every other stored server credential.
class SettingsMusicAssistantConfigStore implements MusicAssistantConfigStore {
  SettingsMusicAssistantConfigStore({Future<SettingsService> Function()? settings, this.database})
    : _settings = settings ?? SettingsService.getInstance;

  final Future<SettingsService> Function() _settings;

  /// Earlier builds of this fork stored the server as a `music_assistant` row
  /// in the connections table. Given a database, [read] moves that row here
  /// once and deletes it.
  final AppDatabase? database;

  @override
  Future<MusicAssistantServerConfig?> read() async {
    final settings = await _settings();
    final raw = settings.read(SettingsService.musicAssistantServer);
    if (raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final token = json['accessToken'];
        if (token is String && token.isNotEmpty) json['accessToken'] = await CredentialVault.reveal(token);
        return MusicAssistantServerConfig.fromJson(json);
      } catch (e) {
        appLogger.w('Stored Music Assistant server is unreadable; forgetting it', error: e);
        await write(null);
        return null;
      }
    }
    return _importLegacyConnection();
  }

  @override
  Future<void> write(MusicAssistantServerConfig? config) async {
    final settings = await _settings();
    if (config == null) {
      await settings.write(SettingsService.musicAssistantServer, '');
      return;
    }
    final token = config.accessToken;
    final json = config.toJson()..['accessToken'] = token == null ? null : await CredentialVault.protect(token);
    await settings.write(SettingsService.musicAssistantServer, jsonEncode(json));
  }

  Future<MusicAssistantServerConfig?> _importLegacyConnection() async {
    final db = database;
    if (db == null) return null;
    try {
      final rows = await (db.select(db.connections)..where((c) => c.kind.equals('music_assistant'))).get();
      if (rows.isEmpty) return null;
      MusicAssistantServerConfig? imported;
      for (final row in rows) {
        final json = jsonDecode(row.configJson) as Map<String, dynamic>;
        final token = json['accessToken'];
        if (token is String && token.isNotEmpty) json['accessToken'] = await CredentialVault.reveal(token);
        imported ??= MusicAssistantServerConfig.fromJson(json);
      }
      if (imported != null) await write(imported);
      // Profile bindings go with them (ON DELETE CASCADE).
      await (db.delete(db.connections)..where((c) => c.kind.equals('music_assistant'))).go();
      appLogger.i('Moved the Music Assistant server out of the connections table');
      return imported;
    } catch (e, st) {
      appLogger.w('Could not import the old Music Assistant connection', error: e, stackTrace: st);
      return null;
    }
  }
}

/// The app's one connection to a Music Assistant server, used only to play to
/// its speakers. Music Assistant is not a media server here: the music always
/// comes from Plex (or Jellyfin/Emby), and the server is just told what to play
/// and where.
///
/// Notifies when the server is set, forgotten, connects or drops.
class MusicAssistantLink extends ChangeNotifier {
  MusicAssistantLink({required this._store, MusicAssistantApi Function()? apiFactory})
    : _apiFactory = apiFactory ?? MusicAssistantApi.new;

  final MusicAssistantConfigStore _store;
  final MusicAssistantApi Function() _apiFactory;

  MusicAssistantServerConfig? _config;
  MusicAssistantApi? _api;
  StreamSubscription<MaConnectionState>? _stateSubscription;
  bool _authRejected = false;
  bool _disposed = false;
  Future<void>? _loading;

  MusicAssistantServerConfig? get config => _config;

  /// The open socket, or null when no server is set.
  MusicAssistantApi? get api => _api;

  bool get isConnected => _api?.isConnected ?? false;

  /// The server refused the stored token (or wants one and none is stored).
  bool get needsSignIn => _authRejected;

  /// Read the stored server and connect to it. Safe to call more than once.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final config = await _store.read();
      if (config != null && !_disposed) await _open(config);
    } catch (e, st) {
      appLogger.w('Could not load the Music Assistant server', error: e, stackTrace: st);
    }
  }

  /// Use [config] from now on.
  Future<void> save(MusicAssistantServerConfig config) async {
    await _store.write(config);
    await _open(config);
  }

  /// Stop using any Music Assistant server.
  Future<void> forget() async {
    await _store.write(null);
    await _close();
    _config = null;
    _authRejected = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> _open(MusicAssistantServerConfig config) async {
    await _close();
    if (_disposed) return;
    // Before anything about this server can reach the log.
    LogRedactionManager.registerServer(config.baseUrl, config.accessToken);
    _config = config;
    _authRejected = false;
    final api = _apiFactory();
    _api = api;
    _stateSubscription = api.connectionStates.listen((_) {
      if (!_disposed) notifyListeners();
    });
    notifyListeners();
    try {
      await api.connect(Uri.parse(config.baseUrl), accessToken: config.accessToken);
      if (identical(api, _api) && await api.requiresSignIn()) {
        _authRejected = true;
      }
    } on MaRequestException catch (e) {
      if (e.isAuthFailure) _authRejected = true;
      appLogger.w('Music Assistant refused the connection', error: e);
    } on MaException catch (e) {
      // The API keeps retrying in the background.
      appLogger.w('Music Assistant is not reachable yet', error: e);
    }
    if (!_disposed && identical(api, _api)) notifyListeners();
  }

  Future<void> _close() async {
    final api = _api;
    _api = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    if (api != null) await api.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_close());
    super.dispose();
  }
}
