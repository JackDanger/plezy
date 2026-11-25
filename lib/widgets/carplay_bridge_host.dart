import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../providers/multi_server_provider.dart';
import '../services/carplay_bridge.dart';
import '../services/music/music_playback_service.dart';

/// Runs the [CarPlayBridge] for as long as a profile session is up, on iOS.
///
/// Per profile session because that is where the music session lives: a
/// profile switch replaces it, and the car must follow the new one.
class CarPlayBridgeHost extends StatefulWidget {
  const CarPlayBridgeHost({super.key, required this.child});

  final Widget child;

  @override
  State<CarPlayBridgeHost> createState() => _CarPlayBridgeHostState();
}

class _CarPlayBridgeHostState extends State<CarPlayBridgeHost> {
  CarPlayBridge? _bridge;

  @override
  void initState() {
    super.initState();
    if (kIsWeb || !Platform.isIOS) return;
    final servers = context.read<MultiServerProvider>().serverManager;
    _bridge = CarPlayBridge(clients: () => servers.visibleOnlineClients, music: context.read<MusicPlaybackService>())
      ..start();
  }

  @override
  void dispose() {
    _bridge?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
