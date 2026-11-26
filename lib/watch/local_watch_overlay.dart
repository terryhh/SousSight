// What the cook sees over the camera preview during a local watch (SS-086).
//
// A privacy chip ("On this device · nothing uploaded"), a viewfinder frame
// and one short status line. The chip's upload wording comes only from the
// session ledger's legs, never from settings or from the watch's intent.
// "Ready" means the picture matches the step's visible cue: the cook still
// decides, and the camera cannot check temperature or food safety.

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../trust/trust_labels.dart';
import '../trust/trust_motion.dart';
import 'capture_owner.dart';
import 'local_watch_controller.dart';
import 'watch_service.dart';
import 'watch_verdict.dart';

/// Where a running local watch is, for the overlay.
enum WatchOverlayPhase {
  starting,
  watching,
  checking,
  awaitingConsent,
  notYet,
  unsure,
  ready,
}

/// The phase for [watch], or null when no local watch is running.
WatchOverlayPhase? watchOverlayPhase(LocalWatchController watch) {
  if (!watch.isActive) return null;
  if (watch.awaitingConsent) return WatchOverlayPhase.awaitingConsent;
  final verdict = watch.verdict;
  if (verdict != null && verdict.watchId == watch.watchId) {
    return switch (verdict.state) {
      WatchState.ready => WatchOverlayPhase.ready,
      WatchState.notYet => WatchOverlayPhase.notYet,
      WatchState.unsure => WatchOverlayPhase.unsure,
    };
  }
  if (watch.isChecking) return WatchOverlayPhase.checking;
  if (watch.capture.mode != CaptureMode.localCamera) {
    return WatchOverlayPhase.starting;
  }
  return WatchOverlayPhase.watching;
}

/// Watch photos that left, or may have left, this device, counted from the
/// ledger's legs for the watch and its consented cloud check.
({int sent, int maybe}) watchUploads(Iterable<InferenceLeg> legs) {
  var sent = 0, maybe = 0;
  for (final leg in legs) {
    if (leg.feature != kLocalWatchFeature &&
        leg.feature != kWatchCloudCheckFeature) {
      continue;
    }
    final outcome = legOutcome(leg);
    if (reportedAsSent(outcome)) sent++;
    if (outcome == LegOutcome.maybeSent) maybe++;
  }
  return (sent: sent, maybe: maybe);
}

/// The chip's wording. With no ledger to read, it says where the watch runs
/// and makes no claim about uploads.
String watchPrivacyLabel(({int sent, int maybe})? uploads) {
  if (uploads == null) return 'On this device';
  if (uploads.sent > 0) {
    return 'On this device · ${uploads.sent} '
        '${uploads.sent == 1 ? 'photo' : 'photos'} sent for a cloud check';
  }
  if (uploads.maybe > 0) {
    return 'On this device · ${uploads.maybe} '
        '${uploads.maybe == 1 ? 'photo' : 'photos'} may have been sent';
  }
  return 'On this device · nothing uploaded';
}

/// Title and optional hint for each phase. Never says done, safe or cooked.
({String title, String? hint, IconData icon}) watchPhaseText(
  WatchOverlayPhase phase, {
  WatchDirection direction = WatchDirection.none,
}) => switch (phase) {
  WatchOverlayPhase.starting => (
    title: 'Starting the camera…',
    hint: null,
    icon: Icons.videocam_outlined,
  ),
  WatchOverlayPhase.watching => (
    title: 'Watching for the cue',
    hint: null,
    icon: Icons.visibility_outlined,
  ),
  WatchOverlayPhase.checking => (
    title: 'Checking this frame on this device…',
    hint: null,
    icon: Icons.visibility_outlined,
  ),
  WatchOverlayPhase.awaitingConsent => (
    title: 'Waiting for your OK',
    hint: 'Nothing is sent unless you allow this one photo.',
    icon: Icons.pan_tool_outlined,
  ),
  WatchOverlayPhase.notYet => (
    title: direction == WatchDirection.less
        ? 'It may be past the cue — have a look'
        : 'Not yet — keep going',
    hint: null,
    icon: Icons.hourglass_bottom,
  ),
  WatchOverlayPhase.unsure => (
    title: 'Move the pan or bowl into view',
    hint: 'Clear steam or hands, or add some light.',
    icon: Icons.center_focus_weak,
  ),
  WatchOverlayPhase.ready => (
    title: 'Looks like the cue — you decide',
    hint: "Have a look yourself. The camera can't check temperature.",
    icon: Icons.check_circle_outline,
  ),
};

/// The overlay, sized to fill the camera preview it sits on.
class LocalWatchOverlay extends StatelessWidget {
  const LocalWatchOverlay({
    super.key,
    required this.phase,
    this.direction = WatchDirection.none,
    this.uploads,
  });

  /// Reads a running watch and, when given, the session ledger's legs.
  /// Returns null when no local watch is running.
  static LocalWatchOverlay? of(
    LocalWatchController watch, {
    List<InferenceLeg>? ledgerLegs,
    Key? key,
  }) {
    final phase = watchOverlayPhase(watch);
    if (phase == null) return null;
    final verdict = watch.verdict;
    return LocalWatchOverlay(
      key: key,
      phase: phase,
      direction: verdict != null && verdict.watchId == watch.watchId
          ? verdict.direction
          : WatchDirection.none,
      uploads: ledgerLegs == null ? null : watchUploads(ledgerLegs),
    );
  }

  final WatchOverlayPhase phase;
  final WatchDirection direction;

  /// From the session ledger; null when no ledger was available.
  final ({int sent, int maybe})? uploads;

  @override
  Widget build(BuildContext context) {
    final text = watchPhaseText(phase, direction: direction);
    final ready = phase == WatchOverlayPhase.ready;
    final unsure = phase == WatchOverlayPhase.unsure;
    final frameColor = ready
        ? const Color(0xffa9dcb9)
        : unsure
        ? const Color(0xfff2b84b)
        : Colors.white.withValues(alpha: 0.75);
    final duration = motionDuration(context, const Duration(milliseconds: 240));
    return Stack(
      key: const ValueKey('local-watch-overlay'),
      fit: StackFit.expand,
      children: [
        // Viewfinder corners: decorative, so hidden from screen readers.
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 52, 22, 104),
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: frameColor),
              duration: duration,
              builder: (context, color, _) =>
                  CustomPaint(painter: _ViewfinderPainter(color ?? frameColor)),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _PrivacyChip(uploads: uploads),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: duration,
                child: _StatusBanner(
                  key: ValueKey('watch-overlay-${phase.name}'),
                  phase: phase,
                  title: text.title,
                  hint: text.hint,
                  icon: text.icon,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PrivacyChip extends StatelessWidget {
  const _PrivacyChip({required this.uploads});

  final ({int sent, int maybe})? uploads;

  @override
  Widget build(BuildContext context) {
    final u = uploads;
    final outcome = u == null || (u.sent == 0 && u.maybe == 0)
        ? LegOutcome.onDevice
        : u.sent > 0
        ? LegOutcome.cloudSdk
        : LegOutcome.maybeSent;
    final colors = outcomeColors(outcome);
    final label = watchPrivacyLabel(u);
    return DecoratedBox(
      key: const ValueKey('watch-privacy-chip'),
      decoration: ShapeDecoration(
        color: colors.background.withValues(alpha: 0.94),
        shape: StadiumBorder(side: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(5, 4, 10, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.border,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  outcomeIcon(outcome),
                  size: 12,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: colors.foreground,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    super.key,
    required this.phase,
    required this.title,
    required this.hint,
    required this.icon,
  });

  final WatchOverlayPhase phase;
  final String title;
  final String? hint;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (phase) {
      WatchOverlayPhase.ready => (
        const Color(0xffe4ebdf),
        const Color(0xff1c4231),
      ),
      WatchOverlayPhase.unsure => (
        const Color(0xfffff0d6),
        const Color(0xff5c3300),
      ),
      _ => (Colors.black.withValues(alpha: 0.62), Colors.white),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 22, color: foreground),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    if (hint case final hint?)
                      Text(
                        hint,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
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

/// Four rounded corner brackets, like a camera viewfinder.
class _ViewfinderPainter extends CustomPainter {
  const _ViewfinderPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final arm = (size.shortestSide * 0.14).clamp(14.0, 34.0);
    const r = 10.0;
    final w = size.width, h = size.height;
    void corner(Offset a, Offset c, Offset b) {
      // a → (rounded) c → b
      final path = Path()..moveTo(a.dx, a.dy);
      final toC = (c - a);
      final fromC = (b - c);
      final p1 = c - toC / toC.distance * r;
      final p2 = c + fromC / fromC.distance * r;
      path
        ..lineTo(p1.dx, p1.dy)
        ..quadraticBezierTo(c.dx, c.dy, p2.dx, p2.dy)
        ..lineTo(b.dx, b.dy);
      canvas.drawPath(path, paint);
    }

    corner(Offset(0, arm), Offset.zero, Offset(arm, 0));
    corner(Offset(w - arm, 0), Offset(w, 0), Offset(w, arm));
    corner(Offset(w, h - arm), Offset(w, h), Offset(w - arm, h));
    corner(Offset(arm, h), Offset(0, h), Offset(0, h - arm));
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => old.color != color;
}

/// The verdict state behind [service]'s status line, when that line is the
/// verdict's own message (not a Live, starting or consent line).
WatchState? watchNoticeState(WatchService service) {
  final verdict = service.local.verdict;
  if (verdict == null || service.activeRoute == WatchRoute.live) return null;
  return service.statusText == verdict.message ? verdict.state : null;
}

/// The watch status line under the preview, styled for the two verdicts a
/// cook acts on: a calm "you decide" card for ready, and a gentle reframe
/// prompt for unsure. Returns null for every other line, so the caller keeps
/// its plain notice.
Widget? watchStatusNotice(WatchService service) {
  final state = watchNoticeState(service);
  final status = service.statusText;
  if (state == null || status == null) return null;
  if (state == WatchState.notYet) return null;
  final ready = state == WatchState.ready;
  final text = watchPhaseText(
    ready ? WatchOverlayPhase.ready : WatchOverlayPhase.unsure,
  );
  final (background, accent, foreground) = ready
      ? (
          const Color(0xffe4ebdf),
          const Color(0xff285b43),
          const Color(0xff1c4231),
        )
      : (
          const Color(0xfffff0d6),
          const Color(0xffb7791f),
          const Color(0xff5c3300),
        );
  return Padding(
    key: ValueKey('watch-notice-${state.name}'),
    padding: const EdgeInsets.only(top: 12),
    child: ArrivalTransition(
      signature: status,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(text.icon, size: 20, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text.title,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status,
                      style: TextStyle(color: foreground, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
