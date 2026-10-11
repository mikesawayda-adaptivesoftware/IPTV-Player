import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_bridge.dart';
import '../../core/cast/cast_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/cast_provider.dart';

/// Asks which Chromecast to cast to. Null when the sheet is dismissed.
Future<CastDevice?> pickCastDevice(BuildContext context) {
  return showModalBottomSheet<CastDevice>(
    context: context,
    backgroundColor: AppTheme.surfaceColor,
    builder: (_) => const _CastDevicePicker(),
  );
}

class _CastDevicePicker extends ConsumerStatefulWidget {
  const _CastDevicePicker();

  @override
  ConsumerState<_CastDevicePicker> createState() => _CastDevicePickerState();
}

class _CastDevicePickerState extends ConsumerState<_CastDevicePicker> {
  late final CastController _cast;
  StreamSubscription<List<CastDevice>>? _subscription;
  List<CastDevice> _devices = const [];
  String? _error;
  bool _searchedLong = false;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _cast = ref.read(castProvider.notifier);
    _subscription = _cast.devices.listen((d) {
      if (mounted) setState(() => _devices = d);
    });
    _cast.startDiscovery().catchError((Object e) {
      if (mounted) setState(() => _error = CastController.describe(e));
    });
    _searchTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _searchedLong = true);
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _subscription?.cancel();
    _cast.stopDiscovery().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Cast to',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(_error!, style: const TextStyle(color: AppTheme.errorColor)),
              ),
            if (_devices.isEmpty && _error == null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _searchedLong
                            ? 'Still looking. The phone has to be on the same '
                                'Wi-Fi as the Chromecast.'
                            : 'Looking for Chromecasts...',
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            for (final device in _devices)
              ListTile(
                leading: const Icon(Icons.cast, color: AppTheme.accentColor),
                title: Text(device.name,
                    style: const TextStyle(color: AppTheme.textPrimary)),
                subtitle: device.description == null
                    ? null
                    : Text(device.description!,
                        style: const TextStyle(color: AppTheme.textSecondary)),
                onTap: () => Navigator.of(context).pop(device),
              ),
          ],
        ),
      ),
    );
  }
}
