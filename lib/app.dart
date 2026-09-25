import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'providers/tv_provider.dart';
import 'ui/screens/home_screen.dart';

class IPTVPlayerApp extends ConsumerWidget {
  const IPTVPlayerApp({super.key});

  /// Android TV's safe area: about 5% in from each edge, which at 1080p with
  /// density 2.0 is 48dp horizontally and 27dp vertically. Older sets really do
  /// crop this much.
  static const EdgeInsets _tvOverscan =
      EdgeInsets.symmetric(horizontal: 48, vertical: 27);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTv = ref.watch(isTvProvider);

    return MaterialApp(
      title: 'Definitely Not Cable',
      debugShowCheckedModeBanner: false,
      theme: isTv ? AppTheme.tvTheme : AppTheme.darkTheme,
      builder: isTv ? _applyOverscan : null,
      home: const HomeScreen(),
    );
  }

  /// Reserves the TV overscan margin by injecting it into [MediaQuery].
  ///
  /// Deliberately not a `Padding` around the app: that would letterbox the
  /// `Video` widget with black bars on all four sides. Injecting the inset into
  /// MediaQuery instead means every `SafeArea` already in the tree starts doing
  /// the right thing for free, the player's `Stack` - which has no SafeArea -
  /// stays full-bleed, and the `SafeArea` inside `showModalBottomSheet` is
  /// fixed as well.
  ///
  /// Added to the platform's own padding rather than replacing it, so a device
  /// that does report insets keeps them.
  static Widget _applyOverscan(BuildContext context, Widget? child) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        padding: mq.padding + _tvOverscan,
        viewPadding: mq.viewPadding + _tvOverscan,
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }
}
