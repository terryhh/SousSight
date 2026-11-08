import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import 'cooking_ui_controller.dart';

const _green = Color(0xFF235B46);
const _cream = Color(0xFFF7F4EB);

Map<String, dynamic> _data(CatalogItemContext context) =>
    Map<String, dynamic>.from(context.data as Map);

Schema _schema(Map<String, Schema> properties, List<String> required) =>
    S.object(
      properties: properties,
      required: required,
      additionalProperties: false,
    );

Catalog buildCookingCatalog(CookingUiController controller) {
  return Catalog([
    CatalogItem(
      name: 'CookingColumn',
      dataSchema: _schema(
        {'children': S.list(items: S.string())},
        ['children'],
      ),
      widgetBuilder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 14,
        children: [
          for (final id in _data(context)['children'] as List)
            context.buildChild(id as String),
        ],
      ),
    ),
    CatalogItem(
      name: 'ingredientChecklist',
      dataSchema: _schema(
        {
          'title': S.string(),
          'items': S.list(
            items: _schema(
              {'id': S.string(), 'label': S.string()},
              ['id', 'label'],
            ),
          ),
        },
        ['title', 'items'],
      ),
      widgetBuilder: (context) {
        final data = _data(context);
        return _Panel(
          icon: Icons.kitchen_outlined,
          title: data['title'] as String,
          eyebrow: 'YOUR INGREDIENTS',
          child: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => Column(
              children: [
                for (final item in data['items'] as List)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text((item as Map)['label'] as String),
                    value: controller.confirmedIngredients.contains(item['id']),
                    onChanged: (value) => controller.confirmIngredient(
                      context.id,
                      item['id'] as String,
                      value ?? false,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
    CatalogItem(
      name: 'stepCue',
      dataSchema: _schema(
        {
          'title': S.string(),
          'body': S.string(),
          'action': S.string(),
          'actionLabel': S.string(),
        },
        ['title', 'body'],
      ),
      widgetBuilder: (context) {
        final data = _data(context);
        final action = data['action'] as String?;
        return _Panel(
          icon: Icons.restaurant_outlined,
          title: data['title'] as String,
          eyebrow: 'YOUR NEXT MOVE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 14,
            children: [
              Text(data['body'] as String, style: const TextStyle(height: 1.5)),
              if (action != null)
                FilledButton.icon(
                  icon: Icon(_actionIcon(action), size: 19),
                  label: Text(
                    data['actionLabel'] as String? ?? _actionLabel(action),
                  ),
                  onPressed: () => controller.dispatch(action, context.id),
                ),
            ],
          ),
        );
      },
    ),
    CatalogItem(
      name: 'cookQuestion',
      dataSchema: _schema(
        {
          'title': S.string(),
          'question': S.string(),
          'options': S.list(
            items: _schema(
              {'id': S.string(), 'label': S.string()},
              ['id', 'label'],
            ),
          ),
        },
        ['title', 'question', 'options'],
      ),
      widgetBuilder: (context) {
        final data = _data(context);
        return _Panel(
          icon: Icons.chat_bubble_outline,
          title: data['title'] as String,
          eyebrow: 'LET’S CHECK WITH YOU',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 14,
            children: [
              Text(
                data['question'] as String,
                style: const TextStyle(height: 1.5),
              ),
              AnimatedBuilder(
                animation: controller,
                builder: (_, _) {
                  final answered = controller.answerFor(
                    data['question'] as String,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 14,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in data['options'] as List)
                            OutlinedButton(
                              onPressed: answered != null
                                  ? null
                                  : () => controller.dispatch(
                                      'cook_answer',
                                      context.id,
                                      {
                                        'question': data['question'],
                                        'answer': option['label'],
                                        'optionId': option['id'],
                                      },
                                    ),
                              child: Text((option as Map)['label'] as String),
                            ),
                        ],
                      ),
                      Text(
                        answered != null
                            ? 'Answered: $answered'
                            : 'You can also answer by voice or text.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    ),
    CatalogItem(
      name: 'comparison',
      dataSchema: _schema(
        {
          'title': S.string(),
          'observed': S.string(),
          'target': S.string(),
          'cue': S.string(),
        },
        ['title', 'observed', 'target', 'cue'],
      ),
      widgetBuilder: (context) {
        final data = _data(context);
        return _Panel(
          icon: Icons.compare_outlined,
          title: data['title'] as String,
          eyebrow: 'AM I DOING THIS RIGHT?',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              _LabeledText('In your food', data['observed'] as String),
              _LabeledText('What to aim for', data['target'] as String),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _green.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(data['cue'] as String),
              ),
            ],
          ),
        );
      },
    ),
    CatalogItem(
      name: 'watchStatus',
      dataSchema: _schema(
        {
          'title': S.string(),
          'body': S.string(),
          'status': S.string(enumValues: ['watching', 'check_now', 'paused']),
        },
        ['title', 'body', 'status'],
      ),
      widgetBuilder: (context) {
        final data = _data(context);
        final status = data['status'] as String;
        return _Panel(
          icon: status == 'check_now'
              ? Icons.notifications_active_outlined
              : Icons.visibility_outlined,
          title: data['title'] as String,
          eyebrow: switch (status) {
            'watching' => 'WATCHING WITH YOU',
            'check_now' => 'TAKE A LOOK',
            _ => 'WATCH PAUSED',
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Text(data['body'] as String),
              if (status == 'check_now')
                TextButton.icon(
                  onPressed: () => controller.dispatch('check_now', context.id),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Check it together'),
                ),
            ],
          ),
        );
      },
    ),
    CatalogItem(
      name: 'cookingTimer',
      dataSchema: _schema(
        {'timerId': S.string(), 'label': S.string()},
        ['timerId', 'label'],
      ),
      widgetBuilder: (context) {
        final data = _data(context);
        return _TimerPanel(
          controller: controller,
          timerId: data['timerId'] as String,
          label: data['label'] as String,
        );
      },
    ),
    CatalogItem(
      name: 'dinnerReady',
      dataSchema: _schema(
        {'title': S.string(), 'message': S.string()},
        ['title', 'message'],
      ),
      widgetBuilder: (context) {
        final data = _data(context);
        return _Panel(
          icon: Icons.favorite_border,
          title: data['title'] as String,
          eyebrow: 'BRING EVERYONE TO THE TABLE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text(data['message'] as String),
              FilledButton.icon(
                onPressed: () => controller.dispatch(
                  'review_dinner_message',
                  context.id,
                  {'message': data['message']},
                ),
                icon: const Icon(Icons.chat_bubble_outline, size: 19),
                label: const Text('Review dinner message'),
              ),
            ],
          ),
        );
      },
    ),
  ], catalogId: CookingUiController.catalogId);
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.eyebrow,
    required this.child,
  });
  final IconData icon;
  final String title;
  final String eyebrow;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    color: _cream,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(color: _green.withValues(alpha: .12)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Icon(icon, color: _green, size: 23),
              Expanded(
                child: Text(
                  eyebrow,
                  style: const TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.6,
                    color: _green,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: const Color(0xFF243A2D),
              fontWeight: FontWeight.w600,
            ),
          ),
          child,
        ],
      ),
    ),
  );
}

class _LabeledText extends StatelessWidget {
  const _LabeledText(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [
      Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
      ),
      Text(value, style: const TextStyle(height: 1.4)),
    ],
  );
}

class _TimerPanel extends StatelessWidget {
  const _TimerPanel({
    required this.controller,
    required this.timerId,
    required this.label,
  });
  final CookingUiController controller;
  final String timerId;
  final String label;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final timer = controller.timerById(timerId);
      final seconds = timer == null
          ? null
          : (timer.remaining(controller.clock()).inMilliseconds / 1000).ceil();
      final elapsed = seconds == 0;
      final value = seconds == null
          ? 'Not started'
          : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
      return _Panel(
        icon: elapsed ? Icons.alarm_on : Icons.timer_outlined,
        title: timer?.label ?? label,
        eyebrow: elapsed ? 'TIME TO CHECK' : 'COOKING TIMER',
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: elapsed,
                label: elapsed
                    ? '$label timer finished. Check your food.'
                    : null,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: seconds == null ? 18 : 42,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: _green,
                  ),
                ),
              ),
            ),
            if (timer != null)
              TextButton(
                onPressed: () => controller.dismissTimer(timerId),
                child: Text(elapsed ? 'Dismiss' : 'Cancel'),
              ),
          ],
        ),
      );
    },
  );
}

String _actionLabel(String action) => switch (action) {
  'check_now' => 'Check my food',
  'next_step' => 'Next step',
  'ask_cook' => 'Let’s clarify',
  _ => 'Watch with me',
};

IconData _actionIcon(String action) => switch (action) {
  'check_now' => Icons.camera_alt_outlined,
  'next_step' => Icons.arrow_forward,
  'ask_cook' => Icons.chat_bubble_outline,
  _ => Icons.visibility_outlined,
};
