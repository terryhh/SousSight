import 'dinner_messages.dart';
import 'dinner_status.dart';

/// How household dinner messages are delivered, chosen at build time with
/// `--dart-define=DINNER_MODE=real|simulated`, independent of `FAKE_BACKEND`.
///
/// - [real]: the reviewed message goes to `/api/dinner-ready` (Vonage) and
///   status comes from Firestore. This is the pre-existing behavior.
/// - [simulated]: the app never calls the dinner endpoint. The local
///   [FakeDinnerBackend] plays the send, the recipient is the fictional
///   [simulatedDinnerRecipient], and every status carries [simulatedLabel].
///   AI features are unaffected. The judged #BuildHybridAI build passes
///   `DINNER_MODE=simulated` explicitly.
enum DinnerMode { real, simulated }

/// Fictional recipient shown, and sent to the local fake, in simulated mode.
const simulatedDinnerRecipient = 'Demo household';

const _rawDinnerMode = String.fromEnvironment('DINNER_MODE');

/// The build's [DinnerMode].
///
/// Missing or `real` → [DinnerMode.real], so existing builds keep their
/// current behavior. `simulated` → [DinnerMode.simulated]. Any other value
/// (a typo such as `simulate`) fails safe to [DinnerMode.simulated]: it can
/// never spend on a provider send and is always visibly labelled. CI (SS-079)
/// should still reject unknown values before compiling.
const DinnerMode configuredDinnerMode =
    _rawDinnerMode == '' || _rawDinnerMode == 'real'
    ? DinnerMode.real
    : DinnerMode.simulated;

/// Runtime equivalent of [configuredDinnerMode], for validation and tests.
DinnerMode parseDinnerMode(String? raw) => switch (raw?.trim() ?? '') {
  '' || 'real' => DinnerMode.real,
  _ => DinnerMode.simulated,
};

/// Whether [raw] is a value CI should accept for `DINNER_MODE`.
bool isKnownDinnerMode(String? raw) =>
    raw == null || raw.isEmpty || raw == 'real' || raw == 'simulated';

/// The sender for [mode].
///
/// Simulated mode always uses [fake] and turns a plain confirm into a
/// simulated delivery, so the cook's reviewed message produces a labelled
/// "Simulated — no SMS sent." status instead of a silent rehearsal. Real mode
/// keeps the existing choice: [fake] in `FAKE_BACKEND` rehearsals, otherwise
/// [real] (the Vonage endpoint).
DinnerMessageSender dinnerSenderFor(
  DinnerMode mode, {
  required bool isDemo,
  required FakeDinnerBackend fake,
  DinnerMessageSender real = sendDinnerMessage,
}) => switch (mode) {
  DinnerMode.simulated => (request) => fake.send(_asSimulated(request)),
  DinnerMode.real => isDemo ? fake.send : real,
};

/// The status source for [mode]; [real] is only built in a real, non-demo
/// build so simulated builds never open a Firestore listener for it.
DinnerStatusSource dinnerStatusFor(
  DinnerMode mode, {
  required bool isDemo,
  required FakeDinnerBackend fake,
  DinnerStatusSource Function() real = FirestoreDinnerStatusSource.new,
}) => mode == DinnerMode.simulated || isDemo ? fake : real();

/// Whether a household send may be counted in analytics. Simulated-mode and
/// `FAKE_BACKEND` sends never reached a provider, so they are not counted.
bool dinnerAnalyticsEnabled(DinnerMode mode, {required bool isDemo}) =>
    mode == DinnerMode.real && !isDemo;

DinnerMessageRequest _asSimulated(DinnerMessageRequest request) =>
    DinnerMessageRequest(
      sessionId: request.sessionId,
      notificationId: request.notificationId,
      recipient: simulatedDinnerRecipient,
      kind: request.kind,
      recipeTitle: request.recipeTitle,
      minutes: request.minutes,
      cookName: request.cookName,
      simulate: request.simulate ?? DinnerSimulation.delivered,
    );
