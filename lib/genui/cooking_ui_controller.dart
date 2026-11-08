import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as a2ui;
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';

import 'cooking_catalog.dart';
import 'cooking_ui_contract.dart';

class CookingUiAction {
  const CookingUiAction(this.name, this.componentId, [this.context = const {}]);

  final String name;
  final String componentId;
  final Map<String, dynamic> context;

  Map<String, dynamic> toJson() => {
    'name': name,
    'componentId': componentId,
    'context': context,
  };
}

class CookingTimerState {
  CookingTimerState({
    required this.id,
    required this.label,
    required this.startedAt,
    required this.deadline,
  });

  final String id;
  final String label;
  final DateTime startedAt;
  final DateTime deadline;
  bool _announced = false;
  bool get announced => _announced;

  Duration remaining(DateTime now) =>
      deadline.isAfter(now) ? deadline.difference(now) : Duration.zero;
}

/// Owns a real GenUI SurfaceController and the client-owned cooking state.
/// Only trusted catalog components are accepted. AI updates cannot confirm
/// ingredients, restart existing timers, or send a dinner message.
class CookingUiController extends ChangeNotifier {
  CookingUiController({this.onAction, DateTime Function()? clock})
    : clock = clock ?? DateTime.now {
    catalog = buildCookingCatalog(this);
    engine = SurfaceController(catalogs: [catalog]);
    engine.handleMessage(
      a2ui.CreateSurfaceMessage(surfaceId: surfaceId, catalogId: catalogId),
    );
    _render();
  }

  static const surfaceId = 'cooking-workspace';
  static const catalogId = 'app.soussight.cooking';

  final void Function(CookingUiAction action)? onAction;
  final DateTime Function() clock;
  late final Catalog catalog;
  late final SurfaceController engine;
  final Map<String, CookingTimerState> _timers = {};
  final Set<String> _confirmedIngredients = {};
  final Set<String> _dismissedTimerIds = {};
  final Map<String, String> _answeredQuestions = {};
  List<Map<String, dynamic>> _components = [
    {'id': 'root', 'component': 'CookingColumn', 'children': <String>[]},
  ];
  Timer? _ticker;
  bool _disposed = false;
  final Set<String> _renderedIds = {};
  int _generation = 0;
  int get generation => _generation;

  List<CookingTimerState> get timers => List.unmodifiable(_timers.values);
  Set<String> get confirmedIngredients =>
      Set.unmodifiable(_confirmedIngredients);
  List<Map<String, dynamic>> get components =>
      (jsonDecode(jsonEncode(_components)) as List)
          .cast<Map<String, dynamic>>();

  void applyJson(String json) {
    _assertActive();
    if (json.length > 24000) {
      throw const FormatException('Cooking UI exceeds 24 KB.');
    }
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Cooking UI must be an object.');
    }
    applyToolPayload(decoded);
  }

  void applyToolPayload(Map<String, dynamic> payload) {
    _assertActive();
    if (jsonEncode(payload).length > 24000) {
      throw const FormatException('Cooking UI exceeds 24 KB.');
    }
    // Validate the whole update before replacing any current UI.
    final validated = validateCookingUi(payload);
    _components = validated;
    _render();
  }

  /// Updates one trusted leaf in-place while preserving the remaining workspace.
  void upsertPanel(Map<String, dynamic> component) {
    _assertActive();
    final id = component['id'];
    if (id == 'root' || component['component'] == 'CookingColumn') {
      throw const FormatException('upsertPanel requires a leaf component.');
    }
    final next = components;
    final existing = next.indexWhere((item) => item['id'] == id);
    if (existing >= 0) {
      next[existing] = component;
    } else {
      next.add(component);
      final root = next.firstWhere((item) => item['id'] == 'root');
      root['children'] = [...root['children'] as List, id];
    }
    applyToolPayload({'components': next});
  }

  /// Idempotent by ID. Repeated tool calls never restart or extend a timer.
  CookingTimerState startTimer({
    required String id,
    required String label,
    required int seconds,
  }) {
    _assertActive();
    requireUiId(id, 'timer ID');
    if (label.trim().isEmpty ||
        label.length > 120 ||
        seconds < 1 ||
        seconds > 7200) {
      throw const FormatException('Timer needs a label and 1-7200 seconds.');
    }
    return restoreTimer(
      id: id,
      label: label,
      deadline: clock().add(Duration(seconds: seconds)),
    );
  }

  /// Resume the original wall-clock deadline, including an already elapsed one.
  CookingTimerState restoreTimer({
    required String id,
    required String label,
    required DateTime deadline,
  }) {
    _assertActive();
    requireUiId(id, 'timer ID');
    if (label.trim().isEmpty ||
        label.length > 120 ||
        deadline.difference(clock()).inSeconds > 7200) {
      throw const FormatException('Invalid saved timer.');
    }
    final existing = _timers[id];
    if (existing != null) return existing;
    if (_dismissedTimerIds.contains(id)) {
      throw const FormatException('Use a new ID for a new timer.');
    }
    if (_timers.length >= 4) {
      throw const FormatException('At most four timers can run at once.');
    }
    final now = clock();
    final timer = CookingTimerState(
      id: id,
      label: label,
      startedAt: now,
      deadline: deadline,
    );
    _timers[id] = timer;
    _ticker ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => refreshTimers(),
    );
    _render();
    refreshTimers();
    return timer;
  }

  /// Uses wall-clock deadlines so throttled browser tabs catch up on the next tick.
  void refreshTimers() {
    if (_disposed) return;
    final now = clock();
    for (final timer in _timers.values.toList()) {
      if (!timer._announced && !timer.deadline.isAfter(now)) {
        timer._announced = true;
        dispatch('timer_elapsed', 'timer_${timer.id}', {
          'timerId': timer.id,
          'label': timer.label,
        });
      }
    }
    notifyListeners();
  }

  void dismissTimer(String id) {
    _assertActive();
    if (_timers.remove(id) == null) return;
    _dismissedTimerIds.add(id);
    final removedIds = _components
        .where(
          (item) =>
              item['component'] == 'cookingTimer' && item['timerId'] == id,
        )
        .map((item) => item['id'])
        .toSet();
    _components.removeWhere((item) => removedIds.contains(item['id']));
    for (final component in _components) {
      if (component['component'] == 'CookingColumn') {
        component['children'] = (component['children'] as List)
            .where((child) => !removedIds.contains(child))
            .toList();
      }
    }
    if (_timers.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
    }
    _render();
    dispatch('timer_dismissed', 'timer_$id', {'timerId': id});
  }

  CookingTimerState? timerById(String id) => _timers[id];

  /// The cook's saved answer for [question], if any. Question panels use it to
  /// disable their options so an answered question cannot be answered twice.
  String? answerFor(String question) => _answeredQuestions[question.trim()];

  void markQuestionAnswered(String question, String answer) {
    if (_disposed) return;
    _answeredQuestions[question.trim()] = answer;
    notifyListeners();
  }

  /// The coach explicitly asked again; allow a fresh answer.
  void reopenQuestion(String question) {
    if (_disposed || _answeredQuestions.remove(question.trim()) == null) return;
    notifyListeners();
  }

  /// Restore learner-confirmed state without manufacturing a user action.
  void restoreConfirmedIngredients(Iterable<String> ids) {
    _assertActive();
    final validated = ids.map((id) => requireUiId(id, 'ingredient ID')).toSet();
    _confirmedIngredients
      ..clear()
      ..addAll(validated);
    _writeConfirmedIngredients();
    notifyListeners();
  }

  void confirmIngredient(String componentId, String id, bool confirmed) {
    _assertActive();
    requireUiId(id, 'ingredient ID');
    confirmed
        ? _confirmedIngredients.add(id)
        : _confirmedIngredients.remove(id);
    engine.handleMessage(
      a2ui.UpdateDataModelMessage(
        surfaceId: surfaceId,
        path: '/confirmedIngredients/$id',
        value: confirmed,
      ),
    );
    notifyListeners();
    dispatch('ingredient_confirmed', componentId, {
      'ingredientId': id,
      'confirmed': confirmed,
    });
  }

  void dispatch(
    String name,
    String componentId, [
    Map<String, dynamic> context = const {},
  ]) {
    if (_disposed) return;
    // The A2UI interaction is available to transport subscribers as well as the
    // app's typed callback, which can persist confirmed state or request a turn.
    engine.handleUiEvent(
      UserActionEvent(
        name: name,
        sourceComponentId: componentId,
        surfaceId: surfaceId,
        timestamp: clock(),
        context: context,
      ),
    );
    onAction?.call(CookingUiAction(name, componentId, context));
  }

  /// Reset layout without silently cancelling active timers.
  void clear() {
    _assertActive();
    _components = [
      {'id': 'root', 'component': 'CookingColumn', 'children': <String>[]},
    ];
    _render();
  }

  void _render() {
    // Pinned timers are still GenUI components. The client adds their IDs to the
    // generated root if the model forgets them while morphing the workspace.
    final rendered = components;
    final root = rendered.firstWhere((item) => item['id'] == 'root');
    final children = List<String>.from(root['children'] as List);
    for (final timer in _timers.values) {
      if (rendered.any(
        (item) =>
            item['component'] == 'cookingTimer' && item['timerId'] == timer.id,
      )) {
        continue;
      }
      var id = 'timer_${timer.id}';
      while (rendered.any((item) => item['id'] == id)) {
        id = '${id}_';
      }
      children.add(id);
      rendered.add({
        'id': id,
        'component': 'cookingTimer',
        'timerId': timer.id,
        'label': timer.label,
      });
    }
    root['children'] = children;
    final nextIds = rendered.map((item) => item['id'] as String).toSet();
    // A2UI updateComponents is an upsert. Replace the surface when IDs disappear
    // so old generated trees cannot accumulate forever. App-owned state remains.
    if (_renderedIds.any((id) => !nextIds.contains(id))) {
      engine.handleMessage(a2ui.DeleteSurfaceMessage(surfaceId: surfaceId));
      engine.handleMessage(
        a2ui.CreateSurfaceMessage(surfaceId: surfaceId, catalogId: catalogId),
      );
      _generation++;
      _writeConfirmedIngredients();
    }
    _renderedIds
      ..clear()
      ..addAll(nextIds);
    engine.handleMessage(
      a2ui.UpdateComponentsMessage(surfaceId: surfaceId, components: rendered),
    );
    notifyListeners();
  }

  void _writeConfirmedIngredients() {
    engine.handleMessage(
      a2ui.UpdateDataModelMessage(
        surfaceId: surfaceId,
        path: '/confirmedIngredients',
        value: {for (final id in _confirmedIngredients) id: true},
      ),
    );
  }

  void _assertActive() {
    if (_disposed) throw StateError('Cooking UI controller has been disposed.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    engine.dispose();
    super.dispose();
  }
}
