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
// The stub directly, so this test means the same on every platform.
import 'package:soussight/trust/privacy_receipt_save_stub.dart' as stub;

import 'trust_test_helpers.dart';

/// A ledger with a session identity, like `InferenceLedger`: [startSession]
/// clears it and changes the session even when it was already empty.
class _Ledger extends ChangeNotifier implements LedgerSource {
  _Ledger([this._legs = const []]);
  List<InferenceLeg> _legs;
  int session = 1;

  @override
  List<InferenceLeg> get legs => List.unmodifiable(_legs);

  void add(InferenceLeg leg) {
    _legs = [..._legs, leg];
    notifyListeners();
  }

  void startSession([List<InferenceLeg> legs = const []]) {
    session++;
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
  final currentAtCall = <bool>[];
  bool Function()? isCurrent;
  ReceiptSaveResult result = ReceiptSaveResult.downloaded;
  Object? error;
  Completer<ReceiptSaveResult>? gate;

  Future<ReceiptSaveResult> call(
    Uint8List png,
    String name, {
    required bool Function() isCurrent,
  }) async {
    calls.add((png, name));
    this.isCurrent = isCurrent;
    currentAtCall.add(isCurrent());
    if (error case final e?) throw e;
    if (gate case final g?) return g.future;
    return result;
  }
}

Future<void> _pump(
  WidgetTester tester,
  LedgerSource ledger, {
  Object? Function()? session,
  _Saver? saver,
  int? timersRun,
  bool reduceMotion = false,
  Size size = const Size(360, 1600),
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
              session:
                  session ??
                  (ledger is _Ledger ? () => ledger.session : () => 's1'),
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
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

String _count(WidgetTester tester, String key) => tester
    .widget<Text>(
      find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Text),
          )
          .last,
    )
    .data!;

String _photos(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('receipt-photos-sent')))
    .data!;

const _photo = {DataKind.image};
final _receipt = find.byKey(const ValueKey('privacy-receipt'));

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
    expect(find.text('AI runs recorded'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('receipt-stamp-practice')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('receipt-on-device')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-cloud')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-camera')), findsNothing);
    expect(_count(tester, 'receipt-practice'), '2');
    expect(_count(tester, 'receipt-practice-camera'), '1');
    expect(find.textContaining('every recorded request was pretend'), findsOne);
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

  testWidgets('practice plus a real timeout is not stamped PRACTICE', (
    tester,
  ) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg('a', Provenance.simulated),
        _leg(
          'b',
          Provenance.unknown,
          transferPermitted: false,
          error: HybridErrorCode.timeout,
        ),
      ]),
    );
    expect(find.byKey(const ValueKey('receipt-stamp-practice')), findsNothing);
    expect(find.textContaining('No model ran'), findsNothing);
    expect(_count(tester, 'receipt-unfinished'), '1');
  });

  testWidgets('practice and real camera checks both show their counts', (
    tester,
  ) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg('a', Provenance.simulated, feature: 'local_watch', kinds: _photo),
        _leg(
          'b',
          Provenance.sdkOnDevice,
          feature: 'local_watch',
          kinds: _photo,
        ),
      ]),
    );
    expect(_count(tester, 'receipt-camera'), '1');
    expect(_count(tester, 'receipt-practice-camera'), '1');
  });

  testWidgets('zero-cloud night: no stamp, and claims scoped to the ledger', (
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
    // Some sends (Nearby) are not ledgered yet: no absolute stamp.
    expect(find.byKey(const ValueKey('receipt-stamp-local')), findsNothing);
    expect(find.text('STAYED HERE'), findsNothing);
    expect(_count(tester, 'receipt-on-device'), '3');
    expect(_count(tester, 'receipt-cloud'), '0');
    expect(_count(tester, 'receipt-camera'), '2');
    expect(_count(tester, 'receipt-timers'), '2');
    expect(find.text('RECORDED PHOTOS SENT'), findsOneWidget);
    expect(_photos(tester), '0');
    expect(
      find.text('No recorded request sent a photo tonight.'),
      findsOneWidget,
    );
    expect(
      find.textContaining("it can't vouch for anything it didn't record"),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('receipt-sent-list')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-maybe-list')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed night lists what left, what may have, and where', (
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
    expect(find.byKey(const ValueKey('receipt-stamp-practice')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-practice')), findsOneWidget);
    expect(_count(tester, 'receipt-unfinished'), '1');
    expect(find.text('WHAT LEFT THIS DEVICE'), findsOneWidget);
    expect(find.text('Label check · photo'), findsOneWidget);
    expect(
      find.text('Ran on Gemini in the cloud · asked to prefer this device'),
      findsOneWidget,
    );
    expect(find.text('MAY HAVE LEFT'), findsOneWidget);
    expect(find.text('Pantry scan · photo'), findsOneWidget);
    expect(_photos(tester), '1');
    expect(
      find.text(
        '1 more may have been sent: allowed to leave, not confirmed either '
        'way.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a request still running reads as running, not stopped', (
    tester,
  ) async {
    await _pump(
      tester,
      ListLedgerSource([
        _leg(
          'a',
          Provenance.unknown,
          feature: 'label_check',
          kinds: _photo,
          transferPermitted: true,
        ),
        _leg('b', Provenance.unknown, transferPermitted: false),
      ]),
    );
    expect(
      find.text('Still running: allowed to leave, not finished yet'),
      findsOneWidget,
    );
    expect(find.textContaining('stopped'), findsNothing);
    expect(_count(tester, 'receipt-in-progress'), '2');
    expect(find.byKey(const ValueKey('receipt-unfinished')), findsNothing);
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
      find.text('Each one is listed below, with where it went.'),
      findsOneWidget,
    );
  });

  testWidgets('a Live night reports connections and what they can receive', (
    tester,
  ) async {
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
    expect(_count(tester, 'receipt-live'), '1');
    expect(find.text('Live coach connections · cloud'), findsOneWidget);
    expect(find.text('Live coach · connection'), findsOneWidget);
    expect(find.textContaining('it can receive your camera'), findsWidgets);
    expect(find.textContaining('saw'), findsNothing);
  });

  testWidgets('an empty night still prints, honestly', (tester) async {
    await _pump(tester, ListLedgerSource());
    expect(find.text('AI runs recorded'), findsOneWidget);
    expect(find.byKey(const ValueKey('receipt-stamp-practice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates as legs finish, and retires when the session changes', (
    tester,
  ) async {
    final ledger = _Ledger([_leg('first', Provenance.sdkOnDevice)]);
    await _pump(tester, ledger);
    ledger.add(_leg('second', Provenance.sdkCloud, kinds: _photo));
    await tester.pump();
    expect(_photos(tester), '1');
    ledger.startSession([_leg('other', Provenance.sdkOnDevice)]);
    await tester.pump();
    expect(_receipt, findsNothing);
  });

  testWidgets('an empty receipt retires on an empty-to-empty reset', (
    tester,
  ) async {
    final ledger = _Ledger();
    await _pump(tester, ledger);
    expect(_receipt, findsOneWidget);
    // The next meal starts: still empty, but a different session.
    ledger.startSession();
    await tester.pump();
    expect(_receipt, findsNothing);
    // The next meal's photo never lands on this receipt.
    ledger.add(_leg('next', Provenance.sdkCloud, kinds: _photo));
    await tester.pump();
    expect(_receipt, findsNothing);
  });

  testWidgets('prints top edge first, instantly under reduced motion', (
    tester,
  ) async {
    final ledger = ListLedgerSource([_leg('a', Provenance.sdkOnDevice)]);
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget app(bool reduce) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(
          body: SingleChildScrollView(
            child: PrivacyReceiptCard(ledger: ledger, session: () => 's'),
          ),
        ),
      ),
    );
    final print = find.byKey(const ValueKey('privacy-receipt-print'));
    double factor() => tester.widget<Align>(print).heightFactor!;
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(milliseconds: 150));
    expect(factor(), lessThan(1));
    // Mid-print the header is inside the visible strip, the footer is not.
    final visible = tester.getRect(print);
    final header = tester.getRect(find.text('SOUSSIGHT'));
    final footer = tester.getRect(
      find.textContaining('Made here; saving it uploads nothing'),
    );
    expect(header.top, greaterThanOrEqualTo(visible.top));
    expect(header.bottom, lessThanOrEqualTo(visible.bottom));
    expect(footer.top, greaterThan(visible.bottom));
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
      expect(saver.currentAtCall.single, isTrue);
      expect(
        find.text('Receipt saved to your downloads. Nothing was uploaded.'),
        findsOneWidget,
      );
    });

    testWidgets('shared, cancelled and stale say nothing more', (tester) async {
      for (final result in [
        ReceiptSaveResult.shared,
        ReceiptSaveResult.cancelled,
        ReceiptSaveResult.stale,
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
      expect(saver.isCurrent!(), isFalse);
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
      ledger.startSession();
      await _settleSave(tester);
      expect(saver.calls, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a session change during the save: the saver is told, and '
        'no feedback is shown', (tester) async {
      for (final outcome in [
        ReceiptSaveResult.downloaded,
        ReceiptSaveResult.unsupported,
        null, // the saver throws
      ]) {
        final saver = _Saver()..gate = Completer();
        final ledger = _Ledger([_leg('first', Provenance.sdkOnDevice)]);
        await _pump(tester, ledger, saver: saver);
        await _tapSave(tester);
        expect(saver.currentAtCall.single, isTrue);
        ledger.startSession();
        await tester.pump();
        // The web saver checks this before falling back to a download.
        expect(saver.isCurrent!(), isFalse);
        if (outcome == null) {
          saver.gate!.completeError(StateError('share failed'));
        } else {
          saver.gate!.complete(outcome);
        }
        await _settleSave(tester);
        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a retired receipt cannot be saved by a stale handler', (
      tester,
    ) async {
      final saver = _Saver();
      final ledger = _Ledger([_leg('first', Provenance.sdkOnDevice)]);
      await _pump(tester, ledger, saver: saver);
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Save image'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      ledger.startSession();
      button.onPressed!();
      await _settleSave(tester);
      expect(saver.calls, isEmpty);
    });
  });

  test('the stub saver reports unsupported without writing anything', () async {
    expect(
      await stub.saveReceiptImage(
        Uint8List(0),
        kReceiptFileName,
        isCurrent: () => true,
      ),
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
    expect(
      PrivacyReceipt.fromLegs([leg(Provenance.sdkOnDevice)]).summary,
      '1 AI run tonight, 1 on this device; recorded photos sent: 0.',
    );
  });
}
