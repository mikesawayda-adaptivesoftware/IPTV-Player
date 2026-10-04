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

  Future<void> hideKeyboard(WidgetTester tester) async {
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
  }

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

  testWidgets('Fields are editable and accept typing', (tester) async {
    await pumpForm(tester);
    expect(field(tester, 0).readOnly, isFalse);

    tester.testTextInput.enterText('my provider');
    await tester.pump();
    expect(controllers[0].text, 'my provider');

    // Still leaves the field with text in it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(tester, 1), isTrue);
  });

  testWidgets('OK brings the keyboard back after it was dismissed',
      (tester) async {
    await pumpForm(tester);
    await hideKeyboard(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(focused(tester, 0), isTrue);
  });

  testWidgets('A stray OK release does not open the keyboard', (tester) async {
    await pumpForm(tester);
    await hideKeyboard(tester);

    // The release of the OK press that opened the dialog lands on the
    // autofocused field without its key-down.
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('A tap opens the keyboard', (tester) async {
    await pumpForm(tester);
    await tester.tap(find.byType(TextField).at(1));
    await tester.pumpAndSettle();
    expect(focused(tester, 1), isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    tester.testTextInput.enterText('http://server:8080');
    await tester.pump();
    expect(controllers[1].text, 'http://server:8080');
  });
}
