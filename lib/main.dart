import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'data/models/channel.dart';
import 'data/models/vod_item.dart';
import 'data/models/playlist_source.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize MediaKit
  MediaKit.ensureInitialized();
  
  // Initialize Hive
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
  await Hive.openBox('settings');
  
  runApp(
    const ProviderScope(
      child: IPTVPlayerApp(),
    ),
  );
}

