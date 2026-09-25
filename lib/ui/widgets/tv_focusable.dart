import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A tappable region that a D-pad can also reach.
///
/// Exists because a bare [GestureDetector] is invisible to a remote: it creates
/// no focus node, so directional traversal cannot find it and Select has
/// nothing to activate. Material widgets built on `InkWell` - `ListTile`,
/// `IconButton`, `FilterChip` - are already focusable and do not need this;
/// this is for the places that were hand-rolled out of `GestureDetector` and a
/// decorated `Container`.
///
/// Built on [FocusableActionDetector] rather than `InkWell` so it needs no
/// `Material` ancestor (several call sites are inside a player `Stack` with no
/// Material in scope) and so the focus decoration is drawn explicitly rather
/// than as a translucent ink overlay that would be invisible on a dark theme.
///
/// Pointer taps keep working unchanged, so phone and desktop behaviour is the
/// same as the `GestureDetector` this replaces.
class TvFocusable extends StatefulWidget {
  final Widget child;

  /// Invoked by a pointer tap and by Select / Enter / Space when focused.
  ///
  /// When null the region is inert and takes no focus, so a disabled control
  /// does not become a dead stop in the traversal order.
  final VoidCallback? onTap;

  final bool autofocus;
  final FocusNode? focusNode;

  /// Corner radius of the focus ring. Match the child's own radius.
  final BorderRadius borderRadius;

  final String? semanticLabel;

  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.semanticLabel,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // Flutter's default shortcuts already map Enter, Space, numpadEnter,
    // gameButtonA and - importantly for TV - LogicalKeyboardKey.select (the
    // D-pad centre, Android keycode 23) onto ActivateIntent. So binding
    // ActivateIntent here is all that is needed to make the remote's OK button
    // work; there is no key mapping to write.
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.onTap != null,
      mouseCursor: SystemMouseCursors.click,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (focused) {
        if (focused != _focused) setState(() => _focused = focused);
      },
      child: Semantics(
        label: widget.semanticLabel,
        button: widget.onTap != null,
        child: GestureDetector(
          onTap: widget.onTap,
          // foregroundDecoration, not decoration: a border in the latter is
          // added to the box's padding, so focusing a control would reflow
          // everything around it. Painted over the child instead, the ring
          // costs no layout.
          child: Container(
            foregroundDecoration: _focused
                ? BoxDecoration(
                    borderRadius: widget.borderRadius,
                    border: Border.all(
                      color: AppTheme.accentColor,
                      width: 3,
                    ),
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
