import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shell's tabs, in the order `HomeScreen` lays them out.
enum HomeTab { liveTv, movies, guide, settings }

/// Which tab the shell is showing.
///
/// A provider rather than `HomeScreen` state so that an empty state on one tab
/// can send the user to another - "No playlist configured" offers a button
/// straight to Settings instead of telling a remote user to go find it.
final homeTabProvider = StateProvider<HomeTab>((ref) => HomeTab.liveTv);
