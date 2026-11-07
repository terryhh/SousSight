import 'dart:async';

import 'package:flutter/material.dart';

import 'core/cooking_research.dart';
import 'research/cooking_research_panel.dart';
import 'research/fake_cooking_research_client.dart';

void main() {
  runApp(const ResearchDemoApp());
}

final ThemeData _researchDemoTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff285b43),
    primary: const Color(0xff285b43),
    secondary: const Color(0xffbf5b32),
    surface: const Color(0xfffffdf8),
  ),
  scaffoldBackgroundColor: const Color(0xfff5f1e8),
  cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xffd5cfc2)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xffd5cfc2)),
    ),
  ),
);

/// Isolated camera-free demo app for ticket SS-005 (`CookingResearchPanel`).
class ResearchDemoApp extends StatelessWidget {
  const ResearchDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SousSight · Grounded Research Demo',
      debugShowCheckedModeBanner: false,
      theme: _researchDemoTheme,
      home: const ResearchDemoHomePage(),
    );
  }
}

class ResearchDemoHomePage extends StatefulWidget {
  const ResearchDemoHomePage({super.key});

  @override
  State<ResearchDemoHomePage> createState() => _ResearchDemoHomePageState();
}

class _ResearchDemoHomePageState extends State<ResearchDemoHomePage> {
  final DemoCookingResearchClient _client = DemoCookingResearchClient(
    scenario: ResearchDemoScenario.lemonVinegarClarificationFlow,
    simulatedDelay: const Duration(milliseconds: 220),
  );

  ResearchDemoScenario _selectedScenario =
      ResearchDemoScenario.lemonVinegarClarificationFlow;

  CookingResearchQuery _currentQuery = const CookingResearchQuery(
    question: "I don't have lemon—can I use vinegar?",
    currentStep: 'Step 2: Whisk bright lemon-tahini dressing for spiced chickpeas',
    confirmedIngredients: <String>[
      '1 can chickpeas (rinsed)',
      '2 tbsp tahini',
      '1 clove garlic',
    ],
  );

  final List<String> _sessionConfirmedFacts = <String>[];
  String? _lastOpenedCitationUrl;
  String? _staleStatusNotice;
  bool _panelVisible = true;

  void _selectScenario(ResearchDemoScenario scenario) {
    setState(() {
      _selectedScenario = scenario;
      _client.scenario = scenario;
      _client.resetScenarioState();
      _staleStatusNotice = null;
      _panelVisible = true;

      switch (scenario) {
        case ResearchDemoScenario.lemonVinegarClarificationFlow:
          _currentQuery = const CookingResearchQuery(
            question: "I don't have lemon—can I use vinegar?",
            currentStep:
                'Step 2: Whisk bright lemon-tahini dressing for spiced chickpeas',
            confirmedIngredients: <String>[
              '1 can chickpeas (rinsed)',
              '2 tbsp tahini',
            ],
          );
        case ResearchDemoScenario.noCitationsReturned:
          _currentQuery = const CookingResearchQuery(
            question: 'Can I use vinegar when no web citations are returned?',
            currentStep: 'Step 2: Season the chickpea wrap filling',
            confirmedIngredients: <String>['1 can chickpeas'],
          );
        case ResearchDemoScenario.timeoutThenRetrySuccess:
          _currentQuery = const CookingResearchQuery(
            question:
                "I don't have lemon—can I use vinegar? (Timeout → Retry test)",
            currentStep: 'Step 2: Whisk dressing',
            confirmedIngredients: <String>['Apple cider vinegar'],
          );
        case ResearchDemoScenario.lateResponseStaleRejection:
          _client.pendingStaleRequest = Completer<CookingResearchResult>();
          _currentQuery = const CookingResearchQuery(
            question:
                "Old question #1: I don't have lemon—can I use vinegar? (Pending slow request)",
            currentStep: 'Step 2: Whisk dressing',
            confirmedIngredients: <String>['1 can chickpeas'],
          );
          _staleStatusNotice =
              'Old question #1 is waiting in flight. Click "2. Ask Newer Question" below, then "3. Resolve Late Old Response" to verify the stale response is ignored.';
      }
    });
  }

  void _askNewerQuestionDuringPendingOldRequest() {
    setState(() {
      _currentQuery = const CookingResearchQuery(
        question:
            'New question #2: How much ground cumin replaces whole cumin seeds?',
        currentStep: 'Step 3: Toast spices for the chickpea filling',
        confirmedIngredients: <String>['Ground cumin', '1 can chickpeas'],
      );
      _staleStatusNotice =
          'New question #2 is now active. Now click "3. Resolve Late Old Response" to fire the late response from Question #1 and verify it does NOT overwrite Question #2.';
    });
  }

  void _resolveLateOldResponse() {
    final pending = _client.pendingStaleRequest;
    if (pending != null && !pending.isCompleted) {
      pending.complete(
        const CookingResearchResult(
          answer:
              'STALE RESULT FROM OLD QUESTION #1 (Should NEVER appear over Question #2!)',
          citations: <CookingCitation>[],
        ),
      );
      setState(() {
        _staleStatusNotice =
            'Late response for Old Question #1 completed in background and was safely rejected! Question #2 remains intact.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildDemoBanner(theme),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth >= 880;
                      final scenarioSidebar = _buildScenarioSidebar(theme);
                      final workspaceArea = _buildWorkspaceArea(theme);

                      if (!isWide) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            scenarioSidebar,
                            const SizedBox(height: 20),
                            workspaceArea,
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 340, child: scenarioSidebar),
                          const SizedBox(width: 24),
                          Expanded(child: workspaceArea),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDemoBanner(ThemeData theme) {
    return Container(
      key: const Key('demo_rehearsal_banner'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xfffbe8c9),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xffe0c08d)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.science_outlined, color: Color(0xff6b440b)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Scripted Camera-Free Research Demo · No Live Google Calls',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xff4a2e04),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'This isolated entrypoint exercises CookingResearchPanel with deterministic fake clients. The cook is the human in the loop—no external instructor queue is used.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xff5c3b09),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScenarioSidebar(ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Demo Scenarios (SS-005)',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Switch scenarios to inspect each required state:',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _scenarioButton(
              key: const Key('scenario_lemon_vinegar_button'),
              scenario: ResearchDemoScenario.lemonVinegarClarificationFlow,
              title: '1. Missing Lemon → Clarification → Cited Answer',
              subtitle:
                  'Ask about vinegar, answer clarification, inspect HTTPS sources, and confirm substitution.',
              icon: Icons.question_answer_outlined,
            ),
            const SizedBox(height: 8),
            _scenarioButton(
              key: const Key('scenario_no_citations_button'),
              scenario: ResearchDemoScenario.noCitationsReturned,
              title: '2. Answer Without Citations',
              subtitle:
                  'Distinguishes uncited answers without fabricating sources.',
              icon: Icons.link_off_rounded,
            ),
            const SizedBox(height: 8),
            _scenarioButton(
              key: const Key('scenario_timeout_retry_button'),
              scenario: ResearchDemoScenario.timeoutThenRetrySuccess,
              title: '3. Timeout → Retry Preserves Question',
              subtitle:
                  'First attempt times out; clicking Retry succeeds while keeping the original question.',
              icon: Icons.refresh_rounded,
            ),
            const SizedBox(height: 8),
            _scenarioButton(
              key: const Key('scenario_late_stale_button'),
              scenario: ResearchDemoScenario.lateResponseStaleRejection,
              title: '4. Late Response to Old Question',
              subtitle:
                  'Proves an older in-flight response cannot overwrite a newer question.',
              icon: Icons.history_toggle_off_rounded,
            ),
            if (_selectedScenario ==
                ResearchDemoScenario.lateResponseStaleRejection) ...[
              const Divider(height: 24),
              Text(
                'Stale Response Controls',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                key: const Key('demo_ask_newer_question_button'),
                onPressed: _askNewerQuestionDuringPendingOldRequest,
                icon: const Icon(Icons.fast_forward_rounded, size: 18),
                label: const Text('2. Ask Newer Question'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('demo_resolve_stale_response_button'),
                onPressed: _resolveLateOldResponse,
                icon: const Icon(Icons.schedule_send_rounded, size: 18),
                label: const Text('3. Resolve Late Old Response'),
              ),
              if (_staleStatusNotice != null) ...[
                const SizedBox(height: 8),
                Text(
                  _staleStatusNotice!,
                  key: const Key('demo_stale_status_notice'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
            const Divider(height: 24),
            Text(
              'Confirmed Session Log',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            if (_sessionConfirmedFacts.isEmpty)
              Text(
                'No facts confirmed yet. Only explicit cook confirmation adds items here.',
                key: const Key('demo_empty_confirmed_log'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final fact in _sessionConfirmedFacts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(fact, style: theme.textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
            if (_lastOpenedCitationUrl != null) ...[
              const SizedBox(height: 12),
              Text(
                'Last opened HTTPS source:\n$_lastOpenedCitationUrl',
                key: const Key('demo_last_opened_source'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _scenarioButton({
    required Key key,
    required ResearchDemoScenario scenario,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final selected = _selectedScenario == scenario;
    final theme = Theme.of(context);
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(14),
      onTap: () => _selectScenario(scenario),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.65)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkspaceArea(ThemeData theme) {
    if (!_panelVisible) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Text('Research panel dismissed.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('demo_reopen_panel_button'),
                onPressed: () => setState(() => _panelVisible = true),
                icon: const Icon(Icons.open_in_full_rounded),
                label: const Text('Reopen Research Panel'),
              ),
            ],
          ),
        ),
      );
    }

    return CookingResearchPanel(
      client: _client,
      query: _currentQuery,
      onCookConfirmed: (fact) {
        setState(() {
          if (!_sessionConfirmedFacts.contains(fact)) {
            _sessionConfirmedFacts.add(fact);
          }
        });
      },
      onOpenSource: (citation) {
        setState(() {
          _lastOpenedCitationUrl = citation.uri.toString();
        });
      },
      onDismiss: () {
        setState(() {
          _panelVisible = false;
        });
      },
    );
  }
}
