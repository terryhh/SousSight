// Motion helpers for the trust surface (SS-086).
//
// Every transition here is short, decorative and skipped entirely when the
// platform asks for reduced motion (MediaQuery.disableAnimations).

import 'package:flutter/material.dart';

/// True when the cook's platform asked for reduced motion.
bool reduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// [duration], or zero under reduced motion.
Duration motionDuration(BuildContext context, Duration duration) =>
    reduceMotion(context) ? Duration.zero : duration;

/// Fades and lifts [child] in once when it is first built, and again when
/// [signature] changes (a new result arrived). Under reduced motion the child
/// is shown as is, with no animation widget in the tree.
class ArrivalTransition extends StatelessWidget {
  const ArrivalTransition({
    super.key,
    required this.signature,
    required this.child,
    this.duration = const Duration(milliseconds: 320),
    this.lift = 6,
  });

  /// What makes this result "new". A change replays the transition.
  final Object signature;
  final Widget child;
  final Duration duration;

  /// How far, in logical pixels, the child rises as it appears.
  final double lift;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return child;
    return TweenAnimationBuilder<double>(
      key: ValueKey(signature),
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        alwaysIncludeSemantics: true,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * lift),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
