import 'package:flutter/material.dart';

/// Isolated attribution surface for provider-returned Google Search suggestions
/// (`searchSuggestionsHtml` / `searchEntryPoint.renderedContent`).
///
/// The current app targets Flutter web. Native hosts or widget tests display an
/// explicit attribution notice while preserving the exact provider HTML payload.
/// Never pass model prose, A2UI properties, or arbitrary user HTML here.
class SearchSuggestions extends StatelessWidget {
  const SearchSuggestions({super.key, required this.html});

  final String? html;

  @override
  Widget build(BuildContext context) {
    final content = html;
    if (content == null || content.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'Google Search suggestions attribution',
      child: Container(
        key: ValueKey<String>(content),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: const Text(
          'Open SousSight on the web to view Google Search suggestions.',
        ),
      ),
    );
  }
}
