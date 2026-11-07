# MVP readiness — November 7, 2026

The MVP is a cook-led companion: live camera and two-way voice, Gemini-generated Flutter panels, grounded research, real timers, opt-in visible-change watches, and an explicitly reviewed dinner message. Vision never establishes internal temperature or food safety. Jenna owns SS-005 and her research-panel files; validation work does not implement her assignment.

## Verified in this session

- 81 Flutter tests pass on Flutter 3.47.9 / Dart 3.13.7. The clarification persistence test now supplies a valid question tool payload, so it reaches the intended failure path.
- Flutter analysis passes with no issues; three browser-media tests pass.
- Mobile PR #35 has 88 passing local Flutter tests, including seven responsive-layout cases, plus analysis and web build. Its GitHub CI passed and PR #35 merged; physical Android Chrome checks remain outstanding, so this is not deployed-phone evidence.
- The simulated rehearsal web build and Wasm compatibility dry run pass. These do not establish camera, microphone, Gemini or notification behavior.
- Backend dependencies are locked; clean offline npm installation succeeds. 21 backend tests pass on Node 22.23.4, syntax checks pass, and both function exports load using installed Firebase SDKs. npm audit reports zero vulnerabilities at validation time. Live model/API version are validated deployment parameters.
- Production reCAPTCHA Enterprise App Check is registered for the two Hosting domains, and the dedicated Gemini server key is in Secret Manager. Local debug tokens remain out of published builds.
- All 10 Firestore emulator security scenarios pass. Actual repository rules compile unchanged; tests verify owner isolation, checkpoint privacy/size, session validation and server-only ledger denial. See `test/rules/README.md`. This is emulator verification, not production deployment.
- Firebase CLI can list the active project and its default Hosting site, `devfest-flutter-a59e8`.
- Initial Hosting root returned HTTP 404. GitHub production deployment run 42419680055, attempt 2, failed because Firebase CLI required missing VONAGE_API_KEY despite selecting liveToken only. The separate deployment-path fix in PR #37 passed CI and merged, and the deployment gate was re-enabled for rollout; a successful production release and deployed Live token endpoint are not yet established. Redundant run 42420643671 was canceled until the fix is ready.
- Real Auth/App Check and an AI Logic request smoke succeeded (5 prompt / 17 total tokens). Response content was not asserted. This does not verify a Live session or production-browser attestation.
- GitHub OIDC is scoped to this repository/main/approved events, with a main-only production environment. Both pre-existing default runtime accounts have Editor; the approved actAs grants mean the effective deployment path is not globally least privilege. See `docs/AUTODEPLOY.md`.
- Interactive browser verification was blocked by an unavailable browser access host and, in a separate attempt, denied native Chrome permission. Neither attempt establishes browser acceptance.

## Live acceptance sequence

1. Confirm anonymous Authentication, Firestore and production reCAPTCHA Enterprise App Check are configured for the Hosting origin. Configure backend Gemini credentials and the selected model/API version; keep credentials out of browser assets.
2. Build `lib/main_learner.dart` with production configuration, without `FAKE_BACKEND=true` or an App Check debug token. Deploy reviewed rules, functions and Hosting after configuration is ready.
3. From HTTPS on desktop and phone, sign in and create a cooking session. Connect camera/microphone, ask a cooking question and hear a response. Verify interruption, denied permissions, reconnect, stop and hidden-tab cleanup.
4. Generate a cooking panel, answer a targeted clarification and confirm persistence after reload. Exercise cited research without replacing Jenna’s assigned UI work.
5. Run a real countdown and an explicitly enabled visible-change watch. Confirm stopping disables capture and watches. No appearance-based food-safety claims.
6. Preview the recipient and exact dinner-ready message. Only the cook’s reviewed send can submit it. Use an approved recipient and configured Vonage sender; provider acceptance is not confirmed delivery. No messages were sent during validation.

## Ownership and integration

The prepared implementation stack, MVP validation #24, obsolete-handoff cleanup #25, infrastructure record #28, delivery configuration #31 and assignee preservation #33 are merged. SS-018/#32 is closed and Done after CI. Merges and local tests do not establish live end-to-end acceptance. Chrome on Android and desktop web are the MVP targets; APK work is deferred. Jenna retains SS-005 and its research-panel implementation.
