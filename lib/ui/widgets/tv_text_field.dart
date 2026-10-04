import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/tv_platform.dart';

/// A [TextField] a D-pad can move into, type into, and move out of again.
///
/// Off TV this is a plain [TextField] and behaves exactly like one.
///
/// On TV a stock [TextField] is a dead end, for two reasons:
///
/// - **Up/Down never leave it.** `DefaultTextEditingShortcuts` binds the arrow
///   keys to caret movement, and in a single-line field Up/Down move the caret
///   to the start/end and report the key handled - so the directional
///   traversal binding further up the tree never sees them. A remote has no
///   Tab key, so a focused field could only be left with Back, which closes the
///   whole dialog.
/// - **Focus opens the keyboard.** `EditableText` shows the IME whenever it
///   gains focus, so D-padding down a form of four fields would pop a
///   full-screen TV keyboard four times on the way to the button.
///
/// So on TV the field is read-only until Select (the remote's OK) is pressed,
/// the way native Android TV text fields behave: focusing it just highlights
/// it, OK opens the keyboard, and Up/Down always move focus (Left/Right too,
/// until it is being edited). The IME's Next key
/// carries editing on to the following field so a form can still be filled in
/// one keyboard session.
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
  /// Set when the IME's Next key moves focus out of a field, so the field that
  /// receives focus opens its keyboard straight away instead of making the
  /// user press OK again. Cleared after the frame whatever got focus, so a
  /// button landing the focus cannot leave it armed for a later field.
  static bool _continueEditing = false;

  final FocusNode _focusNode = FocusNode();

  /// Whether the keyboard is allowed: false means read-only and no IME.
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!kIsTv) return;
    if (_focusNode.hasFocus) {
      if (_continueEditing) {
        _continueEditing = false;
        setState(() => _editing = true);
      }
    } else if (_editing) {
      setState(() => _editing = false);
    }
  }

  static bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Keys from a focusable inside the decoration (a search field's clear
    // button) bubble through here too; those are not ours to reinterpret.
    if (!_focusNode.hasPrimaryFocus) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Up/Down always leave the field. Left/Right do too until the field is
    // being edited - before that a caret has nothing to do, and a search
    // field beside the navigation rail would otherwise be a dead end.
    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft when !_editing => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight when !_editing => TraversalDirection.right,
      _ => null,
    };
    if (direction != null) {
      if (event is! KeyUpEvent) _focusNode.focusInDirection(direction);
      return KeyEventResult.handled;
    }

    if (_isSelect(key)) {
      if (event is KeyDownEvent) {
        if (_editing) {
          // Back dismisses the IME but leaves the field connected; OK should
          // bring the keyboard back rather than do nothing.
          SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        } else {
          setState(() => _editing = true);
        }
        return KeyEventResult.handled;
      }
      // Key-up and repeats are consumed too: an unclaimed up would reach the
      // now-connected field, where Android's input connection treats it as an
      // editor action.
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _onEditingComplete() {
    switch (widget.textInputAction) {
      case TextInputAction.next:
        _continueEditing = true;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _continueEditing = false);
        _focusNode.nextFocus();
      case TextInputAction.previous:
        _continueEditing = true;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _continueEditing = false);
        _focusNode.previousFocus();
      default:
        // Keep focus on the field so the D-pad has somewhere to start from;
        // the default would unfocus and strand it. Dropping out of editing
        // closes the keyboard.
        setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      decoration: widget.decoration,
      obscureText: widget.obscureText,
      autofocus: widget.autofocus,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      readOnly: kIsTv && !_editing,
      showCursor: kIsTv ? _editing : null,
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
