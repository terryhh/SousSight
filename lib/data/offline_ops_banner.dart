import 'package:flutter/material.dart';

/// Shown in the cooking screen while the device is offline (SS-072).
const String offlineBannerText =
    "Offline — Coach Lite and timers keep working on this device; we'll save "
    "your progress when you're back.";

/// The cooking screen's offline notice. Place it above the workspace:
/// `if (cook.offline) OfflineBanner(pendingSteps: cook.pendingStepSaves),`
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.pendingSteps = 0});

  /// Step changes made on this device that are not saved yet.
  final int pendingSteps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: const ValueKey('offline-banner'),
      liveRegion: true,
      container: true,
      child: Card(
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cloud_off_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(offlineBannerText),
                    if (pendingSteps > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        pendingSteps == 1
                            ? '1 step change is waiting to save.'
                            : '$pendingSteps step changes are waiting to save.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
