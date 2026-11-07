import 'package:collection/collection.dart';

import '../core/cooking_research.dart';

/// Stable client for one displayed research request. The panel's first fetch
/// joins the coordinator's existing request; user follow-ups remain real calls.
class ResearchPanelClient implements CookingResearchClient {
  ResearchPanelClient({
    required this.query,
    required this.initialResult,
    required this.isCurrent,
    required this.followUp,
  });

  final CookingResearchQuery query;
  final Future<CookingResearchResult?> initialResult;
  final bool Function() isCurrent;
  final Future<CookingResearchResult?> Function(CookingResearchQuery) followUp;
  bool _seedAvailable = true;

  @override
  Future<CookingResearchResult> research(CookingResearchQuery request) async {
    if (!isCurrent()) throw StateError('Cooking context changed.');
    final useSeed =
        _seedAvailable &&
        request.question == query.question &&
        request.currentStep == query.currentStep &&
        const ListEquality<String>().equals(
          request.confirmedIngredients,
          query.confirmedIngredients,
        );
    _seedAvailable = false;
    final result = await (useSeed ? initialResult : followUp(request));
    if (!isCurrent()) throw StateError('Cooking context changed.');
    if (result == null) throw StateError('Research is unavailable.');
    return result;
  }
}

/// One panel identity survives ordinary app rebuilds. Changing the question or
/// cooking context replaces/hides it instead of redispatching from build().
class ResearchPanelRequest {
  const ResearchPanelRequest({
    required this.query,
    required this.client,
    required this.revision,
    required this.stepId,
  });
  final CookingResearchQuery query;
  final ResearchPanelClient client;
  final int? revision;
  final String stepId;
}
