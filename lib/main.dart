import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/platform/tv_platform.dart';
import 'data/models/channel.dart';
import 'data/models/vod_item.dart';
import 'data/models/playlist_source.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set up error handlers
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    print('Flutter Error: ${details.exception}');
    print('Stack trace: ${details.stack}');
  };
  
  // Initialize MediaKit
  print('Initializing MediaKit...');
  MediaKit.ensureInitialized();
  print('MediaKit initialized');
  
  // Initialize Hive
  print('Initializing Hive...');
  await Hive.initFlutter();
  
  // Register Hive adapters
  Hive.registerAdapter(ChannelAdapter());
  Hive.registerAdapter(VODItemAdapter());
  Hive.registerAdapter(PlaylistSourceAdapter());
  Hive.registerAdapter(PlaylistTypeAdapter());
  
  // Open Hive boxes
  await Hive.openBox<Channel>('favorites_channels');
  await Hive.openBox<VODItem>('favorites_vod');
  await Hive.openBox<Channel>('history_channels');
  await Hive.openBox<VODItem>('history_vod');
  await Hive.openBox<PlaylistSource>('playlist_sources');
  final settings = await Hive.openBox('settings');
  print('Hive initialized');

  // Before runApp, because kIsTv decides the theme and every layout branch -
  // resolving it later would mean a visible re-layout on first frame. The
  // override is read straight from Hive rather than through a provider for the
  // same reason: the providers do not exist yet at this point.
  final overrideIndex =
      settings.get(AppConstants.settingTvModeOverride, defaultValue: 0) as int?;
  final override = TvModeOverride.values[overrideIndex ?? 0];
  final isTv = await TvPlatform.resolveIsTv(override: override);
  print('Device type: ${isTv ? "TV (D-pad)" : "touch/pointer"}'
      '${override == TvModeOverride.auto ? "" : " [overridden: ${override.name}]"}');

  // No ProviderScope overrides needed: isTvProvider and tvModeOverrideProvider
  // both read what has already been latched above, so there is one source of
  // truth and the provider and the global cannot disagree.
  runApp(
    const ProviderScope(
      child: IPTVPlayerApp(),
    ),
  );
}

