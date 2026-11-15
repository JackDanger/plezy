import 'dart:async';

import 'package:flutter/material.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../services/music_assistant/music_assistant_api.dart';
import '../../services/music_assistant/music_assistant_link.dart';
import '../../services/music_assistant/music_assistant_models.dart';
import '../../services/music_assistant_lan_discovery_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../../utils/log_redaction_manager.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';
import 'local_server_discovery.dart';

/// Port Music Assistant listens on out of the box.
const int _defaultMusicAssistantPort = 8095;

/// Whether saving [incoming] would move the saved server to a different
/// address.
///
/// The server id comes from an unauthenticated greeting, so anything on the
/// network can claim the user's server's id. Moving a server to a new address
/// is legitimate, so it is confirmed rather than blocked.
@visibleForTesting
bool isMusicAssistantRepoint({
  required MusicAssistantServerConfig? existing,
  required MusicAssistantServerConfig incoming,
}) {
  if (existing == null) return false;
  return existing.baseUrl != incoming.baseUrl;
}

/// Fill in what the user left out. Music Assistant's default port is not 80 and
/// its URL is invariably typed as a bare LAN address, so `10.0.2.107` alone must
/// resolve to `http://10.0.2.107:8095` or the obvious input fails to connect.
@visibleForTesting
String? normalizeMusicAssistantUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';

  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  // `ws`/`wss` are what a user copies out of Music Assistant's own settings;
  // the connection stores the HTTP form because the image proxy and the flow
  // stream are derived from it. MusicAssistantApi re-derives the socket URL.
  final scheme = switch (uri.scheme) {
    'ws' => 'http',
    'wss' => 'https',
    'http' || 'https' => uri.scheme,
    _ => null,
  };
  if (scheme == null) return null;

  // A trailing `/ws` is the endpoint, not the server root.
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);

  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : (scheme == 'https' ? null : _defaultMusicAssistantPort),
    path: path,
  ).toString();
}

/// Choose the Music Assistant server whose speakers music can be sent to.
///
/// The servers found on the network (mDNS `_mass._tcp`) are the body of the
/// screen, and one tap on one connects to it. Typing an address is one tap
/// away for a server discovery cannot reach. A server that wants a sign-in
/// stops on the form; what is stored is a long-lived token, never the password.
///
/// Connecting means opening the WebSocket and reading the greeting, the only
/// thing that proves the address is reachable and that Music Assistant is
/// what answered.
class MusicAssistantSettingsScreen extends StatefulWidget {
  final FutureOr<List<DiscoveredMusicAssistantServer>> Function()? _localDiscoveryFactory;
  final MusicAssistantApi Function()? _apiFactory;

  const MusicAssistantSettingsScreen({
    super.key,
    @visibleForTesting this._localDiscoveryFactory,
    @visibleForTesting this._apiFactory,
  });

  @override
  State<MusicAssistantSettingsScreen> createState() => _MusicAssistantSettingsScreenState();
}

class _MusicAssistantSettingsScreenState extends State<MusicAssistantSettingsScreen>
    with
        AsyncFormStateMixin,
        ControllerDisposerMixin,
        LocalServerDiscoveryMixin<DiscoveredMusicAssistantServer, MusicAssistantSettingsScreen> {
  late final _urlController = createTextEditingController();
  late final _tokenController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'AddMusicAssistant:Url');
  final _findServerFocus = FocusNode(debugLabel: 'AddMusicAssistant:FindServer');
  final _changeServerFocus = FocusNode(debugLabel: 'AddMusicAssistant:ChangeServer');
  final _searchAgainFocus = FocusNode(debugLabel: 'AddMusicAssistant:SearchAgain');
  final _manualToggleFocus = FocusNode(debugLabel: 'AddMusicAssistant:EnterManually');
  final _tokenFocus = FocusNode(debugLabel: 'AddMusicAssistant:Token');
  final _usernameFocus = FocusNode(debugLabel: 'AddMusicAssistant:Username');
  final _passwordFocus = FocusNode(debugLabel: 'AddMusicAssistant:Password');
  final _addFocus = FocusNode(debugLabel: 'AddMusicAssistant:Add');
  final _forgetFocus = FocusNode(debugLabel: 'AddMusicAssistant:Forget');
  final _replaceFocus = FocusNode(debugLabel: 'AddMusicAssistant:Replace');

  /// Showing the add flow while a server is already saved.
  bool _replacing = false;
  final _formKey = GlobalKey<FormState>();

  MaServerInfo? _serverInfo;

  /// The URL the greeting actually arrived on — preferred over the greeting's
  /// own `base_url`, which on a containerised or multi-homed host is routinely
  /// an address this device cannot reach.
  String? _resolvedBaseUrl;

  /// Whether the resolved server refused an unauthenticated socket.
  bool _requiresSignIn = false;

  /// Whether the type-an-address fallback is on screen.
  ///
  /// Starts closed. It opens by itself only when discovery has finished and
  /// found nothing, because at that point it is no longer a fallback — it is
  /// the only way forward, and making the user press one more button to reach
  /// it would be a wall in front of the door.
  bool _manualEntry = false;

  /// The discovered server currently being added, so its own row can show the
  /// progress instead of the whole screen going busy.
  String? _addingServerId;

  MusicAssistantLink get _link => context.read<MusicAssistantLink>();

  /// The saved server's id, so its row in the discovery list can say so.
  String? get _savedServerId => _link.config?.serverId;

  @override
  String get discoveryDebugLabel => 'AddMusicAssistant';

  @override
  String discoveredServerId(DiscoveredMusicAssistantServer server) => server.id;

  @override
  Future<List<DiscoveredMusicAssistantServer>> discoverLocalServers() async {
    final factory = widget._localDiscoveryFactory;
    return factory != null ? await factory() : await MusicAssistantLanDiscoveryService().discover();
  }

  @override
  void initState() {
    super.initState();
    startLocalDiscovery();
  }

  @override
  void dispose() {
    disposeLocalDiscovery();
    _urlFocus.dispose();
    _findServerFocus.dispose();
    _changeServerFocus.dispose();
    _searchAgainFocus.dispose();
    _manualToggleFocus.dispose();
    _tokenFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _addFocus.dispose();
    _forgetFocus.dispose();
    _replaceFocus.dispose();
    super.dispose();
  }

  void _clearResolvedServer() {
    _serverInfo = null;
    _resolvedBaseUrl = null;
    _requiresSignIn = false;
  }

  /// One tap: probe the advertised address and, if it answers, add it.
  ///
  /// No intermediate form: the address comes from the advert. A server that
  /// wants a sign-in is the exception, and stops on the form.
  ///
  /// The probe still happens. The advert proves something is announcing itself
  /// as Music Assistant, not that it is reachable from here or that it is
  /// really Music Assistant, and the greeting is the only thing that proves
  /// both.
  Future<void> _useDiscoveredServer(DiscoveredMusicAssistantServer server) async {
    if (busy || _addingServerId != null) return;
    setState(() {
      _addingServerId = server.id;
      _urlController.text = server.address;
      _clearResolvedServer();
    });
    try {
      await _probe();
      if (!mounted || _serverInfo == null || _requiresSignIn) return;
      await _persistResolvedServer();
    } finally {
      // `mounted` is false on the success path — `_persistAndExit` pops.
      if (mounted) setState(() => _addingServerId = null);
    }
  }

  /// Open the socket, read the greeting, find out whether it wants a sign-in,
  /// close it again.
  ///
  /// Deliberately a throwaway [MusicAssistantApi] with `autoReconnect: false`:
  /// a mistyped address must fail here and stay failed, not leave a retry loop
  /// running behind a form the user has already backed out of.
  Future<void> _probe() async {
    final url = normalizeMusicAssistantUrl(_urlController.text);
    if (url == null) {
      setErrorText(t.addServer.enterMusicAssistantUrlError);
      return;
    }
    // Registered before the probe, not after it succeeds: the failure path is
    // the one that logs the URL, and every failed probe writes it to a log
    // buffer the user can upload. An IP is covered by the generic pattern, a
    // hostname is not covered by anything until it is registered.
    LogRedactionManager.registerServerUrl(url);
    await runAsync<void>(
      () async {
        final api = _oneShotApi();
        final MaServerInfo info;
        final bool requiresSignIn;
        try {
          info = await api.connect(Uri.parse(url));
          requiresSignIn = await api.requiresSignIn();
        } finally {
          unawaited(api.dispose());
        }
        if (!mounted) return;
        setState(() {
          _serverInfo = info;
          _resolvedBaseUrl = url;
          _requiresSignIn = requiresSignIn;
          _urlController.text = url;
        });
        // Only when the form is what the user is looking at. On the one-tap
        // path the Add button never renders, and moving focus to a node that
        // is not in the tree strands a D-pad between two screens.
        if (requiresSignIn) {
          _requestFocusAfterFrame(_usernameFocus);
        } else if (_addingServerId == null) {
          _requestFocusAfterFrame(_addFocus);
        }
      },
      errorMapper: (e) {
        appLogger.w('Music Assistant probe failed for $url', error: e);
        // "Nothing answered" gets its own message because it has its own fix.
        // The generic one invites the user to re-check an address that is
        // usually correct — the address a browser on the same phone can reach
        // — while the thing actually blocking it is a permission they have no
        // reason to connect to this screen.
        if (e is MaUnreachableException) return t.addServer.musicAssistantUnreachable(address: e.address);
        return t.addServer.couldNotReachServer(error: e is MaException ? e.message : e.toString());
      },
    );
  }

  /// A socket that lives for one step of this form.
  MusicAssistantApi _oneShotApi() =>
      widget._apiFactory?.call() ??
      // Deliberately more generous than the background client's ten
      // seconds. This is a one-shot the user is watching, with
      // `autoReconnect: false` and nothing behind it — a premature
      // failure costs them the whole form, while a slow success costs
      // only the spinner. The first connection to a LAN address is also
      // the one iOS may hold while it asks the user for local-network
      // access, and a budget under that prompt's lifetime fails a server
      // that was about to work.
      MusicAssistantApi(autoReconnect: false, handshakeTimeout: const Duration(seconds: 20));

  /// The manual path's Add button: validate the form first, then persist.
  Future<void> _add() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_serverInfo == null || _resolvedBaseUrl == null) {
      await _probe();
      return;
    }
    if (!_requiresSignIn) {
      await _persistResolvedServer();
      return;
    }
    final token = await _signIn();
    if (token != null) await _persistResolvedServer(token: token);
  }

  /// Turn what the form holds into a token the server has accepted, or null
  /// with the reason on screen.
  ///
  /// A pasted token is checked here too. Stored unchecked, a typo would only
  /// surface later as a banner saying the session expired.
  Future<String?> _signIn() {
    final url = _resolvedBaseUrl!;
    final pasted = _tokenController.text.trim();
    return runAsync<String>(
      () async {
        final api = _oneShotApi();
        try {
          await api.connect(Uri.parse(url), accessToken: pasted.isEmpty ? null : pasted);
          if (pasted.isEmpty) {
            return await api.signIn(
              username: _usernameController.text.trim(),
              password: _passwordController.text,
              tokenName: await _tokenName(),
            );
          }
          if (await api.requiresSignIn()) {
            throw const MaRequestException('auth', 23, 'The access token is invalid or has expired.');
          }
          return pasted;
        } finally {
          unawaited(api.dispose());
        }
      },
      errorMapper: (e) {
        appLogger.w('Music Assistant sign-in failed', error: e);
        if (e is MaRequestException && e.isAuthFailure) return t.addServer.musicAssistantSignInRejected;
        return t.addServer.signInFailed(error: e is MaException ? e.message : e.toString());
      },
    );
  }

  /// What the token is called in Music Assistant's own list of them, which is
  /// where someone goes to revoke it, so it has to name the device.
  static Future<String> _tokenName() async {
    try {
      final name = (await DeviceIdentityService.resolve()).deviceName?.trim();
      if (name != null && name.isNotEmpty) return 'Plezy ($name)';
    } catch (e) {
      appLogger.d('Could not resolve a device name for the Music Assistant token: $e');
    }
    return 'Plezy';
  }

  /// Save whatever the last successful probe resolved, and leave.
  Future<void> _persistResolvedServer({String? token}) async {
    final info = _serverInfo;
    final baseUrl = _resolvedBaseUrl;
    if (info == null || baseUrl == null) return;
    final accessToken = token ?? _tokenController.text.trim();
    LogRedactionManager.registerToken(accessToken.isEmpty ? null : accessToken);
    final config = MusicAssistantServerConfig(
      baseUrl: baseUrl,
      serverId: info.serverId,
      accessToken: accessToken.isEmpty ? null : accessToken,
    );
    if (!await _confirmRepointIfNeeded(config)) return;
    if (!mounted) return;
    await runAsync<void>(
      () async {
        await _link.save(config);
        if (mounted) Navigator.of(context).pop(true);
      },
      errorMapper: (e) {
        appLogger.e('Saving the Music Assistant server failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
  }

  /// Ask before an add moves the saved server to another address.
  Future<bool> _confirmRepointIfNeeded(MusicAssistantServerConfig incoming) async {
    final current = _link.config;
    if (!isMusicAssistantRepoint(existing: current, incoming: incoming)) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.addServer.musicAssistantRepointTitle),
        content: Text(
          t.addServer.musicAssistantRepointBody(
            name: 'Music Assistant',
            current: current!.baseUrl,
            replacement: incoming.baseUrl,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(t.common.cancel)),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.addServer.musicAssistantRepointConfirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _forget() async {
    await _link.forget();
    if (mounted) setState(() => _replacing = false);
  }

  void _requestFocusAfterFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.canRequestFocus) return;
      node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.settings.musicAssistantSpeakers),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(crossAxisAlignment: .stretch, children: _buildBodyChildren(theme)),
            ),
          ),
        ),
      ],
    );
  }

  /// The screen has three shapes, in the order a user meets them:
  ///
  ///  * **Nothing resolved yet** — the discovery list, and a way to type an
  ///    address if it is not enough. This is the shape almost everyone sees,
  ///    and almost everyone leaves it by tapping a row.
  ///  * **Manual entry open** — the URL field and its Find button, unchanged
  ///    from before except that it is now something the user asked for.
  ///  * **A server resolved by hand, or one that wants a sign-in** — the
  ///    confirmation card, display name, and token or credentials. The
  ///    one-tap path only reaches this shape when it has something to ask.
  List<Widget> _buildBodyChildren(ThemeData theme) {
    final link = context.watch<MusicAssistantLink>();
    if (link.config != null && !_replacing && _serverInfo == null) return _buildSavedServer(theme, link);
    if (_serverInfo != null) return _buildResolvedServerChildren(theme);
    return [
      ..._buildLocalDiscoverySection(theme),
      if (!isDiscoveringLocalServers && localServers.isEmpty) ..._buildNothingFound(theme),
      if (!isDiscoveringLocalServers) ..._buildManualEntry(theme),
      ...buildInlineError(theme),
    ];
  }

  /// Shown when the browse came back empty.
  ///
  /// Deliberately says what to check before offering the retry: the two
  /// reasons a browse finds nothing on a network that has a server are the
  /// phone being on a different SSID (guest network, or 5GHz/2.4GHz split with
  /// isolation) and the server being off. Neither is fixed by pressing search
  /// again, so the button comes after the sentence rather than instead of it.
  List<Widget> _buildNothingFound(ThemeData theme) => [
    const SizedBox(height: 8),
    Text(t.addServer.musicAssistantNoneFound, style: theme.textTheme.titleSmall),
    const SizedBox(height: 4),
    Text(
      t.addServer.musicAssistantNoneFoundDetail,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
    ),
    const SizedBox(height: 12),
    FocusableButton(
      focusNode: _searchAgainFocus,
      useBackgroundFocus: true,
      onNavigateDown: () => (_manualEntry ? _urlFocus : _manualToggleFocus).requestFocus(),
      onPressed: busy ? null : restartLocalDiscovery,
      child: OutlinedButton.icon(
        onPressed: busy ? null : restartLocalDiscovery,
        icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
        label: Text(t.addServer.musicAssistantSearchAgain),
      ),
    ),
  ];

  /// The type-an-address fallback.
  ///
  /// Collapsed to a single text button until it is wanted, so the primary
  /// screen is the list of real servers rather than an empty field. Opens
  /// itself when discovery found nothing, because then it is not a fallback.
  List<Widget> _buildManualEntry(ThemeData theme) {
    final expanded = _manualEntry || localServers.isEmpty;
    if (!expanded) {
      return [
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FocusableButton(
            focusNode: _manualToggleFocus,
            useBackgroundFocus: true,
            onNavigateUp: () => focusLastDiscoveredServerOr(_manualToggleFocus),
            onPressed: busy ? null : () => setState(() => _manualEntry = true),
            child: TextButton.icon(
              onPressed: busy ? null : () => setState(() => _manualEntry = true),
              icon: const AppIcon(Symbols.keyboard_rounded, fill: 1),
              label: Text(t.addServer.musicAssistantEnterManually),
            ),
          ),
        ),
      ];
    }

    return [
      const SizedBox(height: 16),
      FocusableTextFormField(
        controller: _urlController,
        focusNode: _urlFocus,
        tvTextInputPresentation: PlatformDetector.isAppleTV()
            ? TvTextInputPresentation.platform
            : TvTextInputPresentation.automatic,
        // Only steals the keyboard when there is nothing else to do. With
        // servers on screen the first thing that happens must be the list
        // appearing, not a keyboard covering it.
        autofocus: localServers.isEmpty,
        tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
        keyboardType: TextInputType.url,
        maxLines: 1,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        onNavigateUp: () => focusLastDiscoveredServerOr(_searchAgainFocus),
        onNavigateDown: () => _findServerFocus.requestFocus(),
        textInputAction: TextInputAction.go,
        onFieldSubmitted: busy ? null : (_) => _probe(),
        decoration: InputDecoration(
          labelText: t.addServer.musicAssistantUrl,
          // URL example — intentionally not localized.
          hintText: 'http://192.168.1.10:8095',
          helperText: t.addServer.musicAssistantUrlHelper,
          prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
        ),
        validator: (_) => normalizeMusicAssistantUrl(_urlController.text) == null ? t.addServer.required : null,
      ),
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _findServerFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _urlFocus.requestFocus(),
        onPressed: busy ? null : _probe,
        child: FilledButton.icon(
          onPressed: busy ? null : _probe,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.travel_explore_rounded, fill: 1),
          label: Text(t.addServer.findServer),
        ),
      ),
    ];
  }

  List<Widget> _buildResolvedServerChildren(ThemeData theme) {
    return [
      FocusableTextFormField(
        controller: _urlController,
        focusNode: _urlFocus,
        tvTextInputPresentation: PlatformDetector.isAppleTV()
            ? TvTextInputPresentation.platform
            : TvTextInputPresentation.automatic,
        tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
        keyboardType: TextInputType.url,
        maxLines: 1,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        onChanged: (_) {
          if (_serverInfo == null) return;
          setState(_clearResolvedServer);
        },
        onNavigateDown: () => _changeServerFocus.requestFocus(),
        textInputAction: TextInputAction.go,
        onFieldSubmitted: busy ? null : (_) => _probe(),
        decoration: InputDecoration(
          labelText: t.addServer.musicAssistantUrl,
          hintText: 'http://192.168.1.10:8095',
          prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
        ),
        validator: (_) => normalizeMusicAssistantUrl(_urlController.text) == null ? t.addServer.required : null,
      ),
      const SizedBox(height: 16),
      _buildServerCard(theme),
      const SizedBox(height: 16),
      if (_requiresSignIn) ...[
        FocusableTextFormField(
          controller: _usernameController,
          focusNode: _usernameFocus,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          textInputAction: TextInputAction.next,
          onFieldSubmitted: busy ? null : (_) => _passwordFocus.requestFocus(),
          decoration: InputDecoration(
            labelText: t.addServer.username,
            prefixIcon: const AppIcon(Symbols.person_rounded, fill: 1),
          ),
          validator: _requiredUnlessTokenPasted,
        ),
        const SizedBox(height: 12),
        FocusableTextFormField(
          controller: _passwordController,
          focusNode: _passwordFocus,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: busy ? null : (_) => _add(),
          decoration: InputDecoration(
            labelText: t.addServer.password,
            prefixIcon: const AppIcon(Symbols.password_rounded, fill: 1),
          ),
          validator: _requiredUnlessTokenPasted,
        ),
        const SizedBox(height: 12),
      ],
      FocusableTextFormField(
        controller: _tokenController,
        focusNode: _tokenFocus,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: busy ? null : (_) => _add(),
        decoration: InputDecoration(
          labelText: t.addServer.musicAssistantToken,
          helperText: _requiresSignIn
              ? t.addServer.musicAssistantTokenInsteadHelper
              : t.addServer.musicAssistantTokenHelper,
          prefixIcon: const AppIcon(Symbols.key_rounded, fill: 1),
        ),
        // No validator: a blank token is the normal case.
      ),
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _addFocus,
        useBackgroundFocus: true,
        onPressed: busy ? null : _add,
        child: FilledButton.icon(
          onPressed: busy ? null : _add,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.add_rounded, fill: 1),
          label: Text(_requiresSignIn ? t.addServer.signIn : t.addServer.addMusicAssistantServer),
        ),
      ),
      ...buildInlineError(theme),
    ];
  }

  String? _requiredUnlessTokenPasted(String? value) =>
      (value ?? '').isEmpty && _tokenController.text.trim().isEmpty ? t.addServer.required : null;

  Widget _buildServerCard(ThemeData theme) {
    final info = _serverInfo!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      ),
      child: Row(
        children: [
          const AppIcon(Symbols.cloud_done_rounded, fill: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              children: [
                // Product name + version, matching the Jellyfin card; not
                // localized because neither half of it translates.
                Text('Music Assistant ${info.serverVersion}', style: theme.textTheme.titleSmall),
                Text(
                  info.serverId,
                  maxLines: 1,
                  overflow: .ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          FocusableButton(
            focusNode: _changeServerFocus,
            useBackgroundFocus: true,
            onNavigateUp: () => _urlFocus.requestFocus(),
            onNavigateDown: () => (_requiresSignIn ? _usernameFocus : _tokenFocus).requestFocus(),
            onPressed: busy ? null : () => setState(_clearResolvedServer),
            child: TextButton(
              onPressed: busy ? null : () => setState(_clearResolvedServer),
              child: Text(t.addServer.change),
            ),
          ),
        ],
      ),
    );
  }

  /// The saved server, how it is doing, and the two things to do with it.
  List<Widget> _buildSavedServer(ThemeData theme, MusicAssistantLink link) {
    final config = link.config!;
    final status = link.needsSignIn
        ? t.settings.musicAssistantNeedsSignIn
        : link.isConnected
        ? t.settings.musicAssistantConnected
        : t.settings.musicAssistantNotReachable;
    final version = link.api?.serverVersion;
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(tokens(context).radiusMd),
        ),
        child: Row(
          children: [
            AppIcon(link.isConnected ? Symbols.cloud_done_rounded : Symbols.cloud_off_rounded, fill: 1),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  Text(
                    version == null || version.isEmpty ? 'Music Assistant' : 'Music Assistant $version',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '${config.baseUrl} · $status',
                    maxLines: 2,
                    overflow: .ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _replaceFocus,
        autofocus: true,
        useBackgroundFocus: true,
        onNavigateDown: () => _forgetFocus.requestFocus(),
        onPressed: () => setState(() => _replacing = true),
        child: FilledButton.icon(
          onPressed: () => setState(() => _replacing = true),
          icon: AppIcon(link.needsSignIn ? Symbols.login_rounded : Symbols.swap_horiz_rounded, fill: 1),
          label: Text(link.needsSignIn ? t.addServer.signIn : t.settings.musicAssistantChangeServer),
        ),
      ),
      const SizedBox(height: 8),
      FocusableButton(
        focusNode: _forgetFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _replaceFocus.requestFocus(),
        onPressed: () => unawaited(_forget()),
        child: OutlinedButton.icon(
          onPressed: () => unawaited(_forget()),
          icon: const AppIcon(Symbols.link_off_rounded, fill: 1),
          label: Text(t.settings.musicAssistantForget),
        ),
      ),
    ];
  }

  List<Widget> _buildLocalDiscoverySection(ThemeData theme) => buildLocalDiscoverySection(
    theme,
    searchingLabel: t.addServer.searchingLocalMusicAssistantServers,
    sectionLabel: t.addServer.musicAssistantFoundOnNetwork,
    // Nothing above the list any more — it is the top of the screen. Up from
    // the first row goes to the manual-entry control below it rather than
    // nowhere, so a D-pad can always leave.
    focusAbove: _manualEntry ? _urlFocus : _manualToggleFocus,
    focusBelow: _manualEntry ? _urlFocus : _manualToggleFocus,
    // The advert carries no server name, only an id and a version, so the
    // product name plus the version is the most recognisable label there is.
    titleOf: (server) => server.version == null ? 'Music Assistant' : 'Music Assistant ${server.version}',
    addressOf: (server) => server.address,
    // Recognised from the advert alone — the instance name is the server_id
    // and the row id is derived from it — so this costs no round trip.
    statusOf: (server) => server.id == _savedServerId
        ? (_link.needsSignIn ? t.addServer.musicAssistantTapToSignIn : t.addServer.musicAssistantAlreadyAdded)
        : (_addingServerId == null ? t.addServer.musicAssistantTapToAdd : null),
    busyOf: (server) => _addingServerId == server.id,
    enabledOf: (server) => server.id != _savedServerId || _link.needsSignIn,
    onSelected: busy || _addingServerId != null ? null : (server) => unawaited(_useDiscoveredServer(server)),
  );
}
