import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../client/plex_client.dart';
import '../widgets/focus/focus_indicator.dart';
import '../models/plex_metadata.dart';
import '../utils/keyboard_utils.dart';
import '../utils/provider_extensions.dart';
import '../utils/duration_formatter.dart' show formatDurationTimestamp;
import '../widgets/desktop_app_bar.dart';
import '../widgets/app_bar_back_button.dart';
import '../widgets/media_context_menu.dart';
import '../mixins/item_updatable.dart';
import '../mixins/keyboard_long_press_mixin.dart';
import '../theme/theme_helper.dart' show tokens;
import '../i18n/strings.g.dart';
import '../utils/video_player_navigation.dart' show navigateToAudioPlayer;

class AlbumDetailScreen extends StatefulWidget {
  final PlexMetadata album;

  const AlbumDetailScreen({super.key, required this.album});

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen>
    with ItemUpdatable {
  late final PlexClient _client;

  @override
  PlexClient get client => _client;

  List<PlexMetadata> _tracks = [];
  bool _isLoadingTracks = false;
  PlexMetadata? _fullMetadata;
  bool _isLoadingMetadata = true;
  final FocusNode _firstTrackFocusNode = FocusNode(
    debugLabel: 'FirstTrack',
  );

  /// Get the correct PlexClient for this album's server
  PlexClient _getClientForAlbum(BuildContext context) {
    return context.getClientForServer(widget.album.serverId!);
  }

  @override
  void initState() {
    super.initState();
    // Initialize the client once in initState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _client = _getClientForAlbum(context);
      _loadFullMetadata();
      _loadTracks();
    });
  }

  @override
  void dispose() {
    _firstTrackFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadFullMetadata() async {
    setState(() {
      _isLoadingMetadata = true;
    });

    try {
      final metadata = await _client.getMetadataWithImages(
        widget.album.ratingKey,
      );

      if (metadata != null) {
        final metadataWithServerId = metadata.copyWith(
          serverId: widget.album.serverId,
          serverName: widget.album.serverName,
        );

        setState(() {
          _fullMetadata = metadataWithServerId;
          _isLoadingMetadata = false;
        });
      } else {
        setState(() {
          _fullMetadata = widget.album;
          _isLoadingMetadata = false;
        });
      }
    } catch (e) {
      setState(() {
        _fullMetadata = widget.album;
        _isLoadingMetadata = false;
      });
    }
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoadingTracks = true;
    });

    try {
      // Tracks are automatically tagged with server info by PlexClient
      final tracks = await _client.getChildren(widget.album.ratingKey);

      setState(() {
        _tracks = tracks;
        _isLoadingTracks = false;
      });

      // Focus the first track after loading
      if (tracks.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _firstTrackFocusNode.requestFocus();
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingTracks = false;
      });
    }
  }

  @override
  Future<void> updateItem(String ratingKey) async {
    await super.updateItem(ratingKey);
  }

  @override
  void updateItemInLists(String ratingKey, PlexMetadata updatedMetadata) {
    final index = _tracks.indexWhere((item) => item.ratingKey == ratingKey);
    if (index != -1) {
      _tracks[index] = updatedMetadata;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 600;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(_fullMetadata?.title ?? widget.album.title),
        leading: AppBarBackButton(),
      ),
      body: _isLoadingMetadata
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await Future.wait([
                  _loadFullMetadata(),
                  _loadTracks(),
                ]);
              },
              child: CustomScrollView(
                slivers: [
                  // Album header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Album artwork
                          if (_fullMetadata?.thumb != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: _client.getThumbnailUrl(_fullMetadata!.thumb!),
                                width: isDesktop ? 300.0 : 200.0,
                                height: isDesktop ? 300.0 : 200.0,
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Container(
                                  width: isDesktop ? 300 : 200,
                                  height: isDesktop ? 300 : 200,
                                  color: theme.cardColor,
                                  child: const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  width: isDesktop ? 300 : 200,
                                  height: isDesktop ? 300 : 200,
                                  color: theme.cardColor,
                                  child: Icon(
                                    Icons.album,
                                    size: 64,
                                    color: theme.disabledColor,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(width: 16),
                          // Album info
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _fullMetadata?.title ?? widget.album.title,
                                  style: theme.textTheme.headlineMedium,
                                ),
                                if (_fullMetadata?.parentTitle != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    _fullMetadata!.parentTitle!,
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      color: theme.disabledColor,
                                    ),
                                  ),
                                ],
                                if (_fullMetadata?.year != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    _fullMetadata!.year.toString(),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.disabledColor,
                                    ),
                                  ),
                                ],
                                if (_fullMetadata?.summary != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    _fullMetadata!.summary!,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Tracks section
                  SliverPadding(
                    padding: const EdgeInsets.all(16.0),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        t.libraries.groupings.tracks,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  if (_isLoadingTracks)
                    const SliverToBoxAdapter(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(32.0),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    )
                  else if (_tracks.isEmpty)
                    SliverToBoxAdapter(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32.0),
                          child: Text(
                            t.messages.noEpisodesFoundGeneral,
                            style: theme.textTheme.bodyLarge,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final track = _tracks[index];
                          final isFirst = index == 0;
                          return _TrackCard(
                            track: track,
                            client: _client,
                            focusNode: isFirst ? _firstTrackFocusNode : null,
                            onTap: () async {
                              await navigateToAudioPlayer(
                                context,
                                metadata: track,
                              );
                              // Refresh tracks when returning from audio player
                              _loadTracks();
                            },
                            onRefresh: updateItem,
                          );
                        },
                        childCount: _tracks.length,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Focusable track card widget
class _TrackCard extends StatefulWidget {
  final PlexMetadata track;
  final PlexClient client;
  final VoidCallback onTap;
  final Future<void> Function(String) onRefresh;
  final FocusNode? focusNode;

  const _TrackCard({
    required this.track,
    required this.client,
    required this.onTap,
    required this.onRefresh,
    this.focusNode,
  });

  @override
  State<_TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends State<_TrackCard> with KeyboardLongPressMixin {
  FocusNode? _internalFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());
  bool _isFocused = false;
  final _contextMenuKey = GlobalKey<MediaContextMenuState>();

  @override
  void onKeyboardTap() => widget.onTap();

  @override
  void onKeyboardLongPress() {
    _contextMenuKey.currentState?.showContextMenu(context);
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_isFocused != _focusNode.hasFocus) {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
      if (_focusNode.hasFocus) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final theme = Theme.of(context);

    return MediaContextMenu(
      key: _contextMenuKey,
      item: track,
      onRefresh: widget.onRefresh,
      onTap: widget.onTap,
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: (node, event) {
          if (isBackKeyEvent(event)) {
            Navigator.pop(context);
            return KeyEventResult.handled;
          }
          return handleKeyboardLongPress(event);
        },
        child: FocusIndicator(
          isFocused: _isFocused,
          borderRadius: 8,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListTile(
            leading: track.index != null
                ? SizedBox(
                    width: 40,
                    child: Center(
                      child: Text(
                        track.index.toString(),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.disabledColor,
                        ),
                      ),
                    ),
                  )
                : const SizedBox(width: 40),
            title: Text(
              track.title,
              style: theme.textTheme.bodyLarge,
            ),
            subtitle: track.duration != null
                ? Text(
                    formatDurationTimestamp(Duration(milliseconds: track.duration!)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                  )
                : null,
            trailing: Icon(
              Icons.play_arrow,
              color: theme.iconTheme.color,
            ),
            onTap: widget.onTap,
            ),
          ),
        ),
      ),
    );
  }
}

