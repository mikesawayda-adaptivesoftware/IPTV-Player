import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/tv_platform.dart';

/// A [TextField] a D-pad can move into, type into, and move out of again.
///
/// Off TV this is a plain [TextField] and behaves exactly like one.
///
/// On TV a stock [TextField] is a dead end: `DefaultTextEditingShortcuts`
/// binds the arrow keys to caret movement, and in a single-line field Up/Down
/// move the caret to the start/end and report the key handled - so the
/// directional traversal binding further up the tree never sees them. A
/// remote has no Tab key, so a focused field could only be left with Back,
/// which closes the whole dialog.
///
/// So on TV this intercepts the D-pad above the field: Up/Down always move
/// focus, and Left/Right do once the caret is already at that end of the text.
/// OK asks for the keyboard explicitly.
///
/// The field itself is otherwise left completely stock - editable, and opening
/// the keyboard on focus and on tap exactly as Flutter does everywhere else.
/// An earlier version kept it read-only until OK to stop the keyboard popping
/// on every focus change; on a real TV that never opened for typing at all,
/// and a working field that shows its keyboard eagerly beats a tidy one that
/// cannot be typed into.
class TvTextField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration? decoration;
  final bool obscureText;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const TvTextField({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.obscureText = false,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _fieldKey = GlobalKey();

  /// Select went down while this field had focus, so its key-up is ours. A
  /// key-up without one (the OK press that opened the dialog, landing on the
  /// autofocused field) is swallowed and does nothing.
  bool _selectDown = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  static bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter;

  EditableTextState? _editable() {
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    (_fieldKey.currentContext as Element?)?.visitChildren(visit);
    return found;
  }

  /// The same call a tap makes: opens the input connection if it is not open
  /// and shows the keyboard either way, including after Back dismissed it.
  void _showKeyboard() => _editable()?.requestKeyboard();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Keys from a focusable inside the decoration (a search field's clear
    // button) bubble through here too; those are not ours to reinterpret.
    if (!_focusNode.hasPrimaryFocus) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final selection = widget.controller.selection;
    final text = widget.controller.text;
    final atStart =
        !selection.isValid || (selection.isCollapsed && selection.start == 0);
    final atEnd = !selection.isValid ||
        (selection.isCollapsed && selection.end == text.length);

    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft when atStart => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight when atEnd => TraversalDirection.right,
      _ => null,
    };
    if (direction != null) {
      if (event is! KeyUpEvent) _focusNode.focusInDirection(direction);
      return KeyEventResult.handled;
    }

    if (_isSelect(key)) {
      // Acts on key-up, as a native Android TV text field does, and claims
      // both edges so neither reaches the input connection as an editor
      // action.
      if (event is KeyDownEvent) {
        _selectDown = true;
      } else if (event is KeyUpEvent && _selectDown) {
        _selectDown = false;
        _showKeyboard();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _onEditingComplete() {
    switch (widget.textInputAction) {
      case TextInputAction.next:
        _focusNode.nextFocus();
      case TextInputAction.previous:
        _focusNode.previousFocus();
      default:
        // The default unfocuses, which on a remote strands the D-pad with
        // nothing to move from. Keep focus and just put the keyboard away.
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      key: _fieldKey,
      controller: widget.controller,
      focusNode: _focusNode,
      decoration: widget.decoration,
      obscureText: widget.obscureText,
      autofocus: widget.autofocus,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onEditingComplete: kIsTv ? _onEditingComplete : null,
    );

    if (!kIsTv) return field;

    // Not focusable itself: it only intercepts keys bubbling up from the
    // field's own node, ahead of DefaultTextEditingShortcuts higher up.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: field,
    );
  }
}
