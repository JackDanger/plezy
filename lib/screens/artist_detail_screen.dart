import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../client/plex_client.dart';
import '../widgets/focus/focus_indicator.dart';
import '../models/plex_metadata.dart';
import '../utils/keyboard_utils.dart';
import '../utils/provider_extensions.dart';
import '../utils/duration_formatter.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/app_bar_back_button.dart';
import '../widgets/media_context_menu.dart';
import '../mixins/item_updatable.dart';
import '../mixins/keyboard_long_press_mixin.dart';
import '../theme/theme_helper.dart' show tokens;
import '../i18n/strings.g.dart';
import '../widgets/media_card.dart';
import 'album_detail_screen.dart';

class ArtistDetailScreen extends StatefulWidget {
  final PlexMetadata artist;

  const ArtistDetailScreen({super.key, required this.artist});

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen>
    with ItemUpdatable {
  late final PlexClient _client;

  @override
  PlexClient get client => _client;

  List<PlexMetadata> _albums = [];
  bool _isLoadingAlbums = false;
  PlexMetadata? _fullMetadata;
  bool _isLoadingMetadata = true;
  final FocusNode _firstAlbumFocusNode = FocusNode(
    debugLabel: 'FirstAlbum',
  );

  /// Get the correct PlexClient for this artist's server
  PlexClient _getClientForArtist(BuildContext context) {
    return context.getClientForServer(widget.artist.serverId!);
  }

  @override
  void initState() {
    super.initState();
    // Initialize the client once in initState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _client = _getClientForArtist(context);
      _loadFullMetadata();
      _loadAlbums();
    });
  }

  @override
  void dispose() {
    _firstAlbumFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadFullMetadata() async {
    setState(() {
      _isLoadingMetadata = true;
    });

    try {
      final metadata = await _client.getMetadataWithImages(
        widget.artist.ratingKey,
      );

      if (metadata != null) {
        final metadataWithServerId = metadata.copyWith(
          serverId: widget.artist.serverId,
          serverName: widget.artist.serverName,
        );

        setState(() {
          _fullMetadata = metadataWithServerId;
          _isLoadingMetadata = false;
        });
      } else {
        setState(() {
          _fullMetadata = widget.artist;
          _isLoadingMetadata = false;
        });
      }
    } catch (e) {
      setState(() {
        _fullMetadata = widget.artist;
        _isLoadingMetadata = false;
      });
    }
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _isLoadingAlbums = true;
    });

    try {
      // Albums are automatically tagged with server info by PlexClient
      final albums = await _client.getChildren(widget.artist.ratingKey);

      setState(() {
        _albums = albums;
        _isLoadingAlbums = false;
      });

      // Focus the first album after loading
      if (albums.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _firstAlbumFocusNode.requestFocus();
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingAlbums = false;
      });
    }
  }

  @override
  void updateItemInLists(String ratingKey, PlexMetadata updatedMetadata) {
    final index = _albums.indexWhere((item) => item.ratingKey == ratingKey);
    if (index != -1) {
      _albums[index] = updatedMetadata;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 600;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (isBackKeyEvent(event)) {
            Navigator.pop(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: _isLoadingMetadata
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () async {
                  await Future.wait([
                    _loadFullMetadata(),
                    _loadAlbums(),
                  ]);
                },
                child: CustomScrollView(
                slivers: [
                  DesktopSliverAppBar(
                    pinned: true,
                    leading: AppBarBackButton(
                      style: BackButtonStyle.circular,
                    ),
                    title: Text(_fullMetadata?.title ?? widget.artist.title),
                  ),
                  // Artist header
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Artist artwork
                          if (_fullMetadata?.art != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: _client.getThumbnailUrl(_fullMetadata!.art!),
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
                                    Icons.music_note,
                                    size: 64,
                                    color: theme.disabledColor,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(width: 16),
                          // Artist info
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _fullMetadata?.title ?? widget.artist.title,
                                  style: theme.textTheme.headlineMedium,
                                ),
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
                  // Albums section
                  SliverPadding(
                    padding: const EdgeInsets.all(16.0),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        t.libraries.groupings.albums,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  if (_isLoadingAlbums)
                    const SliverToBoxAdapter(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(32.0),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    )
                  else if (_albums.isEmpty)
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
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: isDesktop ? 300 : 200,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.7,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final album = _albums[index];
                            final isFirst = index == 0;
                            return MediaCard(
                              item: album,
                              focusNode: isFirst ? _firstAlbumFocusNode : null,
                              onRefresh: (ratingKey) {
                                _loadAlbums();
                              },
                            );
                          },
                          childCount: _albums.length,
                        ),
                      ),
                    ),
                ],
              ),
            ),
      ),
    );
  }
}

