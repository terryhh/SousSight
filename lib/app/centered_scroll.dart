// Full-width scroll views with centred, width-limited content (SS-089).
//
// A scroll view inside a centred ConstrainedBox only scrolls when the pointer
// is over the content column; the wheel does nothing over the side margins
// on a desktop browser. These helpers keep the scroll view full width and
// centre the content inside it with padding, so phones look the same.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The side padding that centres content of at most [maxWidth] (including
/// [gutter] on each side) in [width]. Never less than [gutter].
double centeredSide(
  double width, {
  required double maxWidth,
  double gutter = 0,
}) => math.max(gutter, (width - maxWidth) / 2 + gutter);

/// A full-width [ListView] whose children sit in a centred column of at most
/// [maxWidth] (gutters included).
class CenteredListView extends StatelessWidget {
  const CenteredListView({
    super.key,
    required this.children,
    this.controller,
    this.maxWidth = 720,
    this.gutter = 20,
    this.top = 0,
    this.bottom = 32,
    this.shrinkWrap = false,
  });

  final List<Widget> children;
  final ScrollController? controller;
  final double maxWidth;
  final double gutter;
  final double top;
  final double bottom;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = centeredSide(
        constraints.maxWidth,
        maxWidth: maxWidth,
        gutter: gutter,
      );
      return ListView(
        controller: controller,
        shrinkWrap: shrinkWrap,
        padding: EdgeInsets.fromLTRB(side, top, side, bottom),
        children: children,
      );
    },
  );
}

/// Sheets span the window so the wheel works anywhere over them; their
/// content is centred by [CenteredListView].
const fullWidthSheet = BoxConstraints(maxWidth: double.infinity);
