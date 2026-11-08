import 'dart:convert';

/// The Live model selects, composes and updates these trusted native widgets.
/// This is A2UI component JSON, not executable HTML or Dart.
const cookingUiInstructions = '''
Use show_cooking_ui to compose the cooking workspace as the cook's needs change.
Set its stepId argument to the exact currentStepId in the latest host context.
Never label an old-step workspace with a new stepId; regenerate for the current step.
Its uiJson argument is a JSON string with one key, components, containing A2UI
v0.9 component objects. Send a complete replacement workspace, not a patch.
Every component has a unique id and a component type. Include a root
CookingColumn with children containing the other component IDs in display order.
Allowed components and properties:
- CookingColumn: children (list of component IDs).
- ingredientChecklist: title, items (list of {id, label}). These are candidates;
  only the cook can confirm an ingredient is present. Do not send checked states.
- stepCue: title, body, optional action (check_now, next_step, ask_cook,
  or start_watch), optional actionLabel.
- cookQuestion: title, question, options (2-4 objects with id and label). Use this
  to ask the cook for a missing fact instead of guessing. Keep the options neutral,
  and include an unsure option when appropriate. The cook can also answer by voice
  or text. Only the cook's selection counts as an answer.
- comparison: title, observed, target, cue. Describe visible differences only.
- watchStatus: title, body, status (watching, check_now, paused).
- cookingTimer: timerId, label. Display an existing timer started by start_timer;
  creating a panel does not start or restart a timer.
- donenessGauge: title, percent (integer 0-100), currentTexture, targetTexture, cue.
  Display visual progress toward a texture cue (e.g. mashing or mixing). Never certify
  food safety or internal temperature.
- dinnerReady: title, message. Creates a draft for the cook to review; never sends.
Use 1-12 visible components, concise text, stable IDs, and no URLs or HTML.
Timers keep running through workspace changes. Use a new timerId for a new timer.
Never claim camera vision proves food safety, allergen absence, or internal
temperature. A visual watch cue asks the cook to check, not a guarantee of doneness.
The cook is the human in the loop. Ask them clarifying questions when facts are
missing; research factual questions when useful. Do not route to an external
instructor or invent a human expert who will answer later.
Example uiJson (adapt the content to the current recipe and step):
{"components":[{"id":"root","component":"CookingColumn","children":["check"]},{"id":"check","component":"stepCue","title":"Check this step","body":"Compare your food with the current recipe cue.","action":"check_now","actionLabel":"Check my food"}]}
''';

/// A deterministic layout for the explicitly labelled offline demo.
const demoCookingUi = <String, dynamic>{
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['ingredients', 'mash', 'watch'],
    },
    {
      'id': 'ingredients',
      'component': 'ingredientChecklist',
      'title': 'What is on your counter?',
      'items': [
        {'id': 'chickpeas', 'label': '1 can chickpeas, drained'},
        {'id': 'yogurt', 'label': 'Plain yogurt'},
        {'id': 'lemon', 'label': 'Lemon or a reviewed swap'},
      ],
    },
    {
      'id': 'mash',
      'component': 'stepCue',
      'title': 'A little chunky is just right',
      'body': 'Press with a fork until most chickpeas are broken up.',
      'action': 'check_now',
      'actionLabel': 'Am I doing this right?',
    },
    {
      'id': 'watch',
      'component': 'watchStatus',
      'title': 'Keep your bowl in view',
      'body': 'Start the camera to get a visual check while you cook.',
      'status': 'paused',
    },
  ],
};

const cookingActions = {'check_now', 'next_step', 'ask_cook', 'start_watch'};

/// Reject malformed or excessive model output before the GenUI runtime mutates.
/// This also prevents cyclic layouts and model-written confirmation states.
List<Map<String, dynamic>> validateCookingUi(Map<String, dynamic> payload) {
  if (payload.keys.any((key) => key != 'components')) {
    throw const FormatException('Expected only components.');
  }
  final raw = payload['components'];
  if (raw is! List || raw.isEmpty || raw.length > 16) {
    throw const FormatException('Supply between 1 and 16 components.');
  }
  // Deep-copy before handing model-owned maps to the mutable UI runtime.
  final components = <Map<String, dynamic>>[];
  final byId = <String, Map<String, dynamic>>{};
  for (final item in raw) {
    if (item is! Map<String, dynamic>) {
      throw const FormatException('Each component must be an object.');
    }
    final component = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(item)) as Map<String, dynamic>,
    );
    final id = requireUiId(component['id'], 'id');
    if (byId.containsKey(id)) {
      throw FormatException('Duplicate component ID: $id');
    }
    _validateComponent(component);
    components.add(component);
    byId[id] = component;
  }
  if (byId['root']?['component'] != 'CookingColumn') {
    throw const FormatException('root must be a CookingColumn.');
  }
  final reached = <String>{};
  final active = <String>{};
  void visit(String id, int depth) {
    if (depth > 4 || active.contains(id)) {
      throw const FormatException('Cyclic or too deeply nested UI.');
    }
    final component = byId[id];
    if (component == null) throw FormatException('Missing component: $id');
    // A component can only occur once in the tree (unique Flutter identity).
    if (!reached.add(id)) {
      throw FormatException('Component used more than once: $id');
    }
    active.add(id);
    if (component['component'] == 'CookingColumn') {
      for (final child in component['children'] as List) {
        visit(child as String, depth + 1);
      }
    }
    active.remove(id);
  }

  visit('root', 0);
  if (reached.length != components.length) {
    throw const FormatException('Every component must be reachable from root.');
  }
  return components;
}

String requireUiId(Object? value, String field) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(value)) {
    throw FormatException('$field must be a short alphanumeric ID.');
  }
  return value;
}

void _text(Map<String, dynamic> data, String key, {bool optional = false}) {
  final value = data[key];
  if (optional && !data.containsKey(key)) return;
  if (value is! String || value.trim().isEmpty || value.length > 600) {
    throw FormatException('$key must contain 1-600 characters.');
  }
}

void _validateComponent(Map<String, dynamic> data) {
  final type = data['component'];
  final Set<String> fields;
  switch (type) {
    case 'CookingColumn':
      fields = {'children'};
      final children = data['children'];
      if (children is! List || children.length > 15) {
        throw const FormatException('children must contain up to 15 IDs.');
      }
      for (final child in children) {
        requireUiId(child, 'child');
      }
    case 'ingredientChecklist':
      fields = {'title', 'items'};
      _text(data, 'title');
      final items = data['items'];
      if (items is! List || items.isEmpty || items.length > 24) {
        throw const FormatException('Supply 1-24 ingredient candidates.');
      }
      final ids = <String>{};
      for (final item in items) {
        if (item is! Map<String, dynamic> ||
            item.keys.any((key) => key != 'id' && key != 'label')) {
          throw const FormatException('Ingredient needs only id and label.');
        }
        if (!ids.add(requireUiId(item['id'], 'ingredient id'))) {
          throw const FormatException('Duplicate ingredient ID.');
        }
        _text(item, 'label');
      }
    case 'stepCue':
      fields = {'title', 'body', 'action', 'actionLabel'};
      _text(data, 'title');
      _text(data, 'body');
      _text(data, 'actionLabel', optional: true);
      if (data.containsKey('action') &&
          !cookingActions.contains(data['action'])) {
        throw const FormatException('Unknown cooking action.');
      }
    case 'cookQuestion':
      fields = {'title', 'question', 'options'};
      _text(data, 'title');
      _text(data, 'question');
      final options = data['options'];
      if (options is! List || options.length < 2 || options.length > 4) {
        throw const FormatException(
          'A cook question needs 2-4 answer choices.',
        );
      }
      final ids = <String>{};
      for (final option in options) {
        if (option is! Map<String, dynamic> ||
            option.keys.any((key) => key != 'id' && key != 'label')) {
          throw const FormatException(
            'Each answer choice needs only id and label.',
          );
        }
        if (!ids.add(requireUiId(option['id'], 'option ID'))) {
          throw const FormatException('Duplicate answer choice ID.');
        }
        _text(option, 'label');
      }
    case 'comparison':
      fields = {'title', 'observed', 'target', 'cue'};
      for (final key in fields) {
        _text(data, key);
      }
    case 'watchStatus':
      fields = {'title', 'body', 'status'};
      _text(data, 'title');
      _text(data, 'body');
      if (!{'watching', 'check_now', 'paused'}.contains(data['status'])) {
        throw const FormatException('Invalid watch status.');
      }
    case 'cookingTimer':
      fields = {'timerId', 'label'};
      requireUiId(data['timerId'], 'timerId');
      _text(data, 'label');
    case 'dinnerReady':
      fields = {'title', 'message'};
      _text(data, 'title');
      _text(data, 'message');
    case 'donenessGauge':
      fields = {'title', 'percent', 'currentTexture', 'targetTexture', 'cue'};
      _text(data, 'title');
      final percent = data['percent'];
      if (percent is! int || percent < 0 || percent > 100) {
        throw const FormatException(
          'donenessGauge percent must be an int between 0 and 100.',
        );
      }
      _text(data, 'currentTexture');
      _text(data, 'targetTexture');
      _text(data, 'cue');
    default:
      throw FormatException('Unsupported cooking component: $type');
  }
  if (data.keys.any((key) => !{'id', 'component', ...fields}.contains(key))) {
    throw FormatException('Unexpected property on $type.');
  }
}
