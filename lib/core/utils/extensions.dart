import 'package:flutter/material.dart';

import '../platform/tv_platform.dart';

extension StringExtensions on String {
  /// Capitalize the first letter of the string
  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }

  /// Check if string is a valid URL
  bool get isValidUrl {
    final urlPattern = RegExp(
      r'^(https?:\/\/)?([\da-z\.-]+)\.([a-z\.]{2,6})([\/\w \.-]*)*\/?$',
      caseSensitive: false,
    );
    return urlPattern.hasMatch(this);
  }

  /// Check if string is a valid M3U file path or URL
  bool get isM3UPath {
    final lower = toLowerCase();
    return lower.endsWith('.m3u') || lower.endsWith('.m3u8');
  }

  /// Extract file name from path
  String get fileName {
    final parts = split('/');
    return parts.isNotEmpty ? parts.last : this;
  }
}

extension DateTimeExtensions on DateTime {
  /// Format as time (HH:mm)
  String get timeString {
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  /// Format as date (dd/MM/yyyy)
  String get dateString {
    return '${day.toString().padLeft(2, '0')}/${month.toString().padLeft(2, '0')}/$year';
  }

  /// Format as date and time
  String get dateTimeString => '$dateString $timeString';

  /// Check if this date is today
  bool get isToday {
    final now = DateTime.now();
    return year == now.year && month == now.month && day == now.day;
  }

  /// Check if this date is tomorrow
  bool get isTomorrow {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    return year == tomorrow.year && month == tomorrow.month && day == tomorrow.day;
  }
}

extension DurationExtensions on Duration {
  /// Format duration as HH:MM:SS or MM:SS
  String get formatted {
    final hours = inHours;
    final minutes = inMinutes.remainder(60);
    final seconds = inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

extension ContextExtensions on BuildContext {
  /// Get theme data
  ThemeData get theme => Theme.of(this);

  /// Get text theme
  TextTheme get textTheme => Theme.of(this).textTheme;

  /// Get color scheme
  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  /// Get screen size
  Size get screenSize => MediaQuery.of(this).size;

  /// Check if device is in landscape mode
  bool get isLandscape => MediaQuery.of(this).orientation == Orientation.landscape;

  /// Whether this is a TV, driven by a remote rather than touch or a mouse.
  ///
  /// Resolved once at startup; see [kIsTv].
  bool get isTv => kIsTv;

  /// Check if device is desktop (width > 900)
  ///
  /// Excludes TVs explicitly. At 1080p with density 2.0 a TV reports roughly
  /// 960x540 logical pixels, so it clears the 900 threshold by 60dp and would
  /// otherwise silently inherit the whole desktop layout - navigation rail,
  /// 220px category sidebar, six-column VOD grid - none of which is usable
  /// from a sofa. This single exclusion is what routes TV to its own branches.
  bool get isDesktop => !kIsTv && screenSize.width > 900;

  /// Check if device is tablet (width > 600)
  bool get isTablet => !kIsTv && screenSize.width > 600 && screenSize.width <= 900;

  /// Check if device is mobile (width <= 600)
  bool get isMobile => !kIsTv && screenSize.width <= 600;

  /// Show a snackbar
  void showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

