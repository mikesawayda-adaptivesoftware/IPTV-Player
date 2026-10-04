import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/platform/tv_platform.dart';
import 'package:iptv_player/ui/widgets/tv_text_field.dart';

/// Drives a form the way a remote does: arrow keys and Select only.
void main() {
  setUpAll(() => TvPlatform.resolveIsTv(override: TvModeOverride.forceTv));

  late List<TextEditingController> controllers;
  late FocusNode buttonNode;

  Future<void> pumpForm(WidgetTester tester) async {
    controllers = List.generate(3, (_) => TextEditingController());
    buttonNode = FocusNode();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TvTextField(controller: controllers[0], autofocus: true),
            TvTextField(controller: controllers[1]),
            TvTextField(controller: controllers[2]),
            ElevatedButton(
              focusNode: buttonNode,
              onPressed: () {},
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  TextField field(WidgetTester tester, int i) =>
      tester.widgetList<TextField>(find.byType(TextField)).elementAt(i);

  bool focused(WidgetTester tester, int i) =>
      field(tester, i).focusNode!.hasPrimaryFocus;

  testWidgets('Down walks the fields and reaches the button', (tester) async {
    await pumpForm(tester);
    expect(focused(tester, 0), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focused(tester, 1), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(buttonNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focused(tester, 2), isTrue);
  });

  testWidgets('Focus alone does not open the keyboard; Select does',
      (tester) async {
    await pumpForm(tester);
    expect(field(tester, 0).readOnly, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(field(tester, 0).readOnly, isFalse);
    expect(tester.testTextInput.isVisible, isTrue);

    tester.testTextInput.enterText('my provider');
    await tester.pump();
    expect(controllers[0].text, 'my provider');

    // Still leaves the field while editing.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(tester, 1), isTrue);
    expect(field(tester, 0).readOnly, isTrue);
    expect(field(tester, 1).readOnly, isTrue);
  });
}
