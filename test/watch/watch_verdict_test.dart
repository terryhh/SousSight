import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/watch/frame_digest.dart';
import 'package:soussight/watch/watch_verdict.dart';

import 'watch_fakes.dart';

void main() {
  test('frame digest is SHA-256 (FIPS 180-2 vectors)', () {
    Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
    expect(
      frameDigest(bytes('')),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      frameDigest(bytes('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      frameDigest(
        bytes('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      ),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
    expect(
      frameDigest(Uint8List.fromList(List.filled(1000000, 0x61))),
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    );
  });

  test('parses each state and keeps direction only for not_yet', () {
    expect(
      parseWatchJson(verdictJson('ready', direction: 'more')).direction,
      WatchDirection.none,
    );
    final notYet = parseWatchJson(verdictJson('not_yet', direction: 'less'));
    expect(notYet.state, WatchState.notYet);
    expect(notYet.direction, WatchDirection.less);
    expect(parseWatchJson(verdictJson('unsure')).state, WatchState.unsure);
  });

  test('anything malformed becomes unsure', () {
    for (final text in ['', 'ready', '[]', '{"state":"done"}', '{"state":1}']) {
      expect(parseWatchJson(text).state, WatchState.unsure, reason: text);
    }
  });

  test('missing or wrongly typed required fields abstain as unsure', () {
    for (final text in [
      '{"state":"ready"}',
      '{"state":"ready","direction":"none"}',
      '{"state":"ready","whatISee":"Golden edges."}',
      '{"state":"ready","direction":"none","whatISee":42}',
      '{"state":"ready","direction":"none","whatISee":null}',
      '{"state":"ready","direction":"none","whatISee":"   "}',
      '{"state":"not_yet","direction":"sideways","whatISee":"Pale onions."}',
      '{"state":"not_yet","direction":1,"whatISee":"Pale onions."}',
      '{"state":["ready"],"direction":"none","whatISee":"Golden edges."}',
    ]) {
      final parsed = parseWatchJson(text);
      expect(parsed.state, WatchState.unsure, reason: text);
      expect(parsed.whatISee, isEmpty, reason: text);
    }
    // A complete answer still parses.
    expect(
      parseWatchJson(verdictJson('ready', see: 'Golden edges.')).state,
      WatchState.ready,
    );
  });

  test('claims vision cannot support are replaced, not shown', () {
    for (final claim in [
      'Chicken is cooked through.',
      'Safe to eat now.',
      'Internal temperature looks like 75°C.',
      'The rice may be undercooked.',
    ]) {
      final parsed = parseWatchJson(verdictJson('ready', see: claim));
      expect(parsed.redacted, isTrue, reason: claim);
      expect(parsed.whatISee, isNot(contains(claim)));
    }
    expect(
      parseWatchJson(verdictJson('ready', see: 'Golden edges.')).redacted,
      isFalse,
    );
  });

  group('internal-doneness, temperature and safety claims (SS-113)', () {
    const claims = [
      // Codex's probe, verbatim.
      'The chicken is cooked all the way through.',
      'The chicken is cooked all the way.',
      'Cooked-through and juicy.',
      'Thoroughly cooked chicken.',
      'The pork is fully done.',
      'It looks done.',
      'It’s done now.',
      'The burger is done inside.',
      'Done in the middle.',
      'No longer pink inside.',
      'The chicken is no longer pink.',
      'Still pink in the centre.',
      'Raw in the center.',
      'Opaque throughout.',
      'Right through to the bone.',
      'The thigh has reached 74 degrees.',
      'Reached 165F.',
      'About 165 °F.',
      'Internal temp looks right.',
      'Cooked internally.',
      'The interior is done.',
      'Safe to eat.',
      'Safely cooked.',
      'Ready to eat.',
      'Fine to serve.',
      'No salmonella risk.',
      'The juices run clear.',
      'Medium-rare steak.',
      'The rice is underdone.',
      // Codex, #271 review, verbatim.
      'meets all food safeguards',
      'The rice is overdone.',
      'Ya está hecho.',
      'Los fideos están hechos.',
      'El filete está muy hecho.',
      'Perfect doneness.',
      // Codex, second round (#269 follow-up), verbatim.
      'cooked to the bone',
      'well-done',
      'gluten-free',
      'El pollo está completamente cocido',
      // Orchestrator: the only observation on a ready verdict.
      'The chicken is done and ready to eat',
      // More doneness wording and Spanish basics.
      'Overcooked edges.',
      'The steak is well done.',
      'Nut-free crust.',
      'May contain peanuts.',
      'Dairy free sauce.',
      'La carne está bien hecha.',
      'Es seguro para comer.',
      'Ya está segura.',
      'Pan sin gluten.',
      'Crudo por dentro.',
      'Está rosado por dentro.',
      'La temperatura es de 75 grados.',
      'Listo para comer.',
      'Contiene alérgenos.',
    ];
    const visibleOnly = [
      'Golden on top.',
      'The edges look crisp.',
      'Onions look soft and translucent.',
      'Small bubbles across the surface of the sauce.',
      'Steam rising from the pot.',
      'Browned on the outside with a dark crust.',
      'The cheese has melted and is bubbling.',
      'Pink shrimp curled into a C shape.',
      'The pancake is set at the edges.',
      'The pasta water is at a rolling boil.',
      'Dark sear marks on one side.',
      'Free of lumps and smooth.',
      'The onions are cooking in the pan.',
      'Las cebollas están doradas.',
      'Burbujas pequeñas en la salsa.',
      'Bordes crujientes.',
      // Codex, #271 review: "hecho" as an auxiliary is a visible cue.
      'Se han hecho burbujas en la superficie',
    ];

    for (final claim in claims) {
      test('redacts: $claim', () {
        for (final state in ['ready', 'not_yet']) {
          final parsed = parseWatchJson(verdictJson(state, see: claim));
          expect(parsed.redacted, isTrue, reason: '$state: $claim');
          // A redacted positive abstains; not_yet keeps its state.
          expect(
            parsed.state,
            state == 'ready' ? WatchState.unsure : WatchState.notYet,
            reason: '$state: $claim',
          );
          expect(parsed.whatISee, isNot(contains(claim)));
          final message = WatchVerdict(
            state: parsed.state,
            direction: parsed.direction,
            whatISee: parsed.whatISee,
            redacted: parsed.redacted,
            watchId: 'w',
            stepId: 'a',
            sessionId: 's',
            frameCapturedAt: DateTime(2026),
            source: WatchVerdictSource.onDevice,
          ).message.toLowerCase();
          expect(message, isNot(contains(claim.toLowerCase())));
          expect(message, isNot(contains('cooked all the way')));
          expect(message, isNot(contains('cooked through')));
        }
      });
    }

    for (final seen in visibleOnly) {
      test('keeps visible-cue wording: $seen', () {
        final parsed = parseWatchJson(verdictJson('ready', see: seen));
        expect(parsed.state, WatchState.ready);
        expect(parsed.redacted, isFalse, reason: seen);
        expect(parsed.whatISee, seen);
      });
    }

    test('Codex probe: a redacted ready abstains as unsure', () {
      final parsed = parseWatchJson(
        '{"state":"ready","direction":"none",'
        '"whatISee":"The chicken is cooked all the way through."}',
      );
      expect(parsed.state, WatchState.unsure);
      expect(parsed.redacted, isTrue);
      expect(
        parsed.whatISee,
        'I can describe how it looks, not how it is inside.',
      );
    });

    test('a redacted unsure stays unsure', () {
      final parsed = parseWatchJson(verdictJson('unsure', see: 'Safe to eat.'));
      expect(parsed.state, WatchState.unsure);
      expect(parsed.redacted, isTrue);
    });

    test('claimsUnsupported normalises curly apostrophes', () {
      expect(claimsUnsupported('It’s done.'), isTrue);
      expect(claimsUnsupported('It’s golden.'), isFalse);
    });
  });

  test('prompt carries the step cue and stays bounded', () {
    final long = RecipeStep(
      id: 'x',
      title: 'T' * 2000,
      instruction: 'I' * 2000,
      cue: 'C' * 2000,
    );
    expect(buildWatchPrompt(stepA), contains(stepA.cue));
    expect(buildWatchPrompt(long).length, lessThan(1000));
    // A step without a cue falls back to its instruction.
    const noCue = RecipeStep(
      id: 'n',
      title: 'Rest',
      instruction: 'Let it rest.',
      cue: '',
    );
    expect(watchCue(noCue), 'Let it rest.');
    const empty = RecipeStep(id: 'e', title: 'Rest', instruction: ' ', cue: '');
    expect(watchCue(empty), isNull);
  });

  test('no verdict message certifies doneness or safety', () {
    for (final state in WatchState.values) {
      for (final direction in WatchDirection.values) {
        final message = WatchVerdict(
          state: state,
          direction: direction,
          whatISee: 'Onions in a pan.',
          watchId: 'w',
          stepId: 'a',
          sessionId: 's',
          frameCapturedAt: DateTime(2026),
          source: WatchVerdictSource.onDevice,
        ).message.toLowerCase();
        expect(message, isNot(contains('is done')));
        expect(message, isNot(contains('safe to eat')));
        expect(message, isNot(contains('cooked through')));
        expect(message, contains('i can see: onions in a pan.'));
      }
    }
  });

  test('past the cue says to take the pan off the heat first', () {
    WatchVerdict verdict(WatchVerdictSource source) => WatchVerdict(
      state: WatchState.notYet,
      direction: WatchDirection.less,
      whatISee: 'Dark edges.',
      watchId: 'w',
      stepId: 'a',
      sessionId: 's',
      frameCapturedAt: DateTime(2026),
      source: source,
    );
    expect(
      verdict(WatchVerdictSource.onDevice).message,
      "It may be past the cue. If it's on the heat, slide the pan off the "
      'heat, then look. I can see: Dark edges.',
    );
    expect(
      verdict(WatchVerdictSource.cloud).message,
      startsWith(
        'It may be past the cue (cloud check of one photo). '
        "If it's on the heat, slide the pan off the heat, then look.",
      ),
    );
  });
}
