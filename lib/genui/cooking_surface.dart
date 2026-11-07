import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import 'cooking_ui_controller.dart';

/// The actual GenUI renderer. The model owns component choice/order/content;
/// the catalog owns accessible Flutter widgets and permitted actions.
class CookingSurface extends StatelessWidget {
  const CookingSurface({super.key, required this.controller});
  final CookingUiController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (_, _) => Surface(
      key: ValueKey(controller.generation),
      surfaceContext: controller.engine.contextFor(
        CookingUiController.surfaceId,
      ),
    ),
  );
}
