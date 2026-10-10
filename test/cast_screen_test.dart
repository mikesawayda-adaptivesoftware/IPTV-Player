import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/cast/cast_bridge.dart';
import 'package:iptv_player/core/cast/cast_controller.dart';
import 'package:iptv_player/data/models/channel.dart';
import 'package:iptv_player/providers/cast_provider.dart';
import 'package:iptv_player/ui/screens/cast_screen.dart';
import 'package:iptv_player/ui/widgets/cast_bar.dart';

/// Holds a fixed state and records what the UI asks of it.
class _StaticController extends CastController {
  final List<String> asked = [];

  _StaticController(CastState initial) {
    state = initial;
  }

  @override
  Future<void> stop() async {
    asked.add('stop');
    state = const CastState();
  }

  @override
  Future<void> step(bool forward) async => asked.add(forward ? 'next' : 'previous');

  @override
  Future<void> togglePause() async => asked.add('pause');

  @override
  Future<void> seek(Duration position) async => asked.add('seek ${position.inSeconds}');

  @override
  Future<void> setVolume(double level) async => asked.add('volume');
}

const _channel = Channel(id: '1', name: 'News HD', streamUrl: 'http://p/live/u/p/1.ts');

const _live = CastState(
  phase: CastPhase.casting,
  device: 'Living Room',
  media: CastMedia.live(_channel),
  receiver: ReceiverStatus(ReceiverState.playing),
);

const _film = CastState(
  phase: CastPhase.casting,
  device: 'Living Room',
  media: CastMedia.movie(url: 'http://p/movie/u/p/9.mp4', title: 'A Film'),
  receiver: ReceiverStatus(ReceiverState.playing),
  progress: CastProgress(Duration(minutes: 10), Duration(minutes: 90)),
);

Future<_StaticController> _pump(WidgetTester tester, CastState state, Widget child) async {
  final controller = _StaticController(state);
  await tester.pumpWidget(ProviderScope(
    overrides: [castProvider.overrideWith((ref) => controller)],
    child: MaterialApp(home: child),
  ));
  return controller;
}

void main() {
  testWidgets('live: channel controls and stop', (tester) async {
    final controller = await _pump(tester, _live, const CastScreen());
    expect(find.text('News HD'), findsOneWidget);
    expect(find.text('Playing on Living Room'), findsOneWidget);

    await tester.tap(find.byTooltip('Next channel'));
    await tester.tap(find.byTooltip('Previous channel'));
    expect(controller.asked, ['next', 'previous']);

    await tester.scrollUntilVisible(find.text('Stop casting'), 100);
    await tester.tap(find.text('Stop casting'));
    await tester.pump();
    expect(controller.asked.last, 'stop');
  });

  testWidgets('film: seek and pause', (tester) async {
    final controller = await _pump(tester, _film, const CastScreen());
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('1:30:00'), findsOneWidget);

    await tester.tap(find.byTooltip('Forward 30 seconds'));
    await tester.tap(find.byTooltip('Pause'));
    expect(controller.asked, ['seek 630', 'pause']);
  });

  testWidgets('an uncastable channel says so', (tester) async {
    await _pump(
      tester,
      _live.copyWith(error: "This channel's video is MPEG-2", unsupported: true),
      const CastScreen(),
    );
    expect(find.text("Can't play on the Chromecast"), findsOneWidget);
    expect(find.text("This channel's video is MPEG-2"), findsOneWidget);
  });

  testWidgets('the bar shows what is on and stops it', (tester) async {
    final controller = await _pump(tester, _live, const Scaffold(body: CastBar()));
    expect(find.text('News HD'), findsOneWidget);
    expect(find.text('Casting to Living Room'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop casting'));
    await tester.pump();
    expect(controller.asked, ['stop']);
    expect(find.text('News HD'), findsNothing);
  });
}
