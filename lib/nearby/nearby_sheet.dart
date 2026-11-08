import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'geolocation.dart' as geo;
import 'nearby_client.dart';

typedef NearbyLocator = Future<NearbyCoordinates> Function();
typedef NearbyLinkOpener = Future<void> Function(Uri uri);

const _green = Color(0xFF235B46);
const _cream = Color(0xFFFFF8EC);
const _ink = Color(0xFF3B3328);
const _muted = Color(0xFF6B5A3E);

Future<void> _openExternally(Uri uri) async {
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Opens the nearby help sheet. Location is requested only when the cook taps
/// "Use my location"; otherwise a typed city or ZIP is sent as text.
Future<void> showNearbySheet(
  BuildContext context, {
  required NearbyClient client,
  required NearbyKind kind,
  List<String> missingItems = const [],
  NearbyLocator? locate,
  NearbyLinkOpener? openLink,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: const Color(0xFFF7EFE1),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: NearbyPanel(
      client: client,
      kind: kind,
      missingItems: missingItems,
      locate: locate ?? geo.locateOnce,
      openLink: openLink ?? _openExternally,
    ),
  ),
);

class NearbyPanel extends StatefulWidget {
  const NearbyPanel({
    super.key,
    required this.client,
    required this.kind,
    required this.locate,
    required this.openLink,
    this.missingItems = const [],
  });

  final NearbyClient client;
  final NearbyKind kind;
  final List<String> missingItems;
  final NearbyLocator locate;
  final NearbyLinkOpener openLink;

  @override
  State<NearbyPanel> createState() => _NearbyPanelState();
}

class _NearbyPanelState extends State<NearbyPanel> {
  final _area = TextEditingController();
  final _areaFocus = FocusNode();
  bool _busy = false;
  String? _error;
  NearbyResult? _result;
  int _request = 0;

  @override
  void dispose() {
    _request++;
    _area.dispose();
    _areaFocus.dispose();
    super.dispose();
  }

  String get _title => switch (widget.kind) {
    NearbyKind.foodHelp => 'Find food help nearby',
    NearbyKind.groceries => 'Where to get the missing items',
  };

  Future<void> _useLocation() async {
    if (_busy) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    NearbyCoordinates coordinates;
    try {
      coordinates = await widget.locate();
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _busy = false;
        _error = 'Location is off or blocked. Type a city or ZIP code instead.';
      });
      _areaFocus.requestFocus();
      return;
    }
    if (!mounted || request != _request) return;
    await _search(
      NearbyQuery(
        kind: widget.kind,
        coordinates: coordinates,
        missingItems: widget.missingItems,
      ),
      request,
    );
  }

  Future<void> _useArea() async {
    if (_busy) return;
    final typed = _area.text.trim();
    // Never search an implied place: the hint is only an example.
    if (typed.isEmpty) {
      setState(() => _error = nearbyAreaRequired);
      _areaFocus.requestFocus();
      return;
    }
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _search(
      NearbyQuery(
        kind: widget.kind,
        area: typed,
        missingItems: widget.missingItems,
      ),
      request,
    );
  }

  Future<void> _search(NearbyQuery query, int request) async {
    try {
      final result = await widget.client.find(query);
      if (!mounted || request != _request) return;
      setState(() {
        _result = result;
        _busy = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _busy = false;
        _result = null;
        _error = error is NearbyException
            ? error.message
            : 'Nearby search is unavailable right now. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: const Color(0xFFD9C9AE),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                _title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              iconSize: 28,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        if (widget.missingItems.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Looking for: ${widget.missingItems.join(', ')}',
            style: const TextStyle(fontSize: 15, color: _muted, height: 1.4),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('nearby-use-location'),
          style: _button(_green),
          icon: const Icon(Icons.my_location),
          label: const Text('Use my location once'),
          onPressed: _busy ? null : () => unawaited(_useLocation()),
        ),
        const SizedBox(height: 8),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 16, color: _muted),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                nearbyLocationNotice,
                style: TextStyle(fontSize: 13, color: _muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('nearby-area'),
                controller: _area,
                focusNode: _areaFocus,
                maxLength: 80,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_useArea()),
                style: const TextStyle(fontSize: 17),
                decoration: const InputDecoration(
                  labelText: 'Or type a city or ZIP',
                  hintText: 'e.g. $kNearbyAreaHint',
                  counterText: '',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _area,
              builder: (context, value, _) => SizedBox(
                height: 56,
                child: OutlinedButton(
                  key: const ValueKey('nearby-search-area'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(64, 56),
                    foregroundColor: _green,
                    side: const BorderSide(color: _green, width: 1.5),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _busy || value.text.trim().isEmpty
                      ? null
                      : () => unawaited(_useArea()),
                  child: const Text('Search'),
                ),
              ),
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator(color: _green)),
        ],
        if (_error case final error?) ...[
          const SizedBox(height: 16),
          Container(
            key: const ValueKey('nearby-error'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFBE3DC),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    error,
                    style: const TextStyle(fontSize: 14, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_result case final result? when !_busy) ...[
          const SizedBox(height: 20),
          NearbyResults(result: result, openLink: widget.openLink),
        ],
      ],
    ),
  );

  static ButtonStyle _button(Color color) => FilledButton.styleFrom(
    backgroundColor: color,
    minimumSize: const Size.fromHeight(56),
    textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  );
}

/// The grounded answer, followed immediately by its Google Maps source places
/// and attribution, as required for Grounding with Google Maps results.
class NearbyResults extends StatelessWidget {
  const NearbyResults({
    super.key,
    required this.result,
    required this.openLink,
  });
  final NearbyResult result;
  final NearbyLinkOpener openLink;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFEADFCB)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.simulated) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _muted,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  'REHEARSAL · SIMULATED PLACES',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (result.answer.isNotEmpty) ...[
          Text(
            result.answer,
            style: const TextStyle(fontSize: 16, height: 1.45, color: _ink),
          ),
          const SizedBox(height: 14),
        ],
        for (final place in result.places)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              link: true,
              label: '${place.title}, open in Google Maps',
              excludeSemantics: true,
              // The merged node replaces the InkWell's own semantics, so it
              // must carry the same activation for screen readers.
              onTap: () => unawaited(openLink(place.uri)),
              child: Material(
                color: _cream,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  key: ValueKey('nearby-place-${place.uri}'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => unawaited(openLink(place.uri)),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.place_outlined, color: _green),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              place.title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: _green,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.open_in_new,
                            size: 18,
                            color: _green,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 4),
        const GoogleMapsAttribution(),
        const SizedBox(height: 12),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.schedule, size: 16, color: _muted),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                nearbyDisclaimer,
                style: TextStyle(fontSize: 13, color: _muted, height: 1.4),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// "Sources: Google Maps". Per the Grounding with Google Maps display rules,
/// "Google Maps" is not wrapped, translated, or restyled: weight 400, normal
/// style, gray #5E5E5E, 12–16 sp.
class GoogleMapsAttribution extends StatelessWidget {
  const GoogleMapsAttribution({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Sources: Google Maps',
    excludeSemantics: true,
    child: const Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Sources: ',
          style: TextStyle(fontSize: 13, color: Color(0xFF5E5E5E)),
        ),
        Text(
          'Google Maps',
          softWrap: false,
          maxLines: 1,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            fontStyle: FontStyle.normal,
            color: Color(0xFF5E5E5E),
          ),
        ),
      ],
    ),
  );
}
