import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../music_assistant/music_assistant_api.dart';
import '../music_assistant/music_assistant_link.dart';
import '../music_assistant/music_assistant_players.dart';
import '../settings_service.dart';
import 'music_output.dart';
import '../../i18n/strings.g.dart';

/// The `players/*` handle for the server that owns [output].
///
/// Throws [StateError] when that server is not connected — a real state (the
/// user forgot the server while a speaker was selected) that the caller must
/// not paper over by playing on the phone instead without saying so.
MusicAssistantPlayers musicAssistantPlayersFor(MusicAssistantLink link, MusicOutput output) {
  final api = link.api;
  if (output.serverId == null || api == null || link.config?.serverId != output.serverId) {
    throw StateError('The Music Assistant server behind ${output.name} is not connected');
  }
  return MusicAssistantPlayers(api);
}

/// Discovers every output the user could play to, and remembers which one they
/// chose.
///
/// ### Why the phone wins a tie
///
/// With no stored choice this stays on the phone. Preferring a speaker was
/// tried and was wrong in three ways at once: the speaker picked is whichever
/// discovery returned first, so it is arbitrary; the app then mirrors that
/// player's queue, which reports `playing` for audio this session never sent
/// and leaves `currentTrack` null; and tapping a track sends it to a room the
/// listener may not be in.
///
/// The device in someone's hand is the only output they are certainly present
/// for. A speaker is a deliberate choice, and the stored choice always wins.
///
/// ### Fan-out
///
/// One `players/all` per refresh, serialized. The Music Assistant socket
/// wedges under concurrent load, so refreshes run one at a time.
class MusicOutputController extends ChangeNotifier {
  /// Earlier builds registered this device as a player, and servers remember it.
  static const String _staleOwnPlayerPrefix = 'ma_plezy_';

  MusicOutputController({required this.link, Future<SettingsService> Function()? settingsLoader})
    : _settingsLoader = settingsLoader ?? SettingsService.getInstance;

  final MusicAssistantLink link;
  final Future<SettingsService> Function() _settingsLoader;

  bool _started = false;

  /// The socket [_playerSubscription] listens on, so a new socket gets a new
  /// subscription.
  MusicAssistantApi? _watchedApi;
  StreamSubscription<void>? _playerSubscription;

  /// The last list the server actually answered with, keyed by server id.
  ///
  /// A server that cannot be asked right now — its socket dropped, or
  /// `players/all` failed — would otherwise contribute nothing, so its rooms
  /// would vanish. [_reconcileSelection] would then read the chosen speaker as
  /// gone and fall back to the phone, stopping the remote engine while the
  /// audio carries on in the room. Remembering what the server last said turns
  /// a momentary silence into a silence instead of a removal.
  final Map<String, List<MusicOutput>> _lastKnownByServer = {};

  List<MusicOutput> _outputs = const [MusicOutput.thisDevice];
  List<MusicOutput> _groupableRooms = const [];
  MusicOutput _selected = MusicOutput.thisDevice;
  bool _restored = false;
  bool _disposed = false;
  Future<void>? _pendingRefresh;
  Timer? _debounce;

  /// Every output, local first, then remote players in server order.
  ///
  /// Includes unavailable ones: see [MusicOutput.unavailableReason].
  List<MusicOutput> get outputs => List.unmodifiable(_outputs);

  /// Rooms that can be put in a sync group together.
  ///
  /// Not a subset of [outputs]. A room already in a group is hidden there,
  /// because the group is the destination, but is exactly what someone changing
  /// the group needs to see.
  List<MusicOutput> get groupableRooms => List.unmodifiable(_groupableRooms);

  /// Outputs that can actually be played to right now.
  List<MusicOutput> get playableOutputs => _outputs.where((output) => output.available).toList(growable: false);

  MusicOutput get selected => _selected;

  /// True once a remote player has been seen, i.e. the picker is worth showing.
  bool get hasRemoteOutputs => _outputs.any((output) => output.isRemote);

  /// Begin watching the server and its players.
  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    link.addListener(_requestRefresh);
    await _restoreSelection();
    await refresh();
  }

  /// Re-read the player list from the Music Assistant server.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    _pendingRefresh = (_pendingRefresh ?? Future<void>.value()).then((_) => _refresh());
    return _pendingRefresh!;
  }

  /// Coalesce bursts: a group change emits a run of `player_updated` events and
  /// re-reading the whole list for each one is exactly the fan-out that wedges
  /// the server.
  void _requestRefresh() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => unawaited(refresh()));
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    final discovered = <MusicOutput>[MusicOutput.thisDevice];
    final groupable = <MusicOutput>[];
    final api = link.api;
    final serverId = link.config?.serverId;

    if (api == null || serverId == null) {
      _lastKnownByServer.clear();
    } else if (!api.isConnected) {
      discovered.addAll(_unreachable(serverId));
    } else {
      try {
        final players = await MusicAssistantPlayers(api).players();
        final answered = <MusicOutput>[];
        final groupIds = {
          for (final player in players)
            if (player.isGroupPlayer) player.playerId,
        };
        for (final player in players) {
          // An earlier build registered this device as a player, and the
          // server remembers it. That entry can never be played to, so it is
          // noise in the one menu that has to be clear.
          if (player.playerId.startsWith(_staleOwnPlayerPrefix)) continue;
          if (player.hidden) continue;
          if (player.supportsGrouping && player.available) {
            groupable.add(MusicOutput.fromPlayer(player, serverId: serverId));
          }
          // A sync group's leader looks like a free room, but playing to it
          // would pull it out of the group.
          if (groupIds.contains(player.activeGroup)) continue;
          // A grouped member is driven through its leader; audio sent to it is
          // immediately overridden. A leader has children, a follower does not.
          if (player.isFollower) continue;
          final output = MusicOutput.fromPlayer(player, serverId: serverId);
          answered.add(player.isGroupPlayer ? output.copyWith(volume: _memberVolume(player, players)) : output);
        }
        _lastKnownByServer
          ..clear()
          ..[serverId] = List.unmodifiable(answered);
        discovered.addAll(answered);
      } catch (e, st) {
        // A failed listing is a server that did not answer, not one that
        // answered "no rooms".
        appLogger.w('Could not list Music Assistant players', error: e, stackTrace: st);
        discovered.addAll(_unreachable(serverId));
      }
    }

    if (_disposed) return;
    _watchPlayers(api);
    _outputs = List.unmodifiable(discovered);
    _groupableRooms = List.unmodifiable(groupable);
    _reconcileSelection();
    notifyListeners();
  }

  /// What [serverId] last offered, marked unplayable because it cannot be
  /// asked right now. Empty when it has never answered.
  Iterable<MusicOutput> _unreachable(String serverId) => (_lastKnownByServer[serverId] ?? const <MusicOutput>[]).map(
    (output) => output.copyWith(available: false, unavailableReason: t.music.outputServerUnreachable),
  );

  /// Keep the list live without polling: the server already tells us. One
  /// subscription, moved to each new socket.
  void _watchPlayers(MusicAssistantApi? api) {
    if (identical(api, _watchedApi)) return;
    unawaited(_playerSubscription?.cancel());
    _playerSubscription = null;
    _watchedApi = api;
    if (api != null) {
      _playerSubscription = MusicAssistantPlayers(api).playerChanges().listen((_) => _requestRefresh());
    }
  }

  /// Play to [rooms] at once: find or create their sync group and select it.
  ///
  /// Throws what the server said, for the caller to show: the selection only
  /// moves once the group is real.
  Future<void> selectGroup(List<MusicOutput> rooms) async {
    final first = rooms.first;
    final group = await musicAssistantPlayersFor(
      link,
      first,
    ).syncGroup({for (final room in rooms) room.playerId!}, name: rooms.map((room) => room.name).join(' + '));
    await refresh();
    await select(
      _findById('${first.serverId}|${group.playerId}') ?? MusicOutput.fromPlayer(group, serverId: first.serverId!),
    );
  }

  /// [group]'s volume, read from its rooms.
  ///
  /// A group that has not played yet reports `group_volume: 0`, measured on
  /// 2.10.9 with its rooms at 50. Believing that opens the slider at nothing,
  /// and the next press of a volume button sets every room to almost silent.
  int? _memberVolume(MaPlayer group, List<MaPlayer> players) {
    final levels = [
      for (final player in players)
        if (group.groupChilds.contains(player.playerId)) player.volumeLevel,
    ];
    if (levels.isEmpty) return null;
    return (levels.reduce((a, b) => a + b) / levels.length).round();
  }

  /// Choose where audio comes out. Persisted immediately, so the choice
  /// survives a crash as well as a clean exit.
  Future<void> select(MusicOutput output) async {
    if (_disposed) return;
    // Recorded even when the id is unchanged: choosing the output that was
    // *defaulted* to is a real choice, and it is what stops a later refresh
    // re-deriving a different default.
    final wasChosen = _chosen;
    _chosen = true;
    _storedId = null;
    if (_selected.id == output.id && wasChosen) return;
    _selected = output;
    notifyListeners();
    try {
      final settings = await _settingsLoader();
      await settings.write(SettingsService.musicOutputId, output.id);
    } catch (e, st) {
      appLogger.w('Could not remember the chosen music output', error: e, stackTrace: st);
    }
  }

  Future<void> _restoreSelection() async {
    if (_restored) return;
    _restored = true;
    try {
      final settings = await _settingsLoader();
      final stored = settings.read(SettingsService.musicOutputId);
      if (stored.isNotEmpty) _storedId = stored;
    } catch (e) {
      appLogger.d('Could not read the stored music output: $e');
    }
  }

  String? _storedId;

  /// Whether the current selection is a *choice* rather than a default.
  ///
  /// The distinction cannot be recovered from [_selected] alone, and assuming
  /// it could was a bug: [MusicOutput.thisDevice] is always in the list, so
  /// "the user picked the phone" and "nobody has picked anything" both look
  /// like a selection that is present and valid, and the prefer-a-speaker rule
  /// never fired at all.
  bool _chosen = false;

  /// Re-point the selection at the freshly-read list.
  ///
  /// In order:
  ///
  /// 1. A stored output that is now present — take it. If it is stored but not
  ///    present, keep waiting rather than choosing something else: the server
  ///    may still be connecting, and the phone is a fine place to be
  ///    meanwhile.
  /// 2. Nothing ever chosen — stay on the phone, per the class doc.
  /// 3. A live choice — refresh the availability and volume snapshot on it.
  /// 4. A choice that has gone away (a speaker unplugged, a server removed) —
  ///    fall back to the phone, which is always there. Deliberately *not* a
  ///    silent hop to a different speaker: audio appearing in a room nobody
  ///    chose is worse than audio appearing on the device in their hand.
  void _reconcileSelection() {
    final storedId = _storedId;
    if (storedId != null) {
      final match = _findById(storedId);
      if (match == null) return;
      _storedId = null;
      _chosen = true;
      _selected = match;
      return;
    }

    if (!_chosen) {
      _selected = MusicOutput.thisDevice;
      return;
    }

    final live = _findById(_selected.id);
    if (live != null) {
      _selected = live;
      return;
    }

    if (_selected.isRemote) {
      appLogger.i('Music output ${_selected.name} is gone; falling back to this device');
      _selected = MusicOutput.thisDevice;
    }
  }

  MusicOutput? _findById(String id) {
    for (final output in _outputs) {
      if (output.id == id) return output;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    if (_started) link.removeListener(_requestRefresh);
    unawaited(_playerSubscription?.cancel());
    super.dispose();
  }
}
