import 'package:media_kit/media_kit.dart';

/// Buffer / latency profile applied to every player.
///
/// [seconds] is the target amount of media kept ahead of the playhead. It is
/// used both for the mpv cache configuration and as the denominator for the
/// buffer-health readout in the player UI.
enum BufferMode {
  low(2, 'Low Latency', '2 seconds - minimal delay, may buffer more'),
  normal(10, 'Normal', '10 seconds - balanced'),
  high(30, 'High Reliability', '30 seconds - best for unstable connections');

  final int seconds;
  final String label;
  final String description;

  const BufferMode(this.seconds, this.label, this.description);

  /// Demuxer byte budget. Live TS streams are bursty, so the byte cap matters
  /// as much as the time cap - a 30s target is useless if the demuxer stops
  /// reading after 8MB.
  String get demuxerMaxBytes => switch (this) {
        BufferMode.low => '32MiB',
        BufferMode.normal => '64MiB',
        BufferMode.high => '128MiB',
      };

  String get demuxerMaxBackBytes => switch (this) {
        BufferMode.low => '16MiB',
        BufferMode.normal => '32MiB',
        BufferMode.high => '64MiB',
      };

  /// How long mpv waits for the cache to refill before resuming after an
  /// underrun. Resuming too eagerly on a flaky stream causes a stutter loop.
  String get cachePauseWait => switch (this) {
        BufferMode.low => '0.5',
        BufferMode.normal => '1.5',
        BufferMode.high => '4',
      };
}

/// mpv / FFmpeg level configuration - the *prevention* half of stream
/// resilience.
///
/// The single most important setting here is `stream-lavf-o=reconnect=...`,
/// which lets FFmpeg itself re-establish a dropped HTTP connection mid-stream
/// without playback ever stopping. IPTV providers drop connections constantly;
/// without this, every drop becomes an application-level freeze that the
/// watchdog has to clean up after.
///
/// `network-timeout` is the second: by default a stalled socket read can hang
/// indefinitely, which is exactly the "frozen forever, no error" case. Bounding
/// it converts a silent hang into an error we can act on.
class StreamTuning {
  StreamTuning._();

  static const String userAgent = 'IPTV Player/1.0';

  /// Seconds a socket read may stall before FFmpeg aborts it.
  static const int networkTimeoutSeconds = 10;

  /// Applies tuning to [player]. Safe to call on any platform and at any point
  /// after the player is constructed - unsupported properties are skipped
  /// individually so one failure never aborts the rest.
  ///
  /// MUST be called only after the player's [VideoController] has been handed
  /// to the widget tree. [NativePlayer.setProperty] awaits video-controller
  /// initialisation, and the controller cannot initialise until a Video widget
  /// mounts - so applying tuning before the first build deadlocks until every
  /// property times out. That cost ~30s per recovery when it was wrong.
  static Future<void> apply(
    Player player, {
    required BufferMode mode,
    required bool isLive,
  }) async {
    final native = player.platform;
    if (native is! NativePlayer) return;

    // FFmpeg AVOptions for the underlying http/tcp protocol handler.
    //   reconnect / reconnect_streamed  - transparently redial on connection loss
    //   reconnect_on_network_error      - also redial on transport errors
    //   reconnect_delay_max             - cap the redial backoff
    //   rw_timeout                      - microseconds; bounds a stalled read
    final lavfOptions = <String>[
      'reconnect=1',
      'reconnect_streamed=1',
      'reconnect_on_network_error=1',
      'reconnect_delay_max=5',
      'rw_timeout=${networkTimeoutSeconds * 1000000}',
      'user_agent=$userAgent',
    ].join(',');

    final properties = <String, String>{
      // --- network resilience ---
      'stream-lavf-o': lavfOptions,
      'network-timeout': '$networkTimeoutSeconds',
      'user-agent': userAgent,

      // --- cache sizing ---
      'cache': 'yes',
      'cache-secs': '${mode.seconds}',
      'demuxer-readahead-secs': '${mode.seconds}',
      'demuxer-max-bytes': mode.demuxerMaxBytes,
      'demuxer-max-back-bytes': mode.demuxerMaxBackBytes,
      'stream-buffer-size': '4MiB',

      // Pause on underrun and refill rather than stuttering through it.
      'cache-pause': 'yes',
      'cache-pause-wait': mode.cachePauseWait,
      'cache-pause-initial': mode == BufferMode.high ? 'yes' : 'no',

      // --- live stream behaviour ---
      // keep-open=no so an ended live stream reports completion instead of
      // parking on the last frame, which is indistinguishable from a freeze.
      'keep-open': isLive ? 'no' : 'yes',
      // Drop frames rather than accumulating A/V desync after a network hiccup.
      'framedrop': 'vo',
      'hls-bitrate': 'max',
    };

    // Concurrently, so a property that blocks costs one timeout rather than
    // stacking with all the others. Recovery latency depends on this.
    await Future.wait(properties.entries.map((entry) async {
      try {
        await native
            .setProperty(entry.key, entry.value)
            .timeout(const Duration(milliseconds: 1500));
      } catch (e) {
        print('StreamTuning: could not set ${entry.key}=${entry.value} ($e)');
      }
    }));
  }

  /// Reads an mpv property, returning null instead of hanging or throwing.
  ///
  /// [NativePlayer.getProperty] awaits player *and* video-controller
  /// initialisation, either of which can stall on a wedged stream - which is
  /// precisely when the watchdog needs to read it. The timeout is what keeps a
  /// health sample from blocking the watchdog's timer.
  static Future<String?> readProperty(Player player, String property) async {
    final native = player.platform;
    if (native is! NativePlayer) return null;
    try {
      final value = await native
          .getProperty(property)
          .timeout(const Duration(milliseconds: 500));
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<double?> readDouble(Player player, String property) async {
    final raw = await readProperty(player, property);
    return raw == null ? null : double.tryParse(raw);
  }

  static Future<bool?> readFlag(Player player, String property) async {
    final raw = await readProperty(player, property);
    if (raw == null) return null;
    return raw == 'yes' || raw == 'true';
  }

  /// Fraction of the buffer target currently held ahead of the playhead, 0..1.
  ///
  /// [buffered] is media_kit's `state.buffer`, which is the absolute media
  /// timestamp the demuxer has read up to - NOT the amount of data remaining.
  /// Dividing it by the target directly (as the old buffer-health readout did)
  /// pins the meter at 100% after the first few seconds of any stream, because
  /// the timestamp only ever grows. The readahead is the difference.
  static double bufferHealth(
    Duration buffered,
    Duration position,
    int targetSeconds,
  ) {
    if (targetSeconds <= 0) return 0.0;
    final readaheadMs = buffered.inMilliseconds - position.inMilliseconds;
    if (readaheadMs <= 0) return 0.0;
    return (readaheadMs / (targetSeconds * 1000)).clamp(0.0, 1.0);
  }

  /// Strips credentials out of a stream URL so it is safe to log.
  ///
  /// Xtream embeds the account's username and password directly in the stream
  /// path (`/live/<user>/<pass>/<id>.ts`) and in `player_api.php` query
  /// parameters. Anything that prints a raw stream URL is therefore printing
  /// the subscription password in cleartext, into logs that routinely get
  /// pasted into bug reports.
  static String redactUrl(String url) {
    var result = url;

    // /live|movie|series/<user>/<pass>/<id>.<ext>
    result = result.replaceAllMapped(
      RegExp(r'/(live|movie|series)/[^/]+/[^/]+/'),
      (match) => '/${match[1]}/***/***/',
    );

    // ?username=...&password=...
    result = result.replaceAllMapped(
      RegExp(r'([?&](?:username|password|token|pass|user)=)[^&]*',
          caseSensitive: false),
      (match) => '${match[1]}***',
    );

    return result;
  }

  /// Alternate URL to try when a stream will not start or will not recover.
  ///
  /// Xtream servers usually expose the same live channel as both a raw MPEG-TS
  /// stream and an HLS playlist, and it is common for one to be broken while
  /// the other works. Returns null when there is no sensible alternative.
  static String? alternateUrl(String url) {
    final query = url.indexOf('?');
    final path = query == -1 ? url : url.substring(0, query);
    final suffix = query == -1 ? '' : url.substring(query);

    if (path.endsWith('.ts')) {
      return '${path.substring(0, path.length - 3)}.m3u8$suffix';
    }
    if (path.endsWith('.m3u8')) {
      return '${path.substring(0, path.length - 5)}.ts$suffix';
    }
    return null;
  }
}
