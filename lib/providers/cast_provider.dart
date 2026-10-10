import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cast/cast_controller.dart';
import '../core/platform/tv_platform.dart';
import 'playlist_provider.dart';

/// The app's one Cast session. Lives for the whole app, so a cast carries on
/// while the person browses.
final castProvider = StateNotifierProvider<CastController, CastState>((ref) {
  return CastController(
    stepChannel: (current, forward) {
      final channels = ref.read(channelStateProvider.notifier);
      return forward
          ? channels.getNextChannel(current)
          : channels.getPreviousChannel(current);
    },
    onWatched: (channel) =>
        ref.read(channelStateProvider.notifier).markAsWatched(channel),
  );
});

/// Casting is phone-only: Google's Cast SDK is Android-only here, and a TV
/// is a cast target rather than a sender.
bool get canCast =>
    !kIsWeb && !kIsTv && defaultTargetPlatform == TargetPlatform.android;
