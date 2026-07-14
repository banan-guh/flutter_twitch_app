import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/twitch_message.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_oauth.dart';
import 'benchmark_screen.dart';

typedef OAuthStarter =
    Future<String?> Function({required void Function(String authUrl) onReady});

class SettingsScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueNotifier<List<String>>? channelNotifier;
  final ValueChanged<String>? onLeaveChannel;
  final ValueChanged<String>? onAddChannel;
  final OAuthStarter? oAuthStarter;
  final Stream<TwitchMessage>? eventSubMessageStream;

  const SettingsScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.channelNotifier,
    this.onLeaveChannel,
    this.onAddChannel,
    this.oAuthStarter,
    this.eventSubMessageStream,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _AuthState { idle, waiting, success, error, needsSetup }

class _SettingsScreenState extends State<SettingsScreen> {
  _AuthState _authState = _AuthState.idle;
  String? _authError;
  String? _authUrl;
  int _maxMessagesPerChannel = 200;
  double _uiScale = 1.0;

  @override
  void initState() {
    super.initState();
    if (widget.twitchAuth.isConfigured) _authState = _AuthState.success;
    widget.channelNotifier?.addListener(_onChannelsChanged);
    _loadMaxMessages();
    _loadUiScale();
  }

  Future<void> _loadMaxMessages() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _maxMessagesPerChannel =
            prefs.getInt('max_messages_per_channel') ?? 200;
      });
    }
  }

  Future<void> _loadUiScale() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _uiScale = prefs.getDouble('ui_scale') ?? 1.0;
      });
    }
  }

  @override
  void dispose() {
    widget.channelNotifier?.removeListener(_onChannelsChanged);
    super.dispose();
  }

  void _onChannelsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startOAuth() async {
    setState(() {
      _authState = _AuthState.waiting;
      _authError = null;
      _authUrl = null;
    });

    final starter = widget.oAuthStarter ?? TwitchOAuth.startFlow;
    final token = await starter(
      onReady: (url) {
        if (url.isEmpty) {
          setState(() {
            _authState = _AuthState.needsSetup;
          });
          return;
        }
        setState(() => _authUrl = url);
        _tryOpenUrl(url);
      },
    );

    if (!mounted) return;

    if (token != null && token.isNotEmpty) {
      widget.twitchAuth.setCredentials(accessToken: token);
      setState(() => _authState = _AuthState.success);
    } else if (_authState != _AuthState.needsSetup) {
      setState(() {
        _authState = _AuthState.error;
        _authError =
            _authError ??
            TwitchOAuth.lastError ??
            'Authorization failed or timed out.';
      });
    }
  }

  Future<void> _tryOpenUrl(String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        setState(
          () => _authError = 'Could not open browser. Use the button below.',
        );
      }
    } catch (_) {
      setState(
        () => _authError = 'Could not open browser. Use the button below.',
      );
    }
  }

  void _clearCredentials() {
    widget.twitchAuth.clear();
    setState(() {
      _authState = _AuthState.idle;
      _authError = null;
      _authUrl = null;
    });
  }

  void _addChannelDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join channel'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'channel name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (_) {
            final text = controller.text;
            Navigator.pop(ctx);
            widget.onAddChannel?.call(text);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text;
              Navigator.pop(ctx);
              widget.onAddChannel?.call(text);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final channels = widget.channelNotifier?.value ?? [];

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.channelNotifier != null) ...[
            Text('Channels', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (channels.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No channels joined',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              ...channels.map(
                (ch) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(ch),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => widget.onLeaveChannel?.call(ch),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: OutlinedButton.icon(
                onPressed: _addChannelDialog,
                icon: const Icon(Icons.add),
                label: const Text('Join channel'),
              ),
            ),
            const Divider(height: 32),
          ],
          SwitchListTile(
            title: const Text('Dark mode'),
            value: isDark,
            onChanged: (dark) {
              widget.onThemeChanged(dark ? ThemeMode.dark : ThemeMode.light);
            },
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Max messages per channel: $_maxMessagesPerChannel',
                ),
              ),
              Slider(
                value: _maxMessagesPerChannel.toDouble(),
                min: 100,
                max: 1000,
                divisions: 9,
                label: '$_maxMessagesPerChannel',
                onChanged: (value) async {
                  final v = value.toInt();
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setInt('max_messages_per_channel', v);
                  if (mounted) setState(() => _maxMessagesPerChannel = v);
                },
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'UI scale: ${_uiScale.toStringAsFixed(1)}x',
                ),
              ),
              Slider(
                value: _uiScale,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                label: '${_uiScale.toStringAsFixed(1)}x',
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setDouble('ui_scale', value);
                  if (mounted) setState(() => _uiScale = value);
                },
              ),
            ],
          ),
          const Divider(height: 32),
          Text('Twitch Login', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          _buildBody(),
          const Divider(height: 32),
          Text('Debug', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => BenchmarkScreen(
                  twitchAuth: widget.twitchAuth,
                  availableChannels: widget.channelNotifier?.value ?? [],
                  eventSubMessages: widget.eventSubMessageStream,
                ),
              ),
            ),
            icon: const Icon(Icons.speed),
            label: const Text('Message Latency Benchmark'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_authState) {
      case _AuthState.idle:
        return Center(
          child: FilledButton.icon(
            onPressed: _startOAuth,
            icon: const Icon(Icons.login),
            label: const Text('Login with Twitch'),
          ),
        );

      case _AuthState.needsSetup:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.info_outline, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Open lib/twitch_config.dart and replace YOUR_CLIENT_ID_HERE '
                  'with your Twitch Client ID.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Get one at dev.twitch.tv/console/apps',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _startOAuth,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try Again'),
                ),
              ],
            ),
          ),
        );

      case _AuthState.waiting:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_authUrl != null) ...[
                if (_authError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_authError!, textAlign: TextAlign.center),
                  ),
                SelectionArea(
                  child: SelectableText(
                    _authUrl!,
                    style: const TextStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _authUrl!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL copied!')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy URL'),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: () => _tryOpenUrl(_authUrl!),
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Open in Browser'),
                ),
              ],
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
            ],
          ),
        );

      case _AuthState.success:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, size: 64, color: Colors.green),
              const SizedBox(height: 16),
              const Text('Connected to Twitch'),
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: _clearCredentials,
                icon: const Icon(Icons.logout),
                label: const Text('Disconnect'),
              ),
            ],
          ),
        );

      case _AuthState.error:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _authError ?? 'Unknown error',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              if (_authUrl != null) ...[
                FilledButton.tonalIcon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _authUrl!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL copied!')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy URL'),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                onPressed: _startOAuth,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
            ],
          ),
        );
    }
  }
}
