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
- Initial Hosting root returned HTTP 404. GitHub production deployment run 42419680055, attempt 2, failed because Firebase CLI required missing VONAGE_API_KEY despite selecting liveToken only. The separate deployment-path fix in PR #37 passed CI and merged, and the deployment gate was re-enabled for rollout; that historical attempt did not establish a release; the successful later rollout is recorded below. Redundant run 42420643671 was canceled until the fix is ready.
- Real Auth/App Check and an AI Logic request smoke succeeded (5 prompt / 17 total tokens). Response content was not asserted. This does not verify a Live session or production-browser attestation.
- GitHub OIDC is scoped to this repository/main/approved events, with a main-only production environment. Both pre-existing default runtime accounts have Editor; the approved actAs grants mean the effective deployment path is not globally least privilege. See `docs/AUTODEPLOY.md`.
- Interactive browser verification was blocked by an unavailable browser access host and, in a separate attempt, denied native Chrome permission. Neither attempt establishes browser acceptance.

### Latest verification

Native Chrome subsequently worked: the local simulated mobile build fit a 360×740 DevTools viewport; a timer visibly counted down and the dinner-review dialog opened cleanly. No message was sent. Physical Android camera/audio remain unverified; hosted research was subsequently verified below.

Live-only rollout 42421304400 passed function secret discovery but stopped on a disabled Cloud Billing API. That API was enabled using setup credentials. Rollout 42421669752 subsequently failed after uploads at Auth provisionFirebaseApp (403); uploads do not establish a release. PR #48 passed CI and merged to omit routine Auth deployment because one-time provider setup is already complete. The deployment gate is enabled. 2026-11-07: Run 42422724152 attempt 2 succeeded with all jobs on main d350601. Hosting returned HTTP 200 and native Chrome loaded the hosted real-mode app. A benign chickpea research question rendered an actual answer with multiple source links using gemini-3.8-flash, verifying production browser Auth/App Check and AI Logic without a CI debug token. Camera/microphone permissions were not touched.

A subsequent real Firebase AI Logic request using `gemini-3.8-flash` with Google Search returned nonempty answer text, 3 source chunks and 5 supported segments (32 prompt + 172 candidate = 204 total tokens). Temporary anonymous Auth and debug App Check registrations were removed. This verifies the authenticated provider response and grounding metadata, not by itself the complete research UI or production reCAPTCHA path; the later hosted Chrome check above verifies that production path.

## Live acceptance sequence

1. Confirm anonymous Authentication, Firestore and production reCAPTCHA Enterprise App Check are configured for the Hosting origin. Configure backend Gemini credentials and the selected model/API version; keep credentials out of browser assets.
2. Build `lib/main_learner.dart` with production configuration, without `FAKE_BACKEND=true` or an App Check debug token. Deploy reviewed rules, functions and Hosting after configuration is ready.
3. From HTTPS on desktop and phone, sign in and create a cooking session. Connect camera/microphone, ask a cooking question and hear a response. Verify interruption, denied permissions, reconnect, stop and hidden-tab cleanup.
4. Generate a cooking panel, answer a targeted clarification and confirm persistence after reload. Exercise cited research without replacing Jenna’s assigned UI work.
5. Run a real countdown and an explicitly enabled visible-change watch. Confirm stopping disables capture and watches. No appearance-based food-safety claims.
6. Preview the recipient and exact dinner-ready message. Only the cook’s reviewed send can submit it. Use an approved recipient and configured Vonage sender; provider acceptance is not confirmed delivery. No messages were sent during validation.

## Ownership and integration

The prepared implementation stack, MVP validation #24, obsolete-handoff cleanup #25, infrastructure record #28, delivery configuration #31 and assignee preservation #33 are merged. SS-018/#32 is closed and Done after CI. Merges and local tests do not establish live end-to-end acceptance. Chrome on Android and desktop web are the MVP targets; APK work is deferred. Jenna retains SS-005 and its research-panel implementation.

## Completed automated regression gaps

2026-11-07: PRs #47 and #49 passed CI and merged. All 7 transport and 6 browser-media tests pass; 25 affected cooking/coordinator/mobile widget tests pass, including five reviewed-send regressions. A synchronous confirmation guard fixes the demonstrated duplicate-callback race. No real messages were sent; fake API/widget checks are not physical-device or live-service acceptance. Issue #46/SS-025 is closed and Project Done. Jenna’s physical acceptance and real provider/device checks remain separate.

## Deployed Live limitation and artifact retention

2026-11-07: liveToken is ACTIVE on Node 22 at https://livetoken-kbzslsx4pq-uc.a.run.app. A real protected Auth/App Check request reached upstream but returned 502 because SDK liveConnectConstraints was sent to REST. PR #51 corrects bidiGenerateContentSetup plus fieldMask; one corrected direct real token mint succeeded (token withheld), without audio. Deployed fix and WebSocket/audio verification remain required.

2026-11-07: The initial rollout attempt failed only at artifact cleanup after function creation. Terry explicitly approved one-day artifact retention; firebase functions:artifacts:setpolicy succeeded and read-back confirmed DELETE, tagState ANY, olderThan 86400s on gcf-artifacts. This permits automatic deletion of matching images and limits artifact-based rollback; it does not delete source history or prove immediate cleanup.

## Grounded research provider completion

2026-11-07: Hosted real research rendered an answer, eight source links, Google logo and provider search-suggestion chips. Reviewed provider tests preserve the identical query and grounding metadata, validate HTTPS/deduplicate citations and handle uncited answers; provider suggestions HTML is isolated. Reviewed coordinator passes question, step, confirmed facts and ingredients and only assigns researchResult, without automatic ingredient mutation. SS-005 Jenna panel remains independently open. The finite provider scope SS-004 is Done; this does not take over Jenna’s research UI. Token fix PR #51 passed CI and merged, with rollout 42423984364 active on main 4bb26bb; SS-008 still requires real deployed WebSocket/audio verification.
