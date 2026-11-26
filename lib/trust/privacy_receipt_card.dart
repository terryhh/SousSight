// Tonight's privacy receipt card (SS-105), shown in the meal-complete panel.
//
// A paper receipt built only from this session's ledger legs
// ([PrivacyReceipt.fromLegs]). "Save image" renders it to PNG on this device
// and hands it to the share sheet or a download; nothing is uploaded.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'ledger_source.dart';
import 'privacy_receipt.dart';
import 'privacy_receipt_save.dart';
import 'trust_labels.dart';
import 'trust_motion.dart';

const _paper = Color(0xfffffdf8);
const _backdrop = Color(0xfffff3dc);
const _ink = Color(0xff1f3d2f);
const _muted = Color(0xff6f6a60);
const _rule = Color(0xffd9cdb6);
const _local = Color(0xff285b43);
const _cloud = Color(0xff3c6a92);
const _practice = Color(0xffb86f0e);
const _maybe = Color(0xffbf5b32);

const kReceiptFileName = 'soussight-privacy-receipt.png';

/// Which meal a receipt belongs to, and when it was printed.
///
/// Owned by whoever owns the cooking session (the cooking screen's state),
/// not by the card, so it survives the card being rebuilt or remounted, for
/// example when a layout breakpoint moves the panel from a column to a row.
/// It binds to the ledger's generation (`InferenceLedger.generation`), which
/// advances on every session reset, including one that reuses a session ID
/// and a quick A to B to A. Once it moves, the binding retires for good and
/// any save in flight is dropped.
class PrivacyReceiptBinding {
  /// [expected] is the generation the meal started on; when omitted, the
  /// generation read now.
  PrivacyReceiptBinding({
    required int Function() generation,
    int? expected,
    DateTime Function() clock = DateTime.now,
  }) : _read = generation,
       generation = expected ?? generation(),
       printedAt = clock();

  final int Function() _read;

  /// The ledger generation this receipt was printed for.
  final int generation;
  final DateTime printedAt;
  bool _retired = false;

  /// Whether the ledger is still on [generation]. Latches false.
  bool get isCurrent {
    if (!_retired && _read() != generation) _retired = true;
    return !_retired;
  }
}

class PrivacyReceiptCard extends StatefulWidget {
  const PrivacyReceiptCard({
    super.key,
    required this.ledger,
    required this.binding,
    this.recipeTitle,
    this.timersRun,
    this.saveImage = saveReceiptImage,
  });

  /// This session's ledger. Every inference number comes from its legs; the
  /// timers line is cooking-screen activity ([timersRun]).
  final LedgerSource ledger;

  /// The meal this receipt belongs to; see [PrivacyReceiptBinding].
  final PrivacyReceiptBinding binding;
  final String? recipeTitle;

  /// Timers the cook started since opening this cooking screen
  /// (`CookingCoordinator.timersStarted`), when the caller counts them. Not a
  /// privacy claim; hidden when null.
  final int? timersRun;
  final ReceiptImageSaver saveImage;

  @override
  State<PrivacyReceiptCard> createState() => _PrivacyReceiptCardState();
}

class _PrivacyReceiptCardState extends State<PrivacyReceiptCard> {
  final _boundary = GlobalKey();
  bool _saving = false;

  bool _current() => widget.binding.isCurrent;

  Future<void> _save() async {
    // The save belongs to the meal it started for: that exact binding must
    // stay installed on this card, and current, through every step.
    final binding = widget.binding;
    // Leaving this screen (another route pushed on top, or this one popped)
    // ends the save too.
    bool stillThisMeal() =>
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        identical(widget.binding, binding) &&
        binding.isCurrent;
    if (_saving || !stillThisMeal()) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _saving = true);
    // Feedback only while the receipt is on screen and still tonight's.
    void say(String text) {
      if (!stillThisMeal()) return;
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    try {
      final boundary =
          _boundary.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final ByteData? bytes;
      try {
        bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      // The receipt must still be tonight's, and still on screen.
      if (bytes == null || !stillThisMeal()) return;
      final result = await widget.saveImage(
        bytes.buffer.asUint8List(),
        kReceiptFileName,
        isCurrent: stillThisMeal,
      );
      switch (result) {
        case ReceiptSaveResult.shared ||
            ReceiptSaveResult.cancelled ||
            ReceiptSaveResult.stale:
          break;
        case ReceiptSaveResult.downloaded:
          say('Receipt saved to your downloads. Nothing was uploaded.');
        case ReceiptSaveResult.unsupported:
          say(
            "Saving an image isn't available in this version yet. "
            'A screenshot works.',
          );
      }
    } catch (_) {
      say("Couldn't make the image. Nothing was uploaded.");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.ledger,
    builder: (context, _) {
      if (!_current()) return const SizedBox.shrink();
      final receipt = PrivacyReceipt.fromLegs(widget.ledger.legs);
      return Column(
        key: const ValueKey('privacy-receipt'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PrintIn(
            child: RepaintBoundary(
              key: _boundary,
              child: ColoredBox(
                color: _backdrop,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 10, 6, 14),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: _ReceiptPaper(
                        receipt: receipt,
                        recipeTitle: widget.recipeTitle,
                        printedAt: widget.binding.printedAt,
                        timersRun: widget.timersRun,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: TextButton.icon(
              key: const ValueKey('privacy-receipt-save'),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share),
              label: const Text('Save image'),
            ),
          ),
        ],
      );
    },
  );
}

/// Reveals the receipt top to bottom, like paper leaving a till printer.
/// Zero time under reduced motion; the tree is the same either way.
class _PrintIn extends StatelessWidget {
  const _PrintIn({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: motionDuration(context, const Duration(milliseconds: 1100)),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => ClipRect(
      child: Align(
        key: const ValueKey('privacy-receipt-print'),
        alignment: Alignment.topCenter,
        heightFactor: t,
        child: Opacity(
          opacity: 0.35 + 0.65 * t,
          alwaysIncludeSemantics: true,
          child: child,
        ),
      ),
    ),
    child: child,
  );
}

class _ReceiptPaper extends StatelessWidget {
  const _ReceiptPaper({
    required this.receipt,
    required this.recipeTitle,
    required this.printedAt,
    required this.timersRun,
  });

  final PrivacyReceipt receipt;
  final String? recipeTitle;
  final DateTime printedAt;
  final int? timersRun;

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    final stamp = _stamp(r);
    return PhysicalShape(
      clipper: const ReceiptEdgeClipper(),
      color: _paper,
      elevation: 3,
      shadowColor: const Color(0x66745a2e),
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          color: _ink,
          height: 1.3,
          fontFeatures: [ui.FontFeature.tabularFigures()],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                recipeTitle: recipeTitle,
                printedAt: printedAt,
                stamp: stamp,
              ),
              const _Perforation(),
              _Line(label: 'AI runs recorded', value: r.runs, strong: true),
              const SizedBox(height: 8),
              _SplitBar(receipt: r),
              const SizedBox(height: 6),
              if (!r.practiceOnly)
                _Line(
                  key: const ValueKey('receipt-on-device'),
                  icon: outcomeIcon(LegOutcome.onDevice),
                  color: _local,
                  label: 'Ran on this device',
                  value: r.onDeviceRuns,
                ),
              if (!r.practiceOnly)
                _Line(
                  key: const ValueKey('receipt-cloud'),
                  icon: Icons.cloud_outlined,
                  color: _cloud,
                  label: 'Ran in the cloud',
                  value: r.cloudRuns,
                ),
              if (r.practiceRuns > 0)
                _Line(
                  key: const ValueKey('receipt-practice'),
                  icon: outcomeIcon(LegOutcome.simulated),
                  color: _practice,
                  label: 'Practice · no model ran',
                  value: r.practiceRuns,
                ),
              if (r.unfinished > 0)
                _Line(
                  key: const ValueKey('receipt-unfinished'),
                  icon: Icons.more_horiz,
                  color: _muted,
                  label: "Didn't finish",
                  value: r.unfinished,
                ),
              if (r.endedInError > 0)
                _Line(
                  key: const ValueKey('receipt-ended-in-error'),
                  icon: Icons.do_not_disturb_on_outlined,
                  color: _muted,
                  label: 'Ran, then ended in an error',
                  value: r.endedInError,
                ),
              if (r.inProgress > 0)
                _Line(
                  key: const ValueKey('receipt-in-progress'),
                  icon: Icons.hourglass_empty,
                  color: _muted,
                  label: 'Still running',
                  value: r.inProgress,
                ),
              const _Perforation(),
              if (r.practiceCameraChecks > 0 || r.practiceOnly)
                _Line(
                  key: const ValueKey('receipt-practice-camera'),
                  icon: Icons.photo_camera_outlined,
                  color: _practice,
                  label: 'Practice camera checks',
                  value: r.practiceCameraChecks,
                ),
              if (!r.practiceOnly)
                _Line(
                  key: const ValueKey('receipt-camera'),
                  icon: Icons.photo_camera_outlined,
                  color: _local,
                  label: 'Camera checks on device',
                  value: r.cameraChecksOnDevice,
                ),
              if (r.liveConnections > 0)
                _Line(
                  key: const ValueKey('receipt-live'),
                  icon: Icons.graphic_eq,
                  color: _cloud,
                  label: 'Live coach connections · cloud',
                  value: r.liveConnections,
                ),
              if (timersRun case final timers?)
                _Line(
                  key: const ValueKey('receipt-timers'),
                  icon: Icons.timer_outlined,
                  color: _ink,
                  label: 'Timers started this visit',
                  value: timers,
                ),
              const _Perforation(),
              _PhotosSent(receipt: r),
              if (r.sent.isNotEmpty) ...[
                const SizedBox(height: 14),
                _SendList(
                  key: const ValueKey('receipt-sent-list'),
                  title: 'What left this device',
                  sends: r.sent,
                  color: _cloud,
                ),
              ],
              if (r.maybeSent.isNotEmpty) ...[
                const SizedBox(height: 14),
                _SendList(
                  key: const ValueKey('receipt-maybe-list'),
                  title: 'May have left',
                  sends: r.maybeSent,
                  color: _maybe,
                ),
              ],
              const _Perforation(),
              _Barcode(seed: r.summary),
              const SizedBox(height: 10),
              const Text(
                'AI numbers come only from the requests SousSight recorded '
                "tonight on this device; it can't vouch for anything it "
                "didn't record. Timers come from this cooking screen. Made "
                'here; saving it uploads nothing.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: _muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A rubber stamp, only when the legs earn it. There is deliberately no
  /// "nothing left" stamp: some sends (such as Nearby lookups) are not yet
  /// recorded in the ledger, so the receipt never claims more than it saw.
  static Widget? _stamp(PrivacyReceipt r) {
    if (r.practiceOnly) {
      return const _Stamp(
        key: ValueKey('receipt-stamp-practice'),
        text: 'PRACTICE',
        color: _practice,
      );
    }
    return null;
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.recipeTitle,
    required this.printedAt,
    required this.stamp,
  });

  final String? recipeTitle;
  final DateTime printedAt;
  final Widget? stamp;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              'SOUSSIGHT',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 3,
                fontWeight: FontWeight.w800,
                color: _local,
              ),
            ),
          ),
          ?stamp,
        ],
      ),
      const SizedBox(height: 4),
      Semantics(
        header: true,
        child: const Text(
          "Tonight's privacy receipt",
          style: TextStyle(
            fontSize: 20,
            height: 1.15,
            letterSpacing: -.3,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(height: 6),
      if (recipeTitle case final title? when title.isNotEmpty)
        Text(
          title,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      Text(
        receiptDateLine(printedAt),
        style: const TextStyle(fontSize: 12.5, color: _muted),
      ),
    ],
  );
}

class _Stamp extends StatelessWidget {
  const _Stamp({super.key, required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: -0.14,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: .8), width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 1.6,
          fontWeight: FontWeight.w900,
          color: color.withValues(alpha: .85),
        ),
      ),
    ),
  );
}

/// One receipt line: label, dotted leader, count.
class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.color = _ink,
    this.strong = false,
  });

  final String label;
  final int value;
  final IconData? icon;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: strong ? 16 : 14,
      fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Stack(
                children: [
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 5,
                    child: _Leader(),
                  ),
                  // Paper behind the words hides the dots under them; the
                  // leftover space between label and count shows the leader.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: ColoredBox(
                          color: _paper,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Text(label, style: style),
                          ),
                        ),
                      ),
                      ColoredBox(
                        color: _paper,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '$value',
                            style: style.copyWith(
                              fontWeight: FontWeight.w800,
                              color: value == 0 ? _muted : color,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Leader extends StatelessWidget {
  const _Leader();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 2,
    child: CustomPaint(painter: _DotsPainter(), size: Size.infinite),
  );
}

class _DotsPainter extends CustomPainter {
  const _DotsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = _rule;
    for (var x = 1.0; x < size.width; x += 5) {
      canvas.drawCircle(Offset(x, size.height / 2), 1, paint);
    }
  }

  @override
  bool shouldRepaint(_DotsPainter oldDelegate) => false;
}

/// The share of finished runs by where they ran.
class _SplitBar extends StatelessWidget {
  const _SplitBar({required this.receipt});
  final PrivacyReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    final parts = [
      (r.onDeviceRuns, _local),
      (r.cloudRuns, _cloud),
      (r.practiceRuns, _practice),
    ].where((p) => p.$1 > 0).toList();
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: SizedBox(
          height: 8,
          child: parts.isEmpty
              ? const ColoredBox(color: Color(0xffefe8da))
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, (count, color)) in parts.indexed) ...[
                      if (i > 0) const SizedBox(width: 2),
                      Expanded(
                        flex: count,
                        child: ColoredBox(color: color),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// The hero line: how many photos left the device for an answer.
class _PhotosSent extends StatelessWidget {
  const _PhotosSent({required this.receipt});
  final PrivacyReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    final zero = r.photoRequestsSent == 0 && r.photoRequestsMaybeSent == 0;
    final String note;
    if (r.practiceOnly) {
      note =
          'Practice mode: every recorded request was pretend. No model ran '
          'for them and none was sent.';
    } else if (zero && r.liveConnections > 0) {
      note =
          'No recorded request sent a photo. The Live coach connected; while '
          'connected it can receive your camera.';
    } else if (zero) {
      note = 'No recorded request sent a photo tonight.';
    } else if (r.photoRequestsMaybeSent > 0) {
      final n = r.photoRequestsMaybeSent;
      // Each attempt is its own leg, so a retry of a request already counted
      // above is listed here as another attempt, never as another photo.
      note =
          '$n other ${n == 1 ? 'attempt' : 'attempts'} may also have sent a '
          'photo: allowed to leave, not confirmed either way. A retry of the '
          'same request counts as its own attempt.';
    } else {
      note = 'Each request is listed below, with where it went.';
    }
    return Semantics(
      container: true,
      child: Column(
        children: [
          const Text(
            'REQUESTS THAT SENT PHOTOS',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 2.4,
              fontWeight: FontWeight.w800,
              color: _muted,
            ),
          ),
          Text(
            '${r.photoRequestsSent}',
            key: const ValueKey('receipt-photos-sent'),
            style: TextStyle(
              fontSize: 56,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
              color: zero ? _local : _cloud,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            note,
            key: const ValueKey('receipt-photos-note'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: _muted),
          ),
        ],
      ),
    );
  }
}

class _SendList extends StatelessWidget {
  const _SendList({
    super.key,
    required this.title,
    required this.sends,
    required this.color,
  });

  final String title;
  final List<ReceiptSend> sends;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.8,
          fontWeight: FontWeight.w800,
          color: _muted,
        ),
      ),
      const SizedBox(height: 4),
      for (final send in sends)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    '×${send.count}',
                    style: TextStyle(fontWeight: FontWeight.w800, color: color),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        send.what,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        send.why,
                        style: const TextStyle(fontSize: 12.5, color: _muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

class _Perforation extends StatelessWidget {
  const _Perforation();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 14),
    child: SizedBox(
      height: 1,
      child: CustomPaint(painter: _DashPainter(), size: Size.infinite),
    ),
  );
}

class _DashPainter extends CustomPainter {
  const _DashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _rule
      ..strokeWidth = 1.2;
    for (var x = 0.0; x < size.width; x += 9) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(math.min(x + 5, size.width), 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => false;
}

/// A decorative till barcode. It encodes nothing.
class _Barcode extends StatelessWidget {
  const _Barcode({required this.seed});
  final String seed;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Center(
      child: SizedBox(
        width: 180,
        height: 24,
        child: CustomPaint(painter: _BarcodePainter(seed.hashCode)),
      ),
    ),
  );
}

class _BarcodePainter extends CustomPainter {
  const _BarcodePainter(this.seed);
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final paint = Paint()..color = _ink.withValues(alpha: .5);
    var x = 0.0;
    while (x < size.width) {
      final w = 1.0 + random.nextInt(3);
      if (random.nextBool()) {
        canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), paint);
      }
      x += w + 1;
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter oldDelegate) => oldDelegate.seed != seed;
}

/// Zigzag top and bottom edges, like torn till paper.
class ReceiptEdgeClipper extends CustomClipper<Path> {
  const ReceiptEdgeClipper({this.tooth = 10, this.depth = 5});
  final double tooth;
  final double depth;

  @override
  Path getClip(Size size) {
    final teeth = math.max(1, (size.width / tooth).round());
    final step = size.width / teeth;
    final path = Path()..moveTo(0, depth);
    for (var i = 0; i < teeth; i++) {
      path
        ..lineTo(step * i + step / 2, 0)
        ..lineTo(step * (i + 1), depth);
    }
    path.lineTo(size.width, size.height - depth);
    for (var i = teeth; i > 0; i--) {
      path
        ..lineTo(step * i - step / 2, size.height)
        ..lineTo(step * (i - 1), size.height - depth);
    }
    return path..close();
  }

  @override
  bool shouldReclip(ReceiptEdgeClipper oldClipper) =>
      oldClipper.tooth != tooth || oldClipper.depth != depth;
}
