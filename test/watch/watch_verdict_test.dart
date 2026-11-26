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
}
