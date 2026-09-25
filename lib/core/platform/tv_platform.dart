import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether this device is a TV, resolved once before `runApp`.
///
/// A plain global rather than only a Riverpod provider, deliberately. Every
/// device-shape decision in this app flows through `ContextExtensions` in
/// `core/utils/extensions.dart` and through `AppTheme`, both of which are
/// static and hold no `ref` - so a provider-only answer would mean threading a
/// `ref` through every `isDesktop` call site, or maintaining two parallel
/// mechanisms. `isTvProvider` exists as well, for code that already has a ref.
///
/// Safe to resolve once: the activity declares `uiMode` in its configChanges,
/// so TV-ness cannot change while the app is running.
bool get kIsTv => _isTv;
bool _isTv = false;

/// Forces [kIsTv] regardless of what the platform reports.
///
/// Exists so the TV layout can be exercised on a desktop without a TV box, and
/// so a detection bug is a toggle rather than an unrecoverable wrong UI. Driven
/// by the override setting in the Settings screen.
enum TvModeOverride {
  auto('Automatic', 'Detect the device - TV layout only on a TV'),
  forceTv('Force TV layout', 'Use the 10-foot layout and D-pad focus here'),
  forceTouch('Force touch layout', 'Use the phone/desktop layout even on a TV');

  final String label;
  final String description;

  const TvModeOverride(this.label, this.description);
}

/// Platform hooks that have no Flutter plugin equivalent.
class TvPlatform {
  TvPlatform._();

  static const MethodChannel _channel =
      MethodChannel('com.adaptivesoftware.iptvplayer/platform');

  /// Asks the host whether this is a TV and latches the answer into [kIsTv].
  ///
  /// Call once from `main()` before `runApp`. [override] short-circuits the
  /// platform call entirely.
  static Future<bool> resolveIsTv({
    TvModeOverride override = TvModeOverride.auto,
  }) async {
    switch (override) {
      case TvModeOverride.forceTv:
        _isTv = true;
        return _isTv;
      case TvModeOverride.forceTouch:
        _isTv = false;
        return _isTv;
      case TvModeOverride.auto:
        break;
    }

    // Only Android has a TV form factor here; there is no ios/ or web/ target
    // and the desktop targets are never televisions.
    if (defaultTargetPlatform != TargetPlatform.android) {
      _isTv = false;
      return _isTv;
    }

    try {
      _isTv = await _channel.invokeMethod<bool>('isTelevision') ?? false;
    } on MissingPluginException {
      // Running against a host that predates the channel - treat as not-a-TV
      // rather than failing to start.
      _isTv = false;
    } catch (e) {
      print('TvPlatform: could not determine device type ($e)');
      _isTv = false;
    }
    return _isTv;
  }

  static int _awakeHolders = 0;

  /// Claims a keep-awake hold for one player.
  ///
  /// Reference counted because the mini player and the full-screen player can
  /// be alive at the same time, and in multi-view four players are. A plain
  /// setter would let whichever disposed last put the screen to sleep while
  /// another was still playing. Pair every call with [releaseKeepScreenOn].
  static Future<void> acquireKeepScreenOn() async {
    _awakeHolders++;
    if (_awakeHolders == 1) await _setKeepScreenOn(true);
  }

  /// Releases one hold; the screen may sleep again once all are released.
  static Future<void> releaseKeepScreenOn() async {
    if (_awakeHolders == 0) return;
    _awakeHolders--;
    if (_awakeHolders == 0) await _setKeepScreenOn(false);
  }

  static Future<void> _setKeepScreenOn(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(
        'setKeepScreenOn',
        <String, Object?>{'enabled': enabled},
      );
    } catch (e) {
      print('TvPlatform: could not set keep-screen-on ($e)');
    }
  }
}
