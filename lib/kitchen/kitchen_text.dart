// "Big text" (SS-107): the cooking space, with the current step and the
// timers, read from across the counter.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'kitchen_mode.dart';

/// Enlarges text on top of the system text scale, never instead of it.
///
/// Each size is the system's own scaling of a [factor]-times larger font, so
/// a nonlinear system scaler (Android 14+) still shapes the result. The
/// result is capped at [maxScale] times the unscaled size, but never below
/// what the system alone would show.
class KitchenTextScaler extends TextScaler {
  const KitchenTextScaler(this.system, {this.factor = 1.5, this.maxScale = 3});

  final TextScaler system;
  final double factor;
  final double maxScale;

  @override
  double scale(double fontSize) {
    final systemOnly = system.scale(fontSize);
    final enlarged = system.scale(fontSize * factor);
    return math.min(enlarged, math.max(systemOnly, fontSize * maxScale));
  }

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is KitchenTextScaler &&
      other.system == system &&
      other.factor == factor &&
      other.maxScale == maxScale;

  @override
  int get hashCode => Object.hash(system, factor, maxScale);

  @override
  String toString() => 'kitchen big text (${factor}x on $system)';
}

/// Applies [KitchenTextScaler] to [child] while [mode]'s "Big text" is on.
/// The subtree is the same either way, so turning it on or off keeps the
/// state of everything below.
class KitchenBigText extends StatelessWidget {
  const KitchenBigText({super.key, required this.mode, required this.child});

  final KitchenMode mode;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: mode,
    child: child,
    builder: (context, child) {
      final system = MediaQuery.textScalerOf(context);
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: mode.bigText ? KitchenTextScaler(system) : system,
        ),
        child: child!,
      );
    },
  );
}

/// The "Big text" switch for the cooking space.
class KitchenBigTextToggle extends StatelessWidget {
  const KitchenBigTextToggle({super.key, required this.mode});

  final KitchenMode mode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: mode,
    builder: (context, _) => FilterChip(
      key: const ValueKey('kitchen-big-text'),
      avatar: const Icon(Icons.format_size, size: 18),
      label: const Text('Big text'),
      tooltip: mode.bigText
          ? 'Use normal text size'
          : 'Make the step and timers bigger',
      selected: mode.bigText,
      showCheckmark: false,
      onSelected: (value) => unawaited(mode.setBigText(value)),
    ),
  );
}
