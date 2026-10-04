import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/player/seek_bar.dart';

/// The VOD seek bar driven the way a remote and a finger drive it.
void main() {
  late List<String> steps;
  late List<Duration> scrubs;
  late Duration? committed;
  late int activations;
  late FocusNode seekNode;
  late FocusNode aboveNode;
  late FocusNode belowNode;

  Future<void> pump(WidgetTester tester) async {
    steps = [];
    scrubs = [];
    committed = null;
    activations = 0;
    seekNode = FocusNode();
    aboveNode = FocusNode();
    belowNode = FocusNode();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            ElevatedButton(
              focusNode: aboveNode,
              onPressed: () {},
              child: const Text('Play'),
            ),
            SizedBox(
              width: 400,
              child: SeekBar(
                focusNode: seekNode,
                position: const Duration(minutes: 30),
                duration: const Duration(minutes: 100),
                onStep: (direction, repeat) =>
                    steps.add('${direction > 0 ? '+' : '-'}${repeat ? 'r' : ''}'),
                onActivate: () => activations++,
                onScrubUpdate: scrubs.add,
                onScrubEnd: (d) => committed = d,
              ),
            ),
            ElevatedButton(
              focusNode: belowNode,
              onPressed: () {},
              child: const Text('Mute'),
            ),
          ],
        ),
      ),
    ));
    seekNode.requestFocus();
    await tester.pump();
  }

  testWidgets('Left and Right step, including held repeats', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(steps, ['+', '-', '+', '+r']);
    expect(seekNode.hasPrimaryFocus, isTrue);
  });

  testWidgets('Up and Down leave the bar instead of trapping focus',
      (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(belowNode.hasPrimaryFocus, isTrue);

    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(aboveNode.hasPrimaryFocus, isTrue);
    expect(steps, isEmpty);
  });

  testWidgets('Select toggles playback', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activations, 1);
  });

  testWidgets('a tap seeks to that point of the bar', (tester) async {
    await pump(tester);
    final bar = tester.getRect(find.byType(SeekBar));
    await tester.tapAt(Offset(bar.left + bar.width * 0.75, bar.center.dy));
    await tester.pump();
    expect(committed, isNotNull);
    expect(committed!.inMinutes, inInclusiveRange(70, 80));
  });

  testWidgets('a drag scrubs and commits once', (tester) async {
    await pump(tester);
    final bar = tester.getRect(find.byType(SeekBar));
    await tester.dragFrom(
      Offset(bar.left + 20, bar.center.dy),
      Offset(bar.width * 0.5, 0),
    );
    await tester.pump();
    expect(scrubs, isNotEmpty);
    expect(committed, isNotNull);
  });
}
