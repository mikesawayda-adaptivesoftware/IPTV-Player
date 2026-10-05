import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:iptv_player/core/constants/app_constants.dart';
import 'package:iptv_player/core/platform/tv_platform.dart';
import 'package:iptv_player/core/theme/app_theme.dart';
import 'package:iptv_player/data/models/channel.dart';
import 'package:iptv_player/data/models/playlist_source.dart';
import 'package:iptv_player/data/models/vod_item.dart';
import 'package:iptv_player/providers/navigation_provider.dart';
import 'package:iptv_player/ui/screens/home_screen.dart';
import 'package:iptv_player/ui/widgets/tv_focusable.dart';

/// Drives the shell the way a remote does: arrows, OK and Back.
void main() {
  late Directory hiveDir;

  setUpAll(() async {
    await TvPlatform.resolveIsTv(override: TvModeOverride.forceTv);
    hiveDir = await Directory.systemTemp.createTemp('tv_nav_test');
    Hive.init(hiveDir.path);
    Hive.registerAdapter(ChannelAdapter());
    Hive.registerAdapter(VODItemAdapter());
    Hive.registerAdapter(PlaylistSourceAdapter());
    Hive.registerAdapter(PlaylistTypeAdapter());
    await Hive.openBox<Channel>(AppConstants.favoritesChannelsBox);
    await Hive.openBox<VODItem>(AppConstants.favoritesVodBox);
    await Hive.openBox<Channel>(AppConstants.historyChannelsBox);
    await Hive.openBox<VODItem>(AppConstants.historyVodBox);
    await Hive.openBox<PlaylistSource>(AppConstants.playlistSourcesBox);
    await Hive.openBox(AppConstants.settingsBox);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  late ProviderContainer container;

  Future<void> pumpShell(WidgetTester tester) async {
    // A 1080p TV at density 2.0.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.tvTheme, home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();
  }

  String? focusedLabel() =>
      FocusManager.instance.primaryFocus?.debugLabel;

  HomeTab tab() => container.read(homeTabProvider);

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('starts with the rail focused and has no bottom bar',
      (tester) async {
    await pumpShell(tester);
    expect(focusedLabel(), 'TV rail Live TV');
    expect(find.byType(BottomNavigationBar), findsNothing);
  });

  testWidgets('moving along the rail switches tabs', (tester) async {
    await pumpShell(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(), 'TV rail Movies');
    expect(tab(), HomeTab.movies);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(tab(), HomeTab.settings);
  });

  testWidgets('OK steps into the content, Back returns to the rail',
      (tester) async {
    await pumpShell(tester);
    await press(tester, LogicalKeyboardKey.select);
    expect(focusedLabel(), isNot(startsWith('TV rail')));
    expect(FocusManager.instance.primaryFocus, isNotNull);

    await back(tester);
    expect(focusedLabel(), 'TV rail Live TV');
  });

  testWidgets('entering the rail from content lands on the current tab',
      (tester) async {
    await pumpShell(tester);
    // With no playlist, Live TV is one button in the middle of the screen,
    // level with the lower rail items rather than with Live TV at the top.
    await press(tester, LogicalKeyboardKey.select);
    expect(focusedLabel(), isNot(startsWith('TV rail')));
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(), 'TV rail Live TV');
    expect(tab(), HomeTab.liveTv);
  });

  testWidgets('Back from the rail goes to Live TV before leaving',
      (tester) async {
    await pumpShell(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(tab(), HomeTab.movies);

    await back(tester);
    expect(tab(), HomeTab.liveTv);
    expect(focusedLabel(), 'TV rail Live TV');

    final exits = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        exits.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await back(tester);
    expect(exits.map((c) => c.method), contains('SystemNavigator.pop'));
  });

  testWidgets('focus lost from the content returns to the rail',
      (tester) async {
    await pumpShell(tester);
    await press(tester, LogicalKeyboardKey.select);
    final inContent = FocusManager.instance.primaryFocus!;
    expect(inContent.debugLabel, isNot(startsWith('TV rail')));

    // What a tab swapping its body does to the focused control.
    inContent.unfocus(disposition: UnfocusDisposition.scope);
    await tester.pumpAndSettle();
    expect(focusedLabel(), 'TV rail Live TV');
  });

  group('TvFocusable hold', () {
    Future<(List<String>, FocusNode)> pumpCard(WidgetTester tester) async {
      final events = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          focusNode: node,
          autofocus: true,
          onTap: () => events.add('tap'),
          onLongPress: () => events.add('long'),
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pump();
      return (events, node);
    }

    testWidgets('a short OK taps on release', (tester) async {
      final (events, _) = await pumpCard(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      expect(events, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      expect(events, ['tap']);
    });

    testWidgets('holding OK long-presses and does not tap', (tester) async {
      final (events, _) = await pumpCard(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      expect(events, ['long']);
    });
  });
}
