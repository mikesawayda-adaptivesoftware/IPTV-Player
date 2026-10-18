import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tv_platform.dart';

/// Android picture-in-picture: leaving the app while a video plays shrinks it
/// to a floating window over other apps.
///
/// The window is this same activity drawn small, so it is the same `Player`
/// and the same provider connection - nothing is reopened going in or coming
/// back, which matters with a provider that allows one stream. What changes is
/// only what the player draws: while [active] it shows bare video, because
/// controls at that size are unreadable and cannot be touched anyway (Android
/// routes taps on the window to its own overlay, whose expand button brings
/// the app back).
///
/// Phone only. A TV launcher has no "over other apps" to float above, and
/// Home on a remote should stop the programme, which the players already do.
class PictureInPicture {
  PictureInPicture._();

  static const MethodChannel _channel =
      MethodChannel('com.adaptivesoftware.iptvplayer/pip');

  /// Whether the app is in the floating window right now.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  static final List<PipClaim> _claims = [];
  static bool _listening = false;

  static bool get _supported =>
      !kIsWeb && !kIsTv && defaultTargetPlatform == TargetPlatform.android;

  /// Registers a full-screen player as the one PiP would show.
  ///
  /// A stack rather than a flag: the newest claim speaks for the screen, and
  /// releasing it hands back to whatever player is underneath. Starts
  /// disabled; the player turns it on with [PipClaim.update] once it is
  /// actually playing. [onDismissed] runs when the user closes the floating
  /// window rather than expanding it, so the player can stop holding the
  /// stream for a window nobody can see.
  static PipClaim claim({VoidCallback? onDismissed}) {
    _listen();
    final claim = PipClaim._(onDismissed);
    _claims.add(claim);
    _push();
    return claim;
  }

  static void _listen() {
    if (_listening || !_supported) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'modeChanged':
          active.value = call.arguments == true;
        case 'dismissed':
          active.value = false;
          if (_claims.isNotEmpty) _claims.last._onDismissed?.call();
      }
    });
  }

  /// Tells the activity what the top claim wants. Android reads this when the
  /// user leaves the app, so it has to be current before they do.
  static Future<void> _push() async {
    if (!_supported) return;
    final top = _claims.isEmpty ? null : _claims.last;
    final enabled = top?._enabled ?? false;
    final aspect = top?._aspect;
    try {
      await _channel.invokeMethod<void>('configure', <String, Object?>{
        'enabled': enabled,
        if (aspect != null) 'width': aspect.width.round(),
        if (aspect != null) 'height': aspect.height.round(),
      });
    } on MissingPluginException {
      // A host without the channel simply never offers PiP.
    } catch (e) {
      print('PictureInPicture: could not configure ($e)');
    }
  }
}

/// One player's say in whether leaving the app goes to picture-in-picture.
class PipClaim {
  PipClaim._(this._onDismissed);

  final VoidCallback? _onDismissed;
  bool _enabled = false;
  Size? _aspect;
  bool _released = false;

  /// [enabled] is whether leaving now should float the video: playing, and
  /// not handed to a Chromecast. [videoSize] shapes the window to the picture;
  /// without it Android's default is used.
  void update({required bool enabled, Size? videoSize}) {
    if (_released) return;
    final aspect =
        videoSize != null && videoSize.width > 0 && videoSize.height > 0
            ? videoSize
            : _aspect;
    if (enabled == _enabled && aspect == _aspect) return;
    _enabled = enabled;
    _aspect = aspect;
    PictureInPicture._push();
  }

  void release() {
    if (_released) return;
    _released = true;
    PictureInPicture._claims.remove(this);
    PictureInPicture._push();
  }
}
