import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Renders only Google's provider-returned searchEntryPoint.renderedContent.
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
    return SizedBox(
      height: 160,
      width: double.infinity,
      child: HtmlElementView.fromTagName(
        key: ValueKey(content),
        tagName: 'iframe',
        onElementCreated: (element) {
          final frame = element as web.HTMLIFrameElement;
          frame.title = 'Google Search suggestions';
          frame.setAttribute(
            'sandbox',
            'allow-popups allow-popups-to-escape-sandbox',
          );
          frame.setAttribute('scrolling', 'auto');
          frame.referrerPolicy = 'no-referrer';
          frame.style
            ..border = '0'
            ..width = '100%'
            ..height = '160px';
          // No allow-scripts or allow-same-origin. Keep provider HTML and its
          // official attribution unchanged; long content remains scrollable.
          frame.setAttribute('srcdoc', content);
        },
      ),
    );
  }
}
