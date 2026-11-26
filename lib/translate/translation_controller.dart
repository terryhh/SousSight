// The cook's language choice and the recipe translation shown for it
// (SS-106).

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'cook_language.dart';
import 'recipe_translator.dart';

class TranslationController extends ChangeNotifier {
  TranslationController({
    required this.translator,
    Future<int?> Function()? localTokenBudget,
    CookLanguage initial = sourceLanguage,
  }) : _budget = localTokenBudget,
       _language = initial;

  final RecipeTranslator translator;

  /// The local model's total token budget, when the bridge reports one.
  final Future<int?> Function()? _budget;

  CookLanguage _language;
  RecipeTranslation? _translation;
  bool _busy = false;
  bool _showOriginal = false;
  bool _disposed = false;

  /// Bumped by every request, cancel and dispose; a result is applied only
  /// while its request is still the latest.
  int _epoch = 0;

  /// The language recipe content and AI answers use.
  CookLanguage get language => _language;

  /// The latest finished translation for [language], if any.
  RecipeTranslation? get translation => _translation;
  bool get busy => _busy;

  /// The cook asked to see the English original.
  bool get showOriginal => _showOriginal;

  set showOriginal(bool value) {
    if (_showOriginal == value) return;
    _showOriginal = value;
    _notify();
  }

  /// The translation to show for [recipe], or null for the original: the
  /// source language, "Show original", a stale recipe or nothing yet.
  RecipeTranslation? shownFor(Recipe recipe) {
    final t = _translation;
    if (t == null || _showOriginal || _language.isSource) return null;
    if (t.key != TranslationKey.of(recipe, _language)) return null;
    return switch (t.status) {
      TranslationStatus.complete || TranslationStatus.partial => t,
      _ => null,
    };
  }

  /// Text for [lineId] of [recipe], translated when one is shown.
  String text(Recipe recipe, String lineId, String original) =>
      shownFor(recipe)?.text(lineId, original) ?? original;

  /// Chooses [value] and translates [recipe] into it. [sessionId] is the
  /// cooking session the sends belong to.
  Future<void> select(
    CookLanguage value, {
    required Recipe recipe,
    required String sessionId,
  }) async {
    if (_disposed) return;
    final epoch = ++_epoch;
    translator.cancel();
    _language = value;
    _showOriginal = false;
    _translation = null;
    if (value.isSource) {
      _busy = false;
      _notify();
      return;
    }
    _busy = true;
    _notify();

    int? budget;
    try {
      budget = await _budget?.call();
    } catch (_) {
      budget = null;
    }
    if (!_current(epoch)) return;

    final RecipeTranslation result;
    try {
      result = await translator.translate(
        recipe,
        value,
        sessionId: sessionId,
        maxTotalTokens: budget ?? translateDefaultMaxTotalTokens,
      );
    } catch (_) {
      if (!_current(epoch)) return;
      _busy = false;
      _notify();
      return;
    }
    if (!_current(epoch) || result.status == TranslationStatus.cancelled) {
      return;
    }
    _translation = result;
    _busy = false;
    _notify();
  }

  /// Re-translates when the recipe (or its version) changed under a
  /// non-source language. Does nothing when the current one still fits.
  Future<void> recipeChanged(Recipe recipe, {required String sessionId}) {
    if (_language.isSource) return Future.value();
    final t = _translation;
    if (!_busy && t != null && t.key == TranslationKey.of(recipe, _language)) {
      return Future.value();
    }
    return select(_language, recipe: recipe, sessionId: sessionId);
  }

  /// Stops a running translation. The language choice stays.
  void cancel() {
    _epoch++;
    translator.cancel();
    if (_busy) {
      _busy = false;
      _notify();
    }
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    translator.cancel();
    super.dispose();
  }
}
