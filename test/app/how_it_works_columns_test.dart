import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/how_it_works.dart';
import 'package:soussight/live/live_backend.dart';

List<String> names(List<RoutingEntry> entries) => [
  for (final e in entries) e.feature,
];

void main() {
  group('hybridRoutingColumns', () {
    test('with no cloud route, everything AI runs on this device', () {
      final c = hybridRoutingColumns(
        cloudRoutes: const CloudRoutes({}),
        liveBackend: LiveBackend.none,
      );
      expect(names(c.onDevice), [
        'Pantry scan',
        'Recipe draft',
        'Watch my food',
        'Coach Lite',
        'Label check',
      ]);
      expect(names(c.cloud), ['Nearby stores']);
      expect(c.off, [
        'Pantry voice note',
        'Watch: one photo you choose',
        'Live coach',
        'Grounded research',
        'Step illustrations',
      ]);
      for (final e in c.onDevice) {
        expect(e.note, 'Always here.');
      }
    });

    test(
      'with hybrid fallback, the cloud column follows the routing table',
      () {
        final c = hybridRoutingColumns(
          cloudRoutes: CloudRoutes.parse('hybridFallback,research,live'),
          liveBackend: LiveBackend.aiLogic,
        );
        // The watch itself never appears in the cloud column; only the
        // separate, consented one-photo check does.
        expect(names(c.cloud), isNot(contains('Watch my food')));
        expect(names(c.cloud), contains('Watch: one photo you choose'));
        expect(names(c.onDevice), contains('Watch my food'));
        expect(names(c.cloud), containsAll(['Pantry scan', 'Coach Lite']));
        expect(names(c.cloud), contains('Live coach'));
        expect(names(c.cloud), contains('Grounded research'));
        expect(c.off, ['Step illustrations']); // `images` not in this build
        final coach = c.cloud.firstWhere((e) => e.feature == 'Coach Lite');
        expect(coach.note, contains('fails its checks'));
      },
    );
  });

  testWidgets('two columns side by side at phone width', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: HybridRoutingColumns(
              cloudRoutes: CloudRoutes.parse('hybridFallback'),
              liveBackend: LiveBackend.none,
            ),
          ),
        ),
      ),
    );
    final device = find.byKey(const ValueKey('routing-column-device'));
    final cloud = find.byKey(const ValueKey('routing-column-cloud'));
    expect(device, findsOneWidget);
    expect(cloud, findsOneWidget);
    expect(tester.getTopLeft(device).dy, tester.getTopLeft(cloud).dy);
    expect(tester.getTopLeft(device).dx, lessThan(tester.getTopLeft(cloud).dx));
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('Google cloud'), findsOneWidget);
    expect(find.byKey(const ValueKey('routing-off')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a very narrow sheet stacks the columns', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: HybridRoutingColumns(
              cloudRoutes: const CloudRoutes({}),
              liveBackend: LiveBackend.ephemeral,
            ),
          ),
        ),
      ),
    );
    final device = find.byKey(const ValueKey('routing-column-device'));
    final cloud = find.byKey(const ValueKey('routing-column-cloud'));
    expect(tester.getTopLeft(device).dx, tester.getTopLeft(cloud).dx);
    expect(tester.getTopLeft(device).dy, lessThan(tester.getTopLeft(cloud).dy));
    // Ephemeral Live needs no route; it is listed in the cloud column.
    expect(find.text('Live coach'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the images route is listed on and off in both views (SS-098)', () {
    final on = hybridRoutingColumns(
      cloudRoutes: CloudRoutes.parse('images'),
      liveBackend: LiveBackend.none,
    );
    expect(names(on.cloud), contains('Step illustrations'));
    expect(on.off, isNot(contains('Step illustrations')));
    String row(String routes) => hybridRoutingRows(
      cloudRoutes: CloudRoutes.parse(routes),
      liveBackend: LiveBackend.none,
    ).firstWhere((r) => r.feature == 'Step illustrations').where;
    expect(row('images'), contains('Google cloud'));
    expect(row('images'), contains('after you allow'));
    expect(row(''), startsWith('Off in this build'));
  });
}
