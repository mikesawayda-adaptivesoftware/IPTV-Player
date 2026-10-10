import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_bridge.dart';
import '../../core/cast/cast_relay.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/channel.dart';
import '../../providers/playlist_provider.dart';

/// The Chromecast test: casts live channels through the phone relay and
/// records, per channel, what the stream carried and whether it played.
///
/// A diagnostic screen, not the finished feature. It exists to answer the
/// questions in the relay plan before the rest is built: which channels play,
/// with sound, and how long a channel change takes. Results can be copied and
/// pasted back into the project thread.
///
/// The phone's own player is stopped before this screen opens and is only
/// re-opened after the relay has closed its provider connection (see
/// [_leave]), so the provider never sees two streams.
class CastTestScreen extends ConsumerStatefulWidget {
  final Channel channel;

  const CastTestScreen({super.key, required this.channel});

  @override
  ConsumerState<CastTestScreen> createState() => _CastTestScreenState();
}

class _CastResult {
  final String channel;
  String video = '?';
  String audio = '?';
  Duration? timeToPlaying;
  String receiver = 'not started';
  String? verdict;

  /// Times the receiver errored and was handed the stream again.
  int retries = 0;

  /// Chunks the receiver asked for that were already gone.
  int misses = 0;

  _CastResult(this.channel);

  String get line {
    final t = timeToPlaying == null
        ? 'never played'
        : '${(timeToPlaying!.inMilliseconds / 1000).toStringAsFixed(1)}s to play';
    return '$channel | video $video | audio $audio | $t | receiver $receiver'
        ' | retries $retries | missed chunks $misses'
        ' | ${verdict ?? 'no verdict'}';
  }
}

class _CastTestScreenState extends ConsumerState<CastTestScreen> {
  final CastRelay _relay = CastRelay();
  final CastBridge _bridge = CastBridge();
  final List<StreamSubscription> _subscriptions = [];

  late Channel _channel;
  List<CastDevice> _devices = const [];
  String _session = 'not connected';
  ReceiverStatus _receiver = const ReceiverStatus(ReceiverState.unknown);
  RelayStats? _stats;
  String? _error;
  bool _leaving = false;

  DateTime? _tuneStart;
  final List<_CastResult> _results = [];
  _CastResult? get _current => _results.isEmpty ? null : _results.last;

  Timer? _ticker;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;

    _subscriptions
      ..add(_bridge.devices.listen((d) => setState(() => _devices = d)))
      ..add(_bridge.session.listen(_onSession))
      ..add(_bridge.receiver.listen(_onReceiver))
      ..add(_relay.changes.listen((_) => _refreshStats()));

    // The relay stats change many times a second; repaint on a clock instead.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    _startup();
  }

  Future<void> _startup() async {
    try {
      await _relay.start();
      await _bridge.startDiscovery();
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    }
  }

  void _refreshStats() {
    _stats = _relay.stats;
    final current = _current;
    if (current != null && _stats!.info.videoPid != null) {
      current
        ..video = _stats!.info.videoName
        ..audio = _stats!.info.audioNames;
    }
    if (current != null) current.misses = _stats!.segmentMisses;
  }

  void _onSession(String state) {
    setState(() => _session = state);
    if (state == 'connected' && _current == null) _tune(_channel);
  }

  void _onReceiver(ReceiverStatus status) {
    final current = _current;
    setState(() {
      _receiver = status;
      if (current == null) return;
      current.receiver = status.idleReason == null
          ? status.state.name
          : '${status.state.name} (${status.idleReason})';
      final start = _tuneStart;
      if (status.state == ReceiverState.playing &&
          current.timeToPlaying == null &&
          start != null) {
        current.timeToPlaying = DateTime.now().difference(start);
      }
    });
    if (status.state == ReceiverState.idle && status.idleReason == 'error') {
      _scheduleRetry();
    }
  }

  /// Hands the receiver the same relay address again after it errors.
  ///
  /// The relay keeps running, so this costs no provider connection - it is
  /// the change-channel-and-back workaround without the channel change.
  /// Never gives up while the channel is on screen, like the phone's own
  /// player; the count is recorded so a test still shows it happened.
  void _scheduleRetry() {
    final current = _current;
    if (current == null || _leaving || _retryTimer?.isActive == true) return;
    _retryTimer = Timer(const Duration(seconds: 2), () async {
      if (!mounted || _leaving || !identical(current, _current)) return;
      setState(() => current.retries++);
      try {
        await _bridge.load(_relay.playlistUri.toString(), title: _channel.name);
      } catch (e) {
        if (mounted) setState(() => _error = _describe(e));
      }
    });
  }

  Future<void> _tune(Channel channel) async {
    _retryTimer?.cancel();
    setState(() {
      _channel = channel;
      _error = null;
      _tuneStart = DateTime.now();
      _results.add(_CastResult(channel.name));
    });
    ref.read(channelStateProvider.notifier).markAsWatched(channel);
    try {
      final url = await _relay.tune(channel.streamUrl);
      await _bridge.load(url.toString(), title: channel.name);
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    }
  }

  void _step(bool forward) {
    final notifier = ref.read(channelStateProvider.notifier);
    final next = forward
        ? notifier.getNextChannel(_channel)
        : notifier.getPreviousChannel(_channel);
    if (next != null) _tune(next);
  }

  /// Closes the provider connection, then the receiver, then the screen - in
  /// that order, so the phone's player can reopen without a second stream.
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _retryTimer?.cancel();
    await _relay.stop();
    try {
      await _bridge.disconnect();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(_channel);
  }

  void _copyResults() {
    final text = [
      'Chromecast relay test',
      ..._results.map((r) => r.line),
    ].join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Results copied. Paste them into the thread.')),
    );
  }

  String _describe(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    return e.toString();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _retryTimer?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    // Normally already done by _leave; this covers the screen being torn down
    // some other way.
    _relay.dispose();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _session == 'connected';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: AppTheme.backgroundColor,
        appBar: AppBar(
          title: const Text('Chromecast test'),
          actions: [
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy results',
              onPressed: _results.isEmpty ? null : _copyResults,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null) _errorCard(_error!),
            if (!connected) ..._devicePicker() else ..._casting(),
            const SizedBox(height: 24),
            if (_results.isNotEmpty) ..._resultList(),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _leave,
              icon: const Icon(Icons.stop),
              label: const Text('Stop casting'),
              style: FilledButton.styleFrom(backgroundColor: AppTheme.errorColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String message) {
    return Card(
      color: AppTheme.errorColor.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(message, style: const TextStyle(color: AppTheme.textPrimary)),
      ),
    );
  }

  List<Widget> _devicePicker() {
    return [
      Text('Session: $_session',
          style: const TextStyle(color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      const Text(
        'Pick a Chromecast. The phone must stay on the same Wi-Fi with this '
        'screen open for the whole test.',
        style: TextStyle(color: AppTheme.textPrimary),
      ),
      const SizedBox(height: 12),
      if (_devices.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
      for (final d in _devices)
        ListTile(
          leading: const Icon(Icons.cast, color: AppTheme.accentColor),
          title: Text(d.name, style: const TextStyle(color: AppTheme.textPrimary)),
          subtitle: d.description == null
              ? null
              : Text(d.description!,
                  style: const TextStyle(color: AppTheme.textSecondary)),
          onTap: () async {
            try {
              await _bridge.connect(d.id);
            } catch (e) {
              setState(() => _error = _describe(e));
            }
          },
        ),
    ];
  }

  List<Widget> _casting() {
    final stats = _stats;
    final current = _current;
    final elapsed = _tuneStart == null
        ? null
        : DateTime.now().difference(_tuneStart!).inSeconds;
    final lastRequest = stats?.lastReceiverRequest;
    final sinceRequest = lastRequest == null
        ? 'never'
        : '${DateTime.now().difference(lastRequest).inSeconds}s ago';

    return [
      Row(
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 32),
            onPressed: () => _step(false),
            tooltip: 'Previous channel',
          ),
          Expanded(
            child: Text(
              _channel.name,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, size: 32),
            onPressed: () => _step(true),
            tooltip: 'Next channel',
          ),
        ],
      ),
      const SizedBox(height: 8),
      _row('Chromecast', _receiver.idleReason == null
          ? _receiver.state.name
          : '${_receiver.state.name} (${_receiver.idleReason})'),
      _row(
        'Time to play',
        current?.timeToPlaying != null
            ? '${(current!.timeToPlaying!.inMilliseconds / 1000).toStringAsFixed(1)}s'
            : elapsed == null
                ? '-'
                : 'waiting (${elapsed}s)',
      ),
      _row('Video', stats?.info.videoName ?? '-'),
      _row('Audio', stats?.info.audioNames ?? '-'),
      const Divider(),
      _row('Provider', stats == null
          ? '-'
          : stats.connected
              ? 'connected (${stats.providerConnections} open)'
              : 'connecting (${stats.providerConnections} open)'),
      _row('Arriving', stats == null ? '-' : '${stats.kbpsIn.round()} kbit/s'),
      _row('Chunks ready', '${stats?.segments ?? 0}'
          '${stats?.lastSegmentSeconds == null ? '' : ', last ${stats!.lastSegmentSeconds!.toStringAsFixed(1)}s'}'),
      _row('Held back', '${(stats?.backlogSeconds ?? 0).toStringAsFixed(0)}s of stream'),
      _row('Keyframe every', stats?.keyframeInterval == null
          ? '-'
          : '${stats!.keyframeInterval!.toStringAsFixed(1)}s'),
      _row('Chromecast requests',
          '${stats?.playlistRequests ?? 0} playlist, ${stats?.segmentRequests ?? 0} chunks, last $sinceRequest'),
      if ((stats?.segmentMisses ?? 0) > 0)
        _row('Missed chunks', '${stats!.segmentMisses}'),
      if ((current?.retries ?? 0) > 0)
        _row('Receiver retries', '${current!.retries}'),
      if ((stats?.reconnects ?? 0) > 0)
        _row('Reconnects', '${stats!.reconnects}'),
      if ((stats?.forcedCuts ?? 0) > 0)
        _row('Cuts without keyframe', '${stats!.forcedCuts}'),
      if (stats?.lastError != null) _row('Last problem', stats!.lastError!),
      const SizedBox(height: 16),
      const Text('How is it on the TV?',
          style: TextStyle(color: AppTheme.textSecondary)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in const ['Works', 'No sound', 'No picture', "Won't play"])
            ChoiceChip(
              label: Text(v),
              selected: current?.verdict == v,
              onSelected: current == null
                  ? null
                  : (_) => setState(() => current.verdict = v),
            ),
        ],
      ),
    ];
  }

  List<Widget> _resultList() {
    return [
      const Text('Results',
          style: TextStyle(
              color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      for (final r in _results.reversed)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(r.line,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        ),
    ];
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: const TextStyle(color: AppTheme.textSecondary)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}
