// SS-105: the privacy receipt card, its local image save, and its session
// binding.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/ledger_source.dart';
import 'package:soussight/trust/privacy_receipt.dart';
import 'package:soussight/trust/privacy_receipt_card.dart';
import 'package:soussight/trust/privacy_receipt_save.dart';

import 'trust_test_helpers.dart';

/// A ledger that can be reset, like `InferenceLedger.startSession`.
class _Ledger extends ChangeNotifier implements LedgerSource {
  _Ledger(this._legs);
  List<InferenceLeg> _legs;

  @override
  List<InferenceLeg> get legs => List.unmodifiable(_legs);

  void add(InferenceLeg leg) {
    _legs = [..._legs, leg];
    notifyListeners();
  }

  void reset([List<InferenceLeg> legs = const []]) {
    _legs = legs;
    notifyListeners();
  }
}

InferenceLeg _leg(
  String id,
  Provenance provenance, {
  String feature = 'coach_lite',
  Set<DataKind> kinds = const {DataKind.text},
  bool? transferPermitted,
  HybridErrorCode? error,
}) => InferenceLeg(
  requestId: id,
  feature: feature,
  mode: HybridMode.preferOnDevice,
  kinds: kinds,
  transferPermitted: transferPermitted ?? provenance != Provenance.sdkOnDevice,
  provenance: provenance,
  error: error,
);

class _Saver {
  final calls = <(Uint8List, String)>[];
  ReceiptSaveResult result = ReceiptSaveResult.downloaded;
  Object? error;
  Completer<ReceiptSaveResult>? gate;

  Future<ReceiptSaveResult> call(Uint8List png, String name) async {
    calls.add((png, name));
    if (error case final e?) throw e;
    if (gate case final g?) return g.future;
    return result;
  }
}

Future<void> _pump(
  WidgetTester tester,
  LedgerSource ledger, {
  _Saver? saver,
  int? timersRun,
  bool reduceMotion = false,
  Size size = const Size(360, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: reduceMotion),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: PrivacyReceiptCard(
              ledger: ledger,
              recipeTitle: 'Peanut Butter Sandwich',
              clock: () => DateTime(2026, 11, 26, 19, 42),
              timersRun: timersRun,
              saveImage: (saver ?? _Saver()).call,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps "Save image" and lets the real PNG encode finish.
Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('privacy-receipt-save')));
  await _settleSave(tester);
}

Future<void> _settleSave(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

const _photo = {DataKind.image};

void main() {
  testWidgets('practice night: stamped PRACTICE, nothing claimed on-device', (
    tester,
  ) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg('a', Provenance.simulated),
        _leg('b', Provenance.simulated, feature: 'local_watch', kinds: _photo),
      ]),
    );
    expect(find.text("Tonight's privacy receipt"), findsOneWidget);
    expect(find.text('Peanut Butter Sandwich'), findsOneWidget);
    expect(find.text('Thu 26 Nov · 7:42 pm'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('receipt-stamp-practice')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('receipt-stamp-local')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-on-device')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-cloud')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-camera')), findsNothing);
    expect(find.text('Practice · no model ran'), findsOneWidget);
    expect(find.text('Practice camera checks'), findsOneWidget);
    expect(find.text('On this device'), findsNothing);
    expect(
      find.text('Practice mode: no model ran and nothing was sent.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a practice night without photos never shows an on-device '
      'camera count', (tester) async {
    await _pump(tester, ListLedgerSource([_leg('a', Provenance.simulated)]));
    expect(
      find.byKey(const ValueKey('receipt-practice-camera')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('receipt-camera')), findsNothing);
  });

  testWidgets('zero-cloud night: STAYED HERE and no photo sent', (
    tester,
  ) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg('a', Provenance.sdkOnDevice),
        _leg(
          'b',
          Provenance.sdkOnDevice,
          feature: 'local_watch',
          kinds: _photo,
        ),
        _leg(
          'c',
          Provenance.sdkOnDevice,
          feature: 'local_watch',
          kinds: _photo,
        ),
      ]),
      timersRun: 2,
    );
    expect(find.byKey(const ValueKey('receipt-stamp-local')), findsOneWidget);
    Text count(String key) => tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Text),
          )
          .last,
    );
    expect(count('receipt-on-device').data, '3');
    expect(count('receipt-cloud').data, '0');
    expect(count('receipt-camera').data, '2');
    expect(count('receipt-timers').data, '2');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('receipt-photos-sent')))
          .data,
      '0',
    );
    expect(
      find.text('No photo left this device for an answer tonight.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('receipt-sent-list')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-maybe-list')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed night lists what left, what may have, and why', (
    tester,
  ) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg('a', Provenance.sdkOnDevice),
        _leg('b', Provenance.sdkCloud, feature: 'label_check', kinds: _photo),
        _leg(
          'c',
          Provenance.unknown,
          feature: 'pantry_scan',
          kinds: _photo,
          transferPermitted: true,
          error: HybridErrorCode.network,
        ),
        _leg('d', Provenance.simulated),
      ]),
    );
    expect(find.byKey(const ValueKey('receipt-stamp-local')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-stamp-practice')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-practice')), findsOneWidget);
    expect(find.byKey(const ValueKey('receipt-unfinished')), findsOneWidget);
    expect(find.text('WHAT LEFT THIS DEVICE'), findsOneWidget);
    expect(find.text('Label check · photo'), findsOneWidget);
    expect(
      find.text('Tried this device first; Gemini in the cloud answered'),
      findsOneWidget,
    );
    expect(find.text('MAY HAVE LEFT'), findsOneWidget);
    expect(find.text('Pantry scan · photo'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('receipt-photos-sent')))
          .data,
      '1',
    );
    expect(find.textContaining('1 more may have been sent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sent photos without doubt point at the list', (tester) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg(
          'a',
          Provenance.cloudAdapter,
          feature: 'pantry_scan',
          kinds: _photo,
        ),
      ]),
    );
    expect(
      find.text('Each one is listed below, with why it went.'),
      findsOneWidget,
    );
  });

  testWidgets('a Live night says the coach saw the camera', (tester) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg(
          'live-1',
          Provenance.cloudAdapter,
          feature: 'live',
          kinds: {DataKind.audio, DataKind.image, DataKind.text},
        ),
        _leg('a', Provenance.sdkOnDevice),
      ]),
    );
    expect(find.byKey(const ValueKey('receipt-live')), findsOneWidget);
    expect(find.byKey(const ValueKey('receipt-stamp-local')), findsNothing);
    expect(
      find.textContaining('The Live coach saw your camera'),
      findsOneWidget,
    );
  });

  testWidgets('an empty night still prints, honestly', (tester) async {
    await _pump(tester, ListLedgerSource());
    expect(find.text('AI answers'), findsOneWidget);
    expect(find.byKey(const ValueKey('receipt-stamp-local')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-stamp-practice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates as legs finish, and hides when the session changes', (
    tester,
  ) async {
    final ledger = _Ledger([_leg('first', Provenance.sdkOnDevice)]);
    await _pump(tester, ledger);
    ledger.add(_leg('second', Provenance.sdkCloud, kinds: _photo));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('receipt-photos-sent')))
          .data,
      '1',
    );
    // A new cooking session resets the ledger: not tonight's receipt now.
    ledger.reset([_leg('other-session', Provenance.sdkOnDevice)]);
    await tester.pump();
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
    // It stays retired even if the ledger later looks familiar.
    ledger.reset([_leg('first', Provenance.sdkOnDevice)]);
    await tester.pump();
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
  });

  testWidgets('a receipt that started empty anchors on its first leg', (
    tester,
  ) async {
    final ledger = _Ledger([]);
    await _pump(tester, ledger);
    ledger.add(_leg('first', Provenance.sdkOnDevice));
    await tester.pump();
    expect(find.byKey(const ValueKey('privacy-receipt')), findsOneWidget);
    ledger.reset();
    await tester.pump();
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
  });

  testWidgets('prints in over about a second, instantly under reduced motion', (
    tester,
  ) async {
    final ledger = ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]);
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget app(bool reduce) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(
          body: SingleChildScrollView(
            child: PrivacyReceiptCard(ledger: ledger),
          ),
        ),
      ),
    );
    double factor() => tester
        .widget<Align>(find.byKey(const ValueKey('privacy-receipt-print')))
        .heightFactor!;
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(milliseconds: 200));
    expect(factor(), lessThan(1));
    await tester.pumpAndSettle();
    expect(factor(), 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(true));
    await tester.pump();
    expect(factor(), 1);
  });

  group('Save image', () {
    testWidgets('renders a PNG locally and hands it to the saver', (
      tester,
    ) async {
      final saver = _Saver();
      await _pump(
        tester,
        ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]),
        saver: saver,
      );
      await _tapSave(tester);
      expect(saver.calls, hasLength(1));
      final (png, name) = saver.calls.single;
      expect(name, kReceiptFileName);
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(
        find.text('Receipt saved to your downloads. Nothing was uploaded.'),
        findsOneWidget,
      );
    });

    testWidgets('shared and cancelled say nothing more', (tester) async {
      for (final result in [
        ReceiptSaveResult.shared,
        ReceiptSaveResult.cancelled,
      ]) {
        final saver = _Saver()..result = result;
        await _pump(
          tester,
          ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]),
          saver: saver,
        );
        await _tapSave(tester);
        expect(saver.calls, hasLength(1));
        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('unsupported platforms suggest a screenshot', (tester) async {
      final saver = _Saver()..result = ReceiptSaveResult.unsupported;
      await _pump(
        tester,
        ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]),
        saver: saver,
      );
      await _tapSave(tester);
      expect(find.textContaining('A screenshot works.'), findsOneWidget);
    });

    testWidgets('a failing save says nothing was uploaded', (tester) async {
      final saver = _Saver()..error = StateError('boom');
      await _pump(
        tester,
        ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]),
        saver: saver,
      );
      await _tapSave(tester);
      expect(
        find.text("Couldn't make the image. Nothing was uploaded."),
        findsOneWidget,
      );
      // The button is usable again.
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Save image'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a second tap while saving is ignored', (tester) async {
      final saver = _Saver()..gate = Completer();
      await _pump(
        tester,
        ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]),
        saver: saver,
      );
      await _tapSave(tester);
      expect(saver.calls, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('privacy-receipt-save')),
        warnIfMissed: false,
      );
      await _settleSave(tester);
      expect(saver.calls, hasLength(1));
      saver.gate!.complete(ReceiptSaveResult.downloaded);
      await _settleSave(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('closing the receipt mid-save shows nothing afterwards', (
      tester,
    ) async {
      final saver = _Saver()..gate = Completer();
      await _pump(
        tester,
        ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]),
        saver: saver,
      );
      await _tapSave(tester);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      saver.gate!.complete(ReceiptSaveResult.downloaded);
      await _settleSave(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a session change before the image is ready saves nothing', (
      tester,
    ) async {
      final saver = _Saver();
      final ledger = _Ledger([_leg('first', Provenance.sdkOnDevice)]);
      await _pump(tester, ledger, saver: saver);
      await tester.tap(find.byKey(const ValueKey('privacy-receipt-save')));
      // The ledger moves to another session before the PNG is encoded.
      ledger.reset([_leg('next', Provenance.sdkOnDevice)]);
      await _settleSave(tester);
      expect(saver.calls, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a retired receipt cannot be saved', (tester) async {
      final saver = _Saver();
      final ledger = _Ledger([_leg('first', Provenance.sdkOnDevice)]);
      await _pump(tester, ledger, saver: saver);
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Save image'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      ledger.reset();
      // Without a rebuild, a stale handler still refuses.
      button.onPressed!();
      await _settleSave(tester);
      expect(saver.calls, isEmpty);
    });
  });

  test('the stub saver reports unsupported without writing anything', () async {
    expect(
      await saveReceiptImage(Uint8List(0), kReceiptFileName),
      ReceiptSaveResult.unsupported,
    );
  });

  test('the edge clipper zigzags inside the box', () {
    const clipper = ReceiptEdgeClipper();
    final path = clipper.getClip(const Size(100, 200));
    final bounds = path.getBounds();
    expect(bounds.top, 0);
    expect(bounds.bottom, 200);
    expect(bounds.left, 0);
    expect(bounds.right, 100);
    expect(path.contains(const Offset(50, 100)), isTrue);
    expect(path.contains(const Offset(0, 1)), isFalse);
    expect(clipper.shouldReclip(const ReceiptEdgeClipper()), isFalse);
    expect(clipper.shouldReclip(const ReceiptEdgeClipper(tooth: 8)), isTrue);
  });

  test('summary is built only from legs', () {
    // Keeps the import of PrivacyReceipt meaningful for this file's readers.
    expect(
      PrivacyReceipt.fromLegs([leg(Provenance.sdkOnDevice)]).summary,
      '1 answer tonight, 1 on this device; photos sent: 0.',
    );
  });
}
