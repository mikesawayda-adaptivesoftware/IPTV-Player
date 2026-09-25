import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../core/platform/tv_platform.dart';
import '../data/services/storage_service.dart';

/// Whether this device is a TV, for code that already holds a `ref`.
///
/// Reads the global latched by `TvPlatform.resolveIsTv` in `main()` rather than
/// resolving anything itself, so this and `context.isTv` can never disagree.
/// Widgets without a ref should use `context.isTv`; `AppTheme` and
/// `ContextExtensions` are static and can only see the global.
final isTvProvider = Provider<bool>((ref) => kIsTv);

/// Debug override for the device-type detection.
///
/// Same shape as `bufferModeProvider`: read straight from Hive here, written at
/// the settings call site. Takes effect on the next launch, because `kIsTv` is
/// latched before `runApp` so that the first frame is already the right layout.
final tvModeOverrideProvider = StateProvider<TvModeOverride>((ref) {
  final storage = StorageService();
  final saved = storage.getSetting<int>(
    AppConstants.settingTvModeOverride,
    defaultValue: 0,
  );
  return TvModeOverride.values[saved ?? 0];
});
