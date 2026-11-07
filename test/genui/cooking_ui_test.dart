import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:soussight/genui/cooking_ui.dart';

Map<String, dynamic> panel(Map<String, dynamic> child) => {
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': [child['id']],
    },
    child,
  ],
};

void main() {
  testWidgets(
    'captured Gemini Live workspace renders and waits for the cook answer',
    (tester) async {
      // Captured from an actual Gemini Live show_cooking_ui tool response on
      // 2026-11-07. This is offline replay of that payload, not a live service test.
      final events = <CookingUiAction>[];
      final controller = CookingUiController(onAction: events.add);
      controller.applyJson(
        File('test/genui/fixtures/gemini_live_workspace.json')
            .readAsStringSync(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CookingSurface(controller: controller),
            ),
          ),
        ),
      );
      expect(find.byType(Surface), findsOneWidget);
      expect(find.text('Chickpea Texture Check'), findsOneWidget);
      expect(find.text('Leave some chickpeas whole.'), findsOneWidget);
      expect(find.text('Texture Preference'), findsOneWidget);
      expect(events, isEmpty);
      await tester.ensureVisible(find.text('Chunky'));
      await tester.tap(find.text('Chunky'));
      expect(events.single.name, 'cook_answer');
      expect(events.single.context['answer'], 'Chunky');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  test('rejects cyclic, dangling, duplicate and unknown component trees', () {
    final invalid = [
      {
        'components': [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['root'],
          },
        ],
      },
      {
        'components': [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['missing'],
          },
        ],
      },
      {
        'components': [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['cue'],
          },
          {
            'id': 'cue',
            'component': 'stepCue',
            'title': 'One',
            'body': 'Do this',
          },
          {
            'id': 'cue',
            'component': 'stepCue',
            'title': 'Two',
            'body': 'Do that',
          },
        ],
      },
      panel({
        'id': 'script',
        'component': 'HTML',
        'body': '<script>send()</script>',
      }),
      panel({
        'id': 'cue',
        'component': 'stepCue',
        'title': 'Go',
        'body': 'Do it',
        'action': 'send_sms',
      }),
      panel({
        'id': 'ingredients',
        'component': 'ingredientChecklist',
        'title': 'Have these?',
        'items': [
          {'id': 'yogurt', 'label': 'Yogurt', 'checked': true},
        ],
      }),
    ];
    for (final payload in invalid) {
      expect(() => validateCookingUi(payload), throwsFormatException);
    }
  });

  test('invalid replacement leaves the current workspace intact', () {
    final controller = CookingUiController();
    addTearDown(controller.dispose);
    controller.applyToolPayload(demoCookingUi);
    final original = controller.components;
    expect(
      () => controller.applyJson('{"components":[]}'),
      throwsFormatException,
    );
    expect(controller.components, original);
    expect(controller.catalog.items.length, 8);
  });

  test('timer repeats and layout morphs preserve original deadline', () {
    var now = DateTime.utc(2026, 11, 7, 20);
    final events = <CookingUiAction>[];
    final controller = CookingUiController(
      clock: () => now,
      onAction: events.add,
    );
    addTearDown(controller.dispose);
    final timer = controller.startTimer(
      id: 'pickle',
      label: 'Quick pickle',
      seconds: 300,
    );
    now = now.add(const Duration(seconds: 30));
    final repeated = controller.startTimer(
      id: 'pickle',
      label: 'Changed label',
      seconds: 600,
    );
    controller.applyToolPayload(demoCookingUi);
    expect(identical(timer, repeated), isTrue);
    expect(timer.remaining(now), const Duration(seconds: 270));
    expect(
      controller.engine
          .contextFor(CookingUiController.surfaceId)
          .definition
          .value!
          .components
          .values
          .where((item) => item.type == 'cookingTimer'),
      hasLength(1),
    );
    now = now.add(const Duration(minutes: 10));
    controller.refreshTimers();
    controller.refreshTimers();
    expect(
      events.where((event) => event.name == 'timer_elapsed'),
      hasLength(1),
    );
    expect(timer.remaining(now), Duration.zero);
  });

  test('restoring an elapsed deadline never rearms the timer', () {
    final now = DateTime.utc(2026, 11, 7, 20);
    final events = <CookingUiAction>[];
    final controller = CookingUiController(
      clock: () => now,
      onAction: events.add,
    );
    addTearDown(controller.dispose);
    final deadline = now.subtract(const Duration(minutes: 2));
    final timer = controller.restoreTimer(
      id: 'pickle',
      label: 'Quick pickle',
      deadline: deadline,
    );
    expect(timer.deadline, deadline);
    expect(timer.remaining(now), Duration.zero);
    expect(events.single.name, 'timer_elapsed');
    controller.dismissTimer('pickle');
    expect(
      () => controller.startTimer(
        id: 'pickle',
        label: 'Quick pickle',
        seconds: 30,
      ),
      throwsFormatException,
    );
  });

  test('restoring confirmed ingredients emits no user action', () {
    final events = <CookingUiAction>[];
    final controller = CookingUiController(onAction: events.add);
    addTearDown(controller.dispose);
    controller.restoreConfirmedIngredients(['chickpeas']);
    controller.applyToolPayload(demoCookingUi);
    controller.applyToolPayload(
      panel({
        'id': 'next',
        'component': 'stepCue',
        'title': 'Mix',
        'body': 'Add yogurt.',
      }),
    );
    expect(controller.confirmedIngredients, {'chickpeas'});
    expect(events, isEmpty);
    expect(
      controller.engine
          .contextFor(CookingUiController.surfaceId)
          .definition
          .value!
          .components
          .keys,
      unorderedEquals(['root', 'next']),
    );
  });

  testWidgets(
    'GenUI composes widgets and sends ingredient and button actions',
    (tester) async {
      final events = <CookingUiAction>[];
      final controller = CookingUiController(onAction: events.add);
      controller.applyToolPayload(demoCookingUi);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CookingSurface(controller: controller),
            ),
          ),
        ),
      );
      expect(find.byType(Surface), findsOneWidget);
      expect(find.text('What is on your counter?'), findsOneWidget);
      await tester.tap(find.text('1 can chickpeas, drained'));
      await tester.pump();
      expect(controller.confirmedIngredients, {'chickpeas'});
      expect(events.last.name, 'ingredient_confirmed');
      await tester.ensureVisible(find.text('Am I doing this right?'));
      await tester.tap(find.text('Am I doing this right?'));
      expect(events.last.name, 'check_now');

      controller.applyToolPayload(
        panel({
          'id': 'dinner',
          'component': 'dinnerReady',
          'title': 'Dinner is ready',
          'message': 'Come join me for chickpea wraps!',
        }),
      );
      await tester.pump();
      expect(find.text('What is on your counter?'), findsNothing);
      expect(
        events.where((event) => event.name == 'review_dinner_message'),
        isEmpty,
      );
      await tester.tap(find.text('Review dinner message'));
      expect(events.last.name, 'review_dinner_message');
      expect(
        events.last.context['message'],
        'Come join me for chickpea wraps!',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('timer remains visible through replacement and counts down', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 7, 20);
    final controller = CookingUiController(clock: () => now);
    controller.startTimer(id: 'pickle', label: 'Quick pickle', seconds: 5);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CookingSurface(controller: controller)),
      ),
    );
    expect(find.text('0:05'), findsOneWidget);
    now = now.add(const Duration(seconds: 2));
    controller.refreshTimers();
    controller.applyToolPayload(
      panel({
        'id': 'cue',
        'component': 'stepCue',
        'title': 'Mash',
        'body': 'Use a fork.',
      }),
    );
    await tester.pump();
    expect(find.text('0:03'), findsOneWidget);
    expect(find.text('Mash'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('0:03'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test(
    'cook questions require 2-4 distinct choices and no model selection',
    () {
      Map<String, dynamic> question(List<Map<String, dynamic>> options) =>
          panel({
            'id': 'clarify',
            'component': 'cookQuestion',
            'title': 'One quick question',
            'question': 'Are the chickpeas already cooked?',
            'options': options,
          });
      final choices = [
        {'id': 'yes', 'label': 'Yes, canned and drained'},
        {'id': 'unsure', 'label': 'I am not sure'},
      ];
      expect(validateCookingUi(question(choices)), hasLength(2));
      expect(
        () => validateCookingUi(question([choices.first])),
        throwsFormatException,
      );
      expect(
        () => validateCookingUi(question([choices.first, choices.first])),
        throwsFormatException,
      );
      expect(
        () => validateCookingUi(
          question([
            {...choices.first, 'selected': true},
            choices.last,
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => validateCookingUi(
          panel({
            'id': 'cue',
            'component': 'stepCue',
            'title': 'Ask',
            'body': 'Ask someone.',
            'action': 'request_help',
          }),
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets('cook question waits for explicit answer before dispatch', (
    tester,
  ) async {
    final events = <CookingUiAction>[];
    final controller = CookingUiController(onAction: events.add);
    controller.applyToolPayload(
      panel({
        'id': 'clarify',
        'component': 'cookQuestion',
        'title': 'One quick question',
        'question': 'Are the chickpeas already cooked?',
        'options': [
          {'id': 'yes', 'label': 'Yes, canned and drained'},
          {'id': 'unsure', 'label': 'I am not sure'},
        ],
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CookingSurface(controller: controller)),
      ),
    );
    expect(find.text('Are the chickpeas already cooked?'), findsOneWidget);
    expect(events, isEmpty);
    expect(controller.confirmedIngredients, isEmpty);
    await tester.tap(find.text('I am not sure'));
    expect(events.single.name, 'cook_answer');
    expect(events.single.context, {
      'question': 'Are the chickpeas already cooked?',
      'answer': 'I am not sure',
      'optionId': 'unsure',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
