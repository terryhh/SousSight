import 'package:flutter/material.dart';

/// The current app targets Flutter web. Native hosts must provide a sandboxed
/// WebView before presenting Google-grounded results with search suggestions.
class SearchSuggestions extends StatelessWidget {
  const SearchSuggestions({super.key, required this.html});
  final String? html;

  @override
  Widget build(BuildContext context) => html == null || html!.trim().isEmpty
      ? const SizedBox.shrink()
      : const Text(
          'Open SousSight on the web to view Google Search suggestions.',
        );
}
