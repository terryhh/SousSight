# MVP readiness — November 7, 2026

The MVP is a cook-led companion: live camera and two-way voice, Gemini-generated Flutter panels, grounded research, real timers, opt-in visible-change watches, and an explicitly reviewed dinner message. Vision never establishes internal temperature or food safety. Jenna owns SS-005 and her research-panel files; validation work does not implement her assignment.

## Verified in this session

- 81 Flutter tests pass on Flutter 3.47.9 / Dart 3.13.7. The clarification persistence test now supplies a valid question tool payload, so it reaches the intended failure path.
- Flutter analysis passes with no issues; three browser-media tests pass.
- The simulated rehearsal web build and Wasm compatibility dry run pass. These do not establish camera, microphone, Gemini or notification behavior.
- Backend dependencies are locked; clean offline npm installation succeeds. 21 backend tests pass on Node 22.23.4, syntax checks pass, and both function exports load using installed Firebase SDKs. npm audit reports zero vulnerabilities at validation time. Live model/API version are validated deployment parameters.
- Local build configuration contains an App Check debug token but no production reCAPTCHA site key. No token value was copied or published. A production build remains blocked on configuration.
- All 10 Firestore emulator security scenarios pass. Actual repository rules compile unchanged; tests verify owner isolation, checkpoint privacy/size, session validation and server-only ledger denial. See `test/rules/README.md`. This is emulator verification, not production deployment.
- Firebase CLI can list the active project and its default Hosting site, `devfest-flutter-a59e8`.
- Hosting root returned HTTP 404. Listing deployed functions failed without a useful diagnostic; deployment state is not established.
- Interactive browser verification was unavailable because the browser access host was unavailable.

## Live acceptance sequence

1. Confirm anonymous Authentication, Firestore and production reCAPTCHA Enterprise App Check are configured for the Hosting origin. Configure backend Gemini credentials and the selected model/API version; keep credentials out of browser assets.
2. Build `lib/main_learner.dart` with production configuration, without `FAKE_BACKEND=true` or an App Check debug token. Deploy reviewed rules, functions and Hosting after configuration is ready.
3. From HTTPS on desktop and phone, sign in and create a cooking session. Connect camera/microphone, ask a cooking question and hear a response. Verify interruption, denied permissions, reconnect, stop and hidden-tab cleanup.
4. Generate a cooking panel, answer a targeted clarification and confirm persistence after reload. Exercise cited research without replacing Jenna’s assigned UI work.
5. Run a real countdown and an explicitly enabled visible-change watch. Confirm stopping disables capture and watches. No appearance-based food-safety claims.
6. Preview the recipient and exact dinner-ready message. Only the cook’s reviewed send can submit it. Use an approved recipient and configured Vonage sender; provider acceptance is not confirmed delivery. No messages were sent during validation.

## Ownership and integration

MVP validation PR #24 is stacked above #12. Current implementation stack remains #8 → #9 → #10 → #11 → #12; #7 is the corrected research assignment. #7 and #8 now target main because their parent data layer merged. Keep service implementation drafts until the live checks are recorded. The old instructor-board handoff merged as #3, but the active cook-led stack removes it.
