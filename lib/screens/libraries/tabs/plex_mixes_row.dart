import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../services/plex_client.dart';
import '../../../theme/mono_tokens.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/optimized_media_image.dart';

/// Plex's "Mixes for you" for a music library: personal mixes the server
/// builds from listening history, each around one artist. Tapping one plays
/// it. Renders nothing when the server has none.
class PlexMixesRow extends StatefulWidget {
  const PlexMixesRow({super.key, required this.client, required this.libraryId});

  final PlexClient client;
  final String libraryId;

  @override
  State<PlexMixesRow> createState() => _PlexMixesRowState();
}

class _PlexMixesRowState extends State<PlexMixesRow> {
  static const double _cardWidth = 132;
  static const double _titleGap = 6;

  /// Two lines of card title at the reader's text size, with a little room
  /// for descenders.
  static double _titleHeight(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final fontSize = MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 14);
    return (fontSize * (style?.height ?? 1.43) * 2).ceilToDouble() + 4;
  }

  List<PlexMixForYou> _mixes = const [];
  String? _startingKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PlexMixesRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryId != widget.libraryId || !identical(oldWidget.client, widget.client)) _load();
  }

  Future<void> _load() async {
    try {
      final mixes = await widget.client.fetchMixesForYou(widget.libraryId);
      if (mounted) setState(() => _mixes = mixes);
    } catch (e) {
      // A row of extras: without it the tab is still whole.
      appLogger.w('Could not load mixes for library ${widget.libraryId}', error: e);
    }
  }

  Future<void> _play(PlexMixForYou mix) async {
    if (_startingKey != null) return;
    setState(() => _startingKey = mix.key);
    try {
      await playFetchedTracks(
        context,
        fetch: () => widget.client.fetchMixTracks(mix),
        playContext: MusicPlayContext(title: mix.title, kind: MusicPlayContextKind.mix),
        onError: (e, st) {
          appLogger.w('Could not start mix ${mix.title}', error: e, stackTrace: st);
          showErrorSnackBar(context, t.music.mixFailed);
        },
        onEmpty: () => showErrorSnackBar(context, t.music.mixEmpty),
      );
    } finally {
      if (mounted) setState(() => _startingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_mixes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: .start,
        mainAxisSize: .min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 8, 6),
            child: Row(
              children: [
                const AppIcon(Symbols.auto_awesome_rounded, fill: 1),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(t.music.mixesForYou, style: theme.textTheme.titleLarge, maxLines: 1, overflow: .ellipsis),
                ),
              ],
            ),
          ),
          SizedBox(
            height: _cardWidth + _titleGap + _titleHeight(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _mixes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => _MixCard(
                mix: _mixes[index],
                client: widget.client,
                width: _cardWidth,
                starting: _startingKey == _mixes[index].key,
                onTap: () => _play(_mixes[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MixCard extends StatelessWidget {
  const _MixCard({
    required this.mix,
    required this.client,
    required this.width,
    required this.starting,
    required this.onTap,
  });

  final PlexMixForYou mix;
  final PlexClient client;
  final double width;
  final bool starting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(tokens(context).radiusSm);
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: mix.title,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: .start,
            children: [
              ClipRRect(
                borderRadius: radius,
                child: Stack(
                  children: [
                    OptimizedMediaImage.poster(
                      client: client,
                      imagePath: mix.thumb,
                      width: width,
                      height: width,
                      fallbackIcon: Symbols.auto_awesome_rounded,
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
                            stops: const [0.55, 1],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: starting
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            )
                          : const AppIcon(Symbols.play_circle_rounded, fill: 1, size: 26, color: Colors.white),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: _PlexMixesRowState._titleGap),
              Text(mix.title, maxLines: 2, overflow: .ellipsis, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
