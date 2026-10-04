import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';

/// A scrubber for VOD that works the same from a finger, a mouse and a remote.
///
/// Not a Material [Slider], deliberately. Slider binds all four arrow keys to
/// value changes in traditional navigation mode and reports them handled, so on
/// a remote Up/Down could never move focus off it - the same trap
/// `TvTextField` exists to defuse. This claims Left/Right only; Up/Down fall
/// through to normal traversal.
///
/// It owns no position state. The host decides what a step is worth and when
/// a seek is committed, so a held D-pad can accumulate one target rather than
/// issuing a seek per key repeat against a network stream.
class SeekBar extends StatefulWidget {
  /// What to draw - the pending target while one is in flight, else playback.
  final Duration position;
  final Duration duration;

  /// End of the buffered range, as an absolute media timestamp.
  final Duration buffered;

  /// A Left (-1) or Right (+1) press. [repeat] is true for a held key.
  final void Function(int direction, bool repeat) onStep;

  /// Select / Enter while focused. Play/pause, as on most TV players.
  final VoidCallback? onActivate;

  /// Pointer scrubbing: a drag or tap at a fraction of the width.
  final ValueChanged<Duration> onScrubUpdate;
  final ValueChanged<Duration> onScrubEnd;

  final FocusNode? focusNode;

  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    required this.onStep,
    this.onActivate,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    this.focusNode,
  });

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  bool _focused = false;
  bool _dragging = false;

  /// Select's key-up has to be consumed too, or it reaches the activity.
  bool _swallowSelectUp = false;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isLeft = key == LogicalKeyboardKey.arrowLeft;
    final isRight = key == LogicalKeyboardKey.arrowRight;

    if (isLeft || isRight) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        widget.onStep(isLeft ? -1 : 1, event is KeyRepeatEvent);
      }
      return KeyEventResult.handled;
    }

    final isSelect = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (isSelect && widget.onActivate != null) {
      if (event is KeyDownEvent) {
        _swallowSelectUp = true;
        widget.onActivate!();
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent && _swallowSelectUp) {
        _swallowSelectUp = false;
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // Up/Down and everything else: let traversal and the player have them.
    return KeyEventResult.ignored;
  }

  Duration _positionAt(double dx, double width) {
    if (width <= 0) return Duration.zero;
    final fraction = (dx / width).clamp(0.0, 1.0);
    return widget.duration * fraction;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    double fractionOf(Duration d) =>
        total <= 0 ? 0 : (d.inMilliseconds / total).clamp(0.0, 1.0);

    final played = fractionOf(widget.position);
    final buffered = fractionOf(widget.buffered);
    final emphasised = _focused || _dragging;

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _handleKey,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: Semantics(
        slider: true,
        label: 'Seek',
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) =>
                  widget.onScrubEnd(_positionAt(details.localPosition.dx, width)),
              onHorizontalDragStart: (details) {
                setState(() => _dragging = true);
                widget.onScrubUpdate(
                    _positionAt(details.localPosition.dx, width));
              },
              onHorizontalDragUpdate: (details) => widget.onScrubUpdate(
                  _positionAt(details.localPosition.dx, width)),
              onHorizontalDragEnd: (_) {
                setState(() => _dragging = false);
                widget.onScrubEnd(widget.position);
              },
              onHorizontalDragCancel: () => setState(() => _dragging = false),
              // Tall hit area so a thumb can grab it; the bar itself is thin.
              child: SizedBox(
                height: 36,
                child: CustomPaint(
                  painter: _SeekBarPainter(
                    played: played,
                    buffered: buffered,
                    emphasised: emphasised,
                    focused: _focused,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SeekBarPainter extends CustomPainter {
  final double played;
  final double buffered;
  final bool emphasised;
  final bool focused;

  _SeekBarPainter({
    required this.played,
    required this.buffered,
    required this.emphasised,
    required this.focused,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackHeight = emphasised ? 6.0 : 4.0;
    final thumbRadius = emphasised ? 9.0 : 6.0;
    // Inset by the largest thumb so it never clips at either end.
    const inset = 10.0;
    const left = inset;
    final right = size.width - inset;
    final width = (right - left).clamp(0.0, double.infinity);
    final cy = size.height / 2;

    RRect bar(double from, double to) => RRect.fromLTRBR(
          left + width * from,
          cy - trackHeight / 2,
          left + width * to,
          cy + trackHeight / 2,
          Radius.circular(trackHeight / 2),
        );

    canvas.drawRRect(bar(0, 1), Paint()..color = Colors.white24);
    if (buffered > played) {
      canvas.drawRRect(bar(0, buffered), Paint()..color = Colors.white38);
    }
    canvas.drawRRect(bar(0, played), Paint()..color = AppTheme.primaryColor);

    final thumb = Offset(left + width * played, cy);
    if (focused) {
      // A ring visible across a room, matching the TV theme's focus treatment.
      canvas.drawCircle(
        thumb,
        thumbRadius + 5,
        Paint()..color = Colors.white.withValues(alpha: 0.35),
      );
    }
    canvas.drawCircle(thumb, thumbRadius, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SeekBarPainter old) =>
      old.played != played ||
      old.buffered != buffered ||
      old.emphasised != emphasised ||
      old.focused != focused;
}
