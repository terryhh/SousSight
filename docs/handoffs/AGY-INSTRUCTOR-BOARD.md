# AGY task: SousSight instructor board

Owner: Terry's sister, using Google Antigravity (AGY). Prepared November 7, 2026.

## Build this

Build the responsive instructor board for SousSight, a Flutter web cooking coach for DevFest Orlando. The main app uses **live camera vision, spoken conversation, and Gemini-generated Flutter interfaces**. Those are required product features; do not reduce them to still photos, chat, or optional stretch goals. Your board gives a human instructor the context needed when the cook asks for help.

Terry/Codex owns the learner app, Gemini clients, Live media, GenUI, and notification backend. You own the instructor board. Work independently against the existing service interfaces and fake repositories; you do not need API keys to finish your part.

## Start from this branch

Repository: `git@github.com:terryhh/SousSight.git` (private; your GitHub account needs access).

```sh
git clone git@github.com:terryhh/SousSight.git
cd SousSight
git fetch origin
git switch -c agy/instructor-board origin/stack/02-data
flutter pub get
flutter run -d chrome -t lib/main_board.dart --dart-define=FAKE_BACKEND=true
```

Base commit: `30b35ad622f5c40521cd22fb7fdf65f998555fb3`. Do not use the abandoned local `stack/04-board` worktree. If you already have a checkout, create a separate worktree for `agy/instructor-board` instead of switching someone else's working directory.

Read `lib/core/services.dart`, `lib/core/models.dart`, `lib/core/request_machine.dart`, `lib/core/routing.dart`, `lib/core/fakes.dart`, `lib/app/services_scope.dart`, and `lib/data/firebase_services.dart`. `docs/SPEC.md` has the board details, but any older statement cutting Live video, audio, watch mode, GenUI, or timers is superseded by the user's latest direction.

## Your files

- `lib/board/**`
- `lib/main_board.dart`
- `test/board/**`
- Optional `docs/BOARD.md` with run/demo instructions.

Keep shared models, services, rules, dependencies, learner UI, `lib/ai`, `lib/live`, `lib/genui`, web assets, and backend functions unchanged. If you need a contract addition, document the exact proposal in your PR; do not block the board on it.

## Required behavior

1. Provide an instructor sign-in screen. In fake mode, make switching among the four demo instructors easy and visibly label it as demo mode. Use `demoInstructorEmails` and the roster IDs: `ana`, `marcus`, `priya`, `coordinator`. The Firebase auth UID is not necessarily a roster ID; map the selected demo email explicitly. Never store passwords.
2. Show four live lanes: **Needs owner**, **With instructor** (Suggested/Accepted badges), **Answered**, and **Resolved**. Keep Submitted requests visible as awaiting triage. Show Cancelled separately or in a filter. Use a wide board on desktop and stacked lanes on phones.
3. Each request shows the learner's question, recipe step, category, age, Gemini summary, uncertainty, up to two supplied thumbnails, routing reason, current owner, next step, history, and notification status. Distinguish failed, pending, skipped, and sent messages; never pretend a message was delivered.
4. Implement availability, Accept, Decline, and Answer. Run `RequestMachine` operations inside `RequestRepository.transact`. A coordinator can assign an eligible instructor. Show permission/transition errors inline, and keep typed replies when a write fails. Only the learner can mark a request resolved.
5. For answered substitution requests, let the owner choose **Make reusable**. Use `RequestMachine.approveAsReviewed` and `RecipeRepository.addReviewedSubstitution`. Avoid duplicate approvals on repeated clicks and show whose answer was approved.
6. Add board-local fake fixtures: a normal substitution, an accepted technique question, and a safety question with Priya offline. The no-owner case must be obvious. An instructor coming online should allow rerouting through the existing deterministic routing/state machine.

Use `AppServices` dependency injection. The board does not need Gemini. For real wiring, `firebaseServices` accepts assessment/triage clients; passing the existing fake AI clients is appropriate because the board never calls them. Show backend initialization errors with a retry action.

## Acceptance checks

- `flutter analyze` passes.
- `flutter test test/board` passes; cover accepting, answering, permission failures, no-owner visibility, and duplicate approval behavior with fake services.
- `flutter build web -t lib/main_board.dart --dart-define=FAKE_BACKEND=true` passes.
- In a browser, demonstrate: needs-owner card → instructor available → routed → accepted → answered. Confirm the learner still owns resolution. Check a narrow viewport for overflow.
- No hardcoded credentials, outgoing test messages, or deployment required.

## Deliver

Commit your work and push `agy/instructor-board`. Open a draft PR targeting `stack/02-data` for independent review. State that Codex will retarget/rebase it onto the updated Live/GenUI stack before integration. Include screenshots, checks run, and any contract gaps. Do not merge or rewrite the other stacked branches.

Copy this entire document into AGY and say: **“Implement this task in the specified branch. Preserve the main app's Live video, audio, and GenUI direction. Finish the board, run the checks, and open the draft PR.”**
