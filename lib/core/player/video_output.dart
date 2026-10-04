import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'stream_tuning.dart';

/// How decoded video reaches the screen on Android.
///
/// Exists because one path does not work on every device. The media_kit
/// default - mpv's OpenGL renderer fed by `hwdec=auto-safe` - played sound with
/// a black picture on a real Android TV box. When mpv cannot bring the video
/// output up it deselects the video track and carries on with audio, so from
/// the user's side it looks like a stream with no picture rather than an error.
///
/// Only meaningful on Android. Everywhere else [configuration] ignores the
/// choice and returns the platform default.
enum VideoOutput {
  /// Settings value only: start from [learned] and fall back on its own.
  auto('Automatic', 'Try each output in turn and remember the one that works'),
  hardware('GPU, hardware decoding', 'Default. Best picture handling'),
  direct('Direct (MediaCodec)',
      'Decoder draws straight to the screen. Lightest on TV boxes'),
  software('GPU, software decoding',
      'Most compatible, but 1080p may stutter on a slow box');

  final String label;
  final String description;

  const VideoOutput(this.label, this.description);

  /// Whether this device has a choice to make at all.
  static bool get isConfigurable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// What the user picked in Settings. Latched in `main()` from Hive, like
  /// `kIsTv`, so every player reads the same value without a provider.
  static VideoOutput preference = VideoOutput.auto;

  /// The last output verified to show a picture on this device, persisted so
  /// a box that needs a fallback does not spend a black first channel on
  /// rediscovering it after every launch.
  static VideoOutput learned = VideoOutput.hardware;

  /// The output a newly created player should use.
  static VideoOutput get effective =>
      preference == VideoOutput.auto ? learned : preference;

  /// The next output to try after this one showed no picture, cheapest
  /// compromise first. Direct comes before software because it costs nothing
  /// in smoothness; software decoding is the last resort.
  VideoOutput? get fallback => switch (this) {
        VideoOutput.auto || VideoOutput.hardware => VideoOutput.direct,
        VideoOutput.direct => VideoOutput.software,
        VideoOutput.software => null,
      };

  VideoControllerConfiguration get configuration {
    if (!isConfigurable) {
      return VideoControllerConfiguration(
        enableHardwareAcceleration: StreamTuning.enableHardwareAcceleration,
      );
    }
    return switch (this) {
      VideoOutput.auto ||
      VideoOutput.hardware =>
        const VideoControllerConfiguration(enableHardwareAcceleration: true),
      // mpv's mediacodec_embed renders without any GL at all. media_kit
      // re-selects the video track itself when the surface arrives in this
      // mode, which is what makes it work.
      VideoOutput.direct => const VideoControllerConfiguration(
          vo: 'mediacodec_embed',
          hwdec: 'mediacodec',
        ),
      VideoOutput.software =>
        const VideoControllerConfiguration(enableHardwareAcceleration: false),
    };
  }
}
