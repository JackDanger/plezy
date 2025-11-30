import 'dart:async';

/// Notifier for triggering refreshes of library tabs and screens
/// Singleton pattern for global access
class LibraryRefreshNotifier {
  static final LibraryRefreshNotifier _instance =
      LibraryRefreshNotifier._internal();

  factory LibraryRefreshNotifier() => _instance;

  LibraryRefreshNotifier._internal();

  // Stream controllers for different tab types
  final _collectionsController = StreamController<void>.broadcast();
  final _playlistsController = StreamController<void>.broadcast();

  // Stream controller for when a server comes back online
  // Screens can listen to this to refresh their content and include the new server's data
  final _serverCameOnlineController = StreamController<String>.broadcast();

  // Stream controller for general library list refresh (e.g., when libraries should be reloaded)
  final _librariesChangedController = StreamController<void>.broadcast();

  // Streams that tabs can listen to
  Stream<void> get collectionsStream => _collectionsController.stream;
  Stream<void> get playlistsStream => _playlistsController.stream;
  Stream<String> get serverCameOnlineStream => _serverCameOnlineController.stream;
  Stream<void> get librariesChangedStream => _librariesChangedController.stream;

  // Methods to trigger refreshes
  void notifyCollectionsChanged() {
    if (!_collectionsController.isClosed) {
      _collectionsController.add(null);
    }
  }

  void notifyPlaylistsChanged() {
    if (!_playlistsController.isClosed) {
      _playlistsController.add(null);
    }
  }

  /// Notify that a server has come back online
  /// [serverId] is the ID of the server that reconnected
  void notifyServerCameOnline(String serverId) {
    if (!_serverCameOnlineController.isClosed) {
      _serverCameOnlineController.add(serverId);
    }
    // Also trigger a general libraries refresh
    notifyLibrariesChanged();
  }

  /// Notify that the library list should be refreshed
  /// (e.g., when a server comes online or libraries are added/removed)
  void notifyLibrariesChanged() {
    if (!_librariesChangedController.isClosed) {
      _librariesChangedController.add(null);
    }
  }

  // Cleanup
  void dispose() {
    _collectionsController.close();
    _playlistsController.close();
    _serverCameOnlineController.close();
    _librariesChangedController.close();
  }
}
