import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../core/cooking_research.dart';
import 'search_suggestions.dart';

/// Validates whether a [CookingCitation] has a safe, clickable HTTPS URL.
///
/// Rejects non-HTTPS schemes (`http`, `javascript`, `data`, etc.), missing
/// authority/host, or embedded user credentials (`user:pass@host`).
bool isValidHttpsCitation(CookingCitation citation) {
  final uri = citation.uri;
  return uri.scheme.toLowerCase() == 'https' &&
      uri.hasAuthority &&
      uri.host.trim().isNotEmpty &&
      uri.userInfo.isEmpty;
}

/// Returns deduplicated, valid HTTPS citations in their original order.
List<CookingCitation> filterValidHttpsCitations(
  Iterable<CookingCitation> citations,
) {
  final valid = <CookingCitation>[];
  final seenUris = <String>{};
  for (final citation in citations) {
    if (!isValidHttpsCitation(citation)) continue;
    final normalizedUri = citation.uri.toString();
    if (!seenUris.add(normalizedUri)) continue;
    final cleanTitle = citation.title.trim();
    valid.add(
      CookingCitation(
        title: cleanTitle.isEmpty ? citation.uri.host : cleanTitle,
        uri: citation.uri,
      ),
    );
  }
  return List<CookingCitation>.unmodifiable(valid);
}

/// Grounded answer and substitution workspace panel for SousSight.
///
/// **The cook is the human in the loop.** When context is missing, the panel
/// asks the cook a targeted clarifying question and preserves all confirmed
/// facts. Before any substitution or kitchen fact is recorded, the cook reviews
/// and edits the exact statement in an editable field and explicitly confirms it.
class CookingResearchPanel extends StatefulWidget {
  const CookingResearchPanel({
    super.key,
    required this.client,
    required this.query,
    required this.onCookConfirmed,
    this.onOpenSource,
    this.onDismiss,
  });

  final CookingResearchClient client;
  final CookingResearchQuery query;
  final void Function(String fact) onCookConfirmed;
  final void Function(CookingCitation citation)? onOpenSource;
  final VoidCallback? onDismiss;

  @override
  State<CookingResearchPanel> createState() => _CookingResearchPanelState();
}

class _CookingResearchPanelState extends State<CookingResearchPanel> {
  final TextEditingController _clarificationController =
      TextEditingController();
  final TextEditingController _confirmationController = TextEditingController();

  late CookingResearchQuery _activeQuery;
  late List<String> _confirmedFacts;

  CookingResearchResult? _result;
  CookingResearchQuery? _resultQuery;
  String? _errorMessage;
  bool _isLoading = false;
  bool _isExpanded = true;
  String? _lastConfirmedFact;
  String? _clarificationError;
  String? _confirmationError;

  /// Monotonically increasing token to reject late/stale async responses.
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _syncFromWidgetQuery(widget.query, clearResultAndDrafts: true);
    _runResearch(_activeQuery, clearExistingResult: true);
  }

  @override
  void didUpdateWidget(covariant CookingResearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final queryChanged = !_queriesEqual(oldWidget.query, widget.query);
    final clientChanged = !identical(oldWidget.client, widget.client);
    if (queryChanged || clientChanged) {
      _syncFromWidgetQuery(widget.query, clearResultAndDrafts: true);
      _runResearch(_activeQuery, clearExistingResult: true);
    }
  }

  bool _queriesEqual(CookingResearchQuery a, CookingResearchQuery b) {
    return a.question == b.question &&
        a.currentStep == b.currentStep &&
        const ListEquality<String>().equals(
          a.confirmedIngredients,
          b.confirmedIngredients,
        );
  }

  void _syncFromWidgetQuery(
    CookingResearchQuery incoming, {
    required bool clearResultAndDrafts,
  }) {
    _confirmedFacts = List<String>.from(incoming.confirmedIngredients);
    _activeQuery = CookingResearchQuery(
      question: incoming.question,
      currentStep: incoming.currentStep,
      confirmedIngredients: List<String>.unmodifiable(_confirmedFacts),
    );
    _clarificationError = null;
    if (clearResultAndDrafts) {
      _result = null;
      _resultQuery = null;
      _errorMessage = null;
      _clarificationController.clear();
      _confirmationController.clear();
      _lastConfirmedFact = null;
      _confirmationError = null;
    }
  }

  Future<void> _runResearch(
    CookingResearchQuery requestQuery, {
    required bool clearExistingResult,
  }) async {
    final generation = ++_requestGeneration;
    setState(() {
      _activeQuery = requestQuery;
      _isLoading = true;
      _errorMessage = null;
      _clarificationError = null;
      if (clearExistingResult) {
        _result = null;
        _resultQuery = null;
      }
    });

    try {
      final response = await widget.client.research(requestQuery);
      if (!mounted || generation != _requestGeneration) {
        // Stale response for an older question or superseded retry; ignore it.
        return;
      }
      setState(() {
        _result = response;
        _resultQuery = requestQuery;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = _friendlyErrorMessage(error);
      });
    }
  }

  String _friendlyErrorMessage(Object error) {
    final text = error.toString().trim();
    if (text.isNotEmpty &&
        !text.startsWith('Instance of ') &&
        !text.contains('Exception:') &&
        !text.contains('Error:') &&
        text.length <= 220) {
      return text;
    }
    if (text.toLowerCase().contains('timeout')) {
      return 'The cooking search took too long. Please retry your question.';
    }
    return 'Could not complete the cooking search right now. Check your connection or retry.';
  }

  void _retryCurrentQuestion() {
    // Re-dispatch the exact active query (preserving original question and
    // confirmed facts) with a new generation token.
    _runResearch(_activeQuery, clearExistingResult: false);
  }

  void _submitClarification() {
    final detail = _clarificationController.text.trim();
    if (detail.isEmpty) {
      setState(() {
        _clarificationError =
            'Enter a short answer so we can research the right option for your kitchen.';
      });
      return;
    }

    final updatedFacts = <String>[
      ..._confirmedFacts,
      if (!_confirmedFacts.contains(detail)) detail,
    ];
    _confirmedFacts = updatedFacts;
    _clarificationController.clear();

    final followUpQuery = CookingResearchQuery(
      question: widget.query.question,
      currentStep: _activeQuery.currentStep,
      confirmedIngredients: List<String>.unmodifiable(_confirmedFacts),
    );
    _runResearch(followUpQuery, clearExistingResult: true);
  }

  void _confirmFact() {
    final fact = _confirmationController.text.trim();
    if (fact.isEmpty) {
      setState(() {
        _confirmationError =
            'Review or type the substitution fact you want to use before confirming.';
      });
      return;
    }
    setState(() {
      _confirmationError = null;
      _lastConfirmedFact = fact;
      if (!_confirmedFacts.contains(fact)) {
        _confirmedFacts = <String>[..._confirmedFacts, fact];
      }
    });
    widget.onCookConfirmed(fact);
  }

  bool get _hasMatchingResult =>
      _result != null &&
      _resultQuery != null &&
      _resultQuery!.question == _activeQuery.question &&
      _resultQuery!.currentStep == _activeQuery.currentStep;

  @override
  void dispose() {
    _clarificationController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeResult = _hasMatchingResult ? _result : null;
    final validCitations = activeResult == null
        ? const <CookingCitation>[]
        : filterValidHttpsCitations(activeResult.citations);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Card(
          key: const Key('cooking_research_panel'),
          clipBehavior: Clip.antiAlias,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(theme),
                const SizedBox(height: 12),
                _buildQuestionBox(theme),
                if (!_isExpanded) ...[
                  const SizedBox(height: 10),
                  _buildCollapsedSummary(theme, activeResult),
                ] else ...[
                  if (_confirmedFacts.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildConfirmedFactsRow(theme),
                  ],
                  if (_isLoading) ...[
                    const SizedBox(height: 16),
                    _buildLoadingState(theme),
                  ],
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    _buildErrorState(theme, _errorMessage!),
                  ],
                  if (activeResult != null) ...[
                    const SizedBox(height: 16),
                    _buildResultSection(theme, activeResult, validCitations),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.travel_explore_rounded,
            color: theme.colorScheme.onPrimaryContainer,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Grounded Cooking Research',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                'Step: ${_activeQuery.currentStep}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('research_toggle_collapse_button'),
          onPressed: () => setState(() => _isExpanded = !_isExpanded),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip:
              _isExpanded ? 'Minimize research panel' : 'Expand research panel',
          icon: Icon(
            _isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          ),
        ),
        if (widget.onDismiss != null)
          IconButton(
            key: const Key('research_dismiss_button'),
            onPressed: widget.onDismiss,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: 'Close research panel',
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
  }

  Widget _buildQuestionBox(ThemeData theme) {
    return Container(
      key: const Key('research_original_question_box'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'YOUR QUESTION',
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            widget.query.question,
            key: const Key('research_original_question_text'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedSummary(
    ThemeData theme,
    CookingResearchResult? activeResult,
  ) {
    final statusText = _isLoading
        ? 'Searching grounded cooking sources… (pending result preserved)'
        : _errorMessage != null
        ? 'Search paused with an error. Expand to retry.'
        : activeResult != null
        ? 'Answer ready. Expand to review details and sources.'
        : 'Expand to view cooking research.';
    return InkWell(
      key: const Key('research_collapsed_summary'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _isExpanded = true),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            if (_isLoading) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
            ] else ...[
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                statusText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _isExpanded = true),
              child: const Text('Show'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmedFactsRow(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cook-confirmed kitchen facts',
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final fact in _confirmedFacts)
              Chip(
                avatar: Icon(
                  Icons.check_circle_outline_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                label: Text(fact),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildLoadingState(ThemeData theme) {
    return Container(
      key: const Key('research_loading_indicator'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Looking up grounded cooking guidance…',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Checking your question and confirmed kitchen facts.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(ThemeData theme, String message) {
    return Container(
      key: const Key('research_error_container'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  key: const Key('research_error_text'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              key: const Key('research_retry_button'),
              onPressed: _isLoading ? null : _retryCurrentQuestion,
              style: FilledButton.styleFrom(
                minimumSize: const Size(120, 48),
              ),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry search'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultSection(
    ThemeData theme,
    CookingResearchResult result,
    List<CookingCitation> validCitations,
  ) {
    final hasClarification =
        result.clarifyingQuestion != null &&
        result.clarifyingQuestion!.trim().isNotEmpty;
    final hasValidSources = validCitations.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSourceStatusBadge(theme, hasValidSources, validCitations.length),
        const SizedBox(height: 12),
        SelectableText(
          result.answer,
          key: const Key('research_answer_text'),
          style: theme.textTheme.bodyLarge?.copyWith(
            height: 1.55,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 16),
        _buildCitationsSection(theme, validCitations),
        if (result.searchSuggestionsHtml != null &&
            result.searchSuggestionsHtml!.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          SearchSuggestions(
            key: const Key('research_search_suggestions'),
            html: result.searchSuggestionsHtml,
          ),
        ],
        if (hasClarification) ...[
          const SizedBox(height: 18),
          _buildClarificationCard(theme, result.clarifyingQuestion!.trim()),
        ],
        const SizedBox(height: 18),
        _buildConfirmationSection(theme),
        const SizedBox(height: 12),
        _buildSafetyAndRetryFooter(theme),
      ],
    );
  }

  Widget _buildSourceStatusBadge(
    ThemeData theme,
    bool hasValidSources,
    int sourceCount,
  ) {
    final bgColor = hasValidSources
        ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.7)
        : theme.colorScheme.surfaceContainerHighest;
    final fgColor = hasValidSources
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: Key(
          hasValidSources
              ? 'research_badge_source_backed'
              : 'research_badge_uncited',
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasValidSources
                  ? Icons.verified_outlined
                  : Icons.info_outline_rounded,
              size: 16,
              color: fgColor,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                hasValidSources
                    ? 'Source-backed answer ($sourceCount ${sourceCount == 1 ? 'source' : 'sources'})'
                    : 'Unverified answer · No web sources returned',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: fgColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCitationsSection(
    ThemeData theme,
    List<CookingCitation> validCitations,
  ) {
    if (validCitations.isEmpty) {
      return Container(
        key: const Key('research_no_citations_notice'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.link_off_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No verified HTTPS citations were returned for this answer. Treat this guidance with care and verify with your recipe or kitchen judgment.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SOURCES',
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < validCitations.length; i++)
              OutlinedButton.icon(
                key: Key('research_citation_button_$i'),
                onPressed: widget.onOpenSource == null
                    ? null
                    : () => widget.onOpenSource!(validCitations[i]),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      validCitations[i].title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      validCitations[i].uri.host,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildClarificationCard(ThemeData theme, String clarifyingQuestion) {
    return Container(
      key: const Key('research_clarification_card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.tertiary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.help_outline_rounded,
                size: 20,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Quick question for the cook',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            clarifyingQuestion,
            key: const Key('research_clarifying_question_text'),
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('research_clarification_input'),
            controller: _clarificationController,
            enabled: !_isLoading,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submitClarification(),
            decoration: InputDecoration(
              labelText: 'Your kitchen detail',
              hintText: 'e.g., I have apple cider vinegar and canned chickpeas',
              errorText: _clarificationError,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('research_clarification_submit_button'),
              onPressed: _isLoading ? null : _submitClarification,
              style: FilledButton.styleFrom(
                minimumSize: const Size(160, 48),
              ),
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('Update research'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmationSection(ThemeData theme) {
    return Container(
      key: const Key('research_confirmation_section'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.edit_note_rounded,
                size: 22,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Confirm substitution or kitchen fact',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'SousSight never changes your recipe automatically. Review and edit the exact substitution or fact below before confirming it for your session.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('research_confirmation_input'),
            controller: _confirmationController,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _confirmFact(),
            decoration: InputDecoration(
              labelText: 'Fact to record for your session',
              hintText: 'e.g., Using 1 tbsp apple cider vinegar instead of lemon',
              errorText: _confirmationError,
            ),
          ),
          if (_lastConfirmedFact != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Confirmed: $_lastConfirmedFact',
                    key: const Key('research_confirmed_feedback_text'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('research_confirm_fact_button'),
              onPressed: _confirmFact,
              style: FilledButton.styleFrom(
                minimumSize: const Size(180, 48),
              ),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Confirm for my cook'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSafetyAndRetryFooter(ThemeData theme) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Vision and web answers cannot verify internal temperature or food safety.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        TextButton.icon(
          key: const Key('research_footer_retry_button'),
          onPressed: _isLoading ? null : _retryCurrentQuestion,
          style: TextButton.styleFrom(
            minimumSize: const Size(88, 48),
          ),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Retry'),
        ),
      ],
    );
  }
}
