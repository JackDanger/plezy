import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:os_media_controls/os_media_controls.dart';

import '../client/plex_client.dart';
import '../models/plex_metadata.dart';
import '../services/audio_playback_initialization_service.dart';
import '../services/media_controls_manager.dart';
import '../services/playback_progress_tracker.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/provider_extensions.dart';
import '../utils/duration_formatter.dart' show formatDurationTimestamp;
import '../widgets/desktop_app_bar.dart';
import '../widgets/app_bar_back_button.dart';
import '../theme/theme_helper.dart' show tokens;
import '../i18n/strings.g.dart';

class AudioPlayerScreen extends StatefulWidget {
  final PlexMetadata metadata;

  const AudioPlayerScreen({
    super.key,
    required this.metadata,
  });

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen>
    with WidgetsBindingObserver {
  Player? player;
  bool _isPlayerInitialized = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 100.0;
  PlexMetadata? _fullMetadata;
  bool _isLoadingMetadata = true;

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<dynamic>? _mediaControlSubscription;
  StreamSubscription<bool>? _bufferingSubscription;

  MediaControlsManager? _mediaControlsManager;
  PlaybackProgressTracker? _progressTracker;
  Timer? _progressTimer;

  /// Get the correct PlexClient for this metadata's server
  PlexClient _getClientForMetadata(BuildContext context) {
    return context.getClientForServer(widget.metadata.serverId!);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFullMetadata();
    _initializePlayer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _mediaControlSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _progressTracker?.stopTracking();
    _progressTimer?.cancel();
    _mediaControlsManager?.dispose();
    player?.dispose();
    super.dispose();
  }

  Future<void> _loadFullMetadata() async {
    setState(() {
      _isLoadingMetadata = true;
    });

    try {
      final client = _getClientForMetadata(context);
      final metadata = await client.getMetadataWithImages(
        widget.metadata.ratingKey,
      );

      if (metadata != null) {
        final metadataWithServerId = metadata.copyWith(
          serverId: widget.metadata.serverId,
          serverName: widget.metadata.serverName,
        );

        setState(() {
          _fullMetadata = metadataWithServerId;
          _isLoadingMetadata = false;
        });
      } else {
        setState(() {
          _fullMetadata = widget.metadata;
          _isLoadingMetadata = false;
        });
      }
    } catch (e) {
      setState(() {
        _fullMetadata = widget.metadata;
        _isLoadingMetadata = false;
      });
    }
  }

  Future<void> _initializePlayer() async {
    try {
      final settingsService = await SettingsService.getInstance();
      final bufferSizeMB = settingsService.getBufferSize();
      final bufferSizeBytes = bufferSizeMB * 1024 * 1024;
      final debugLoggingEnabled = settingsService.getEnableDebugLogging();

      // Create player with configuration
      player = Player(
        configuration: PlayerConfiguration(
          bufferSize: bufferSizeBytes,
          logLevel: debugLoggingEnabled ? MPVLogLevel.debug : MPVLogLevel.error,
        ),
      );

      // Apply saved volume
      final savedVolume = settingsService.getVolume();
      player!.setVolume(savedVolume);
      _volume = savedVolume;

      // Notify that player is ready
      if (mounted) {
        setState(() {
          _isPlayerInitialized = true;
        });
      }

      // Start playback
      await _startPlayback();

      // Set up media controls
      await _setupMediaControls();

      // Listen to playback state changes
      _playingSubscription = player!.stream.playing.listen((playing) {
        if (mounted) {
          setState(() {
            _isPlaying = playing;
          });
        }
        _updateMediaControlsPlaybackState();
      });

      // Listen to position updates
      _positionSubscription = player!.stream.position.listen((position) {
        if (mounted) {
          setState(() {
            _position = position;
          });
        }
        _updateMediaControlsPlaybackState();
      });

      // Listen to duration updates
      _durationSubscription = player!.stream.duration.listen((duration) {
        if (mounted) {
          setState(() {
            _duration = duration;
          });
        }
      });

      // Listen to completion
      player!.stream.completed.listen((completed) {
        if (completed && mounted) {
          _onTrackCompleted();
        }
      });

      // Start progress tracking
      final client = _getClientForMetadata(context);
      _progressTracker = PlaybackProgressTracker(
        client: client,
        metadata: _fullMetadata ?? widget.metadata,
        player: player!,
      );
      _progressTracker!.startTracking();
    } catch (e) {
      appLogger.e('Failed to initialize audio player', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start playback: $e')),
        );
      }
    }
  }

  Future<void> _startPlayback() async {
    try {
      final client = _getClientForMetadata(context);
      final initializationService = AudioPlaybackInitializationService(
        player: player!,
        client: client,
        context: context,
      );

      await initializationService.startPlayback(
        metadata: _fullMetadata ?? widget.metadata,
      );
    } catch (e) {
      appLogger.e('Failed to start playback', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start playback: $e')),
        );
      }
    }
  }

  Future<void> _setupMediaControls() async {
    final client = _getClientForMetadata(context);
    _mediaControlsManager = MediaControlsManager();

    // Listen to media control events
    _mediaControlSubscription = _mediaControlsManager!.controlEvents.listen((event) {
      if (event is PlayEvent) {
        player?.play();
      } else if (event is PauseEvent) {
        player?.pause();
      } else if (event is SeekEvent) {
        player?.seek(event.position);
      }
    });

    // Update media metadata
    await _mediaControlsManager!.updateMetadata(
      metadata: _fullMetadata ?? widget.metadata,
      client: client,
      duration: widget.metadata.duration != null
          ? Duration(milliseconds: widget.metadata.duration!)
          : null,
    );

    if (!mounted) return;

    await _mediaControlsManager!.setControlsEnabled(
      canGoNext: false,
      canGoPrevious: false,
    );

    // Listen to playing state and update media controls
    player!.stream.playing.listen((isPlaying) {
      _updateMediaControlsPlaybackState();
    });

    // Listen to position updates for media controls
    player!.stream.position.listen((position) {
      _mediaControlsManager?.updatePlaybackState(
        isPlaying: player!.state.playing,
        position: position,
        speed: player!.state.rate,
      );
    });
  }

  void _updateMediaControlsPlaybackState() {
    _mediaControlsManager?.updatePlaybackState(
      isPlaying: _isPlaying,
      position: _position,
      speed: player?.state.rate ?? 1.0,
    );
  }

  void _onTrackCompleted() {
    // Mark as played and send final progress
    _progressTracker?.sendProgress('stopped');
    _progressTracker?.stopTracking();
    
    // Navigate back
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 600;
    final client = _getClientForMetadata(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(_fullMetadata?.title ?? widget.metadata.title),
        leading: AppBarBackButton(),
      ),
      body: _isPlayerInitialized && !_isLoadingMetadata
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Album art
                    if (_fullMetadata?.thumb != null ||
                        _fullMetadata?.art != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CachedNetworkImage(
                          imageUrl: client.getThumbnailUrl(
                            _fullMetadata!.thumb ?? _fullMetadata!.art!,
                          ),
                          width: isDesktop ? 400 : 300,
                          height: isDesktop ? 400 : 300,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            width: isDesktop ? 400 : 300,
                            height: isDesktop ? 400 : 300,
                            color: theme.cardColor,
                            child: const Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            width: isDesktop ? 400 : 300,
                            height: isDesktop ? 400 : 300,
                            color: theme.cardColor,
                            child: Icon(
                              Icons.music_note,
                              size: 100,
                              color: theme.disabledColor,
                            ),
                          ),
                        ),
                      )
                    else
                      Container(
                        width: isDesktop ? 400 : 300,
                        height: isDesktop ? 400 : 300,
                        decoration: BoxDecoration(
                          color: theme.cardColor,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.music_note,
                          size: 100,
                          color: theme.disabledColor,
                        ),
                      ),
                    const SizedBox(height: 32),
                    // Track info
                    Text(
                      _fullMetadata?.title ?? widget.metadata.title,
                      style: theme.textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (_fullMetadata?.parentTitle != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _fullMetadata!.parentTitle!,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.disabledColor,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 32),
                    // Progress bar
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Column(
                        children: [
                          Slider(
                            value: _duration.inMilliseconds > 0
                                ? _position.inMilliseconds /
                                    _duration.inMilliseconds
                                : 0.0,
                            onChanged: (value) {
                              final newPosition = Duration(
                                milliseconds: (value *
                                        _duration.inMilliseconds)
                                    .round(),
                              );
                              player?.seek(newPosition);
                            },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                formatDurationTimestamp(_position),
                                style: theme.textTheme.bodySmall,
                              ),
                              Text(
                                formatDurationTimestamp(_duration),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Controls
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Volume down
                        IconButton(
                          icon: const Icon(Icons.volume_down),
                          onPressed: () {
                            final newVolume = (_volume - 10).clamp(0.0, 100.0);
                            player?.setVolume(newVolume);
                            setState(() {
                              _volume = newVolume;
                            });
                          },
                          iconSize: 32,
                        ),
                        const SizedBox(width: 16),
                        // Play/Pause
                        IconButton(
                          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                          onPressed: () {
                            if (_isPlaying) {
                              player?.pause();
                            } else {
                              player?.play();
                            }
                          },
                          iconSize: 64,
                        ),
                        const SizedBox(width: 16),
                        // Volume up
                        IconButton(
                          icon: const Icon(Icons.volume_up),
                          onPressed: () {
                            final newVolume = (_volume + 10).clamp(0.0, 100.0);
                            player?.setVolume(newVolume);
                            setState(() {
                              _volume = newVolume;
                            });
                          },
                          iconSize: 32,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

