# Remaining MVP work and ownership — November 7, 2026

The target remains a live cooking companion on Android Chrome and desktop: camera vision, two-way voice, Gemini-generated Flutter GenUI/A2UI panels, grounded research, cook clarification, real timers, opt-in visible-change watches, and a reviewed Vonage dinner message. APK work stays deferred. Assignment means available for pickup, not work started or verified.

## Jenna pickup order

1. **SS-005 research panel** is the first product implementation priority. Use the existing fake-client contract to work independently; Terry supplies grounded provider/runtime integration in SS-004/SS-003.
2. **SS-021 Vonage setup** can proceed independently once account access is available. Share secret locations only. Coordinate readiness with SS-007; paid sending still requires the recorded explicit authorization and cook review.
3. **SS-022 real photo pack** is a bounded parallel deliverable. Jenna owns original/licensed real food photos and visible-cue fixture documentation; Terry owns SS-013 recipe wiring and real model evaluation. No synthetic reference truth or vision-based internal-temperature claim.
4. **SS-024 demo preparation** can be drafted now from the actual cooking flow. Terry owns final recording, official requirement/deadline verification and submission in SS-012. Label planned, rehearsed and live segments honestly.
5. **SS-023 physical cook acceptance** can start with checklist preparation and clearly labeled local rehearsal. Live signoff depends on the deployed HTTPS app and integrated capabilities listed on the card. Record device/browser/build, evidence, and pass/fail/blocked/not-run; Terry fixes runtime defects. The mobile implementation prerequisite was fulfilled by merged PR #35. This supplies physical evidence to SS-010/SS-019; it does not wait for SS-019 to close.

Jenna owns `lib/research/**`, `test/research/**`, `lib/main_research_demo.dart`, `assets/reference-cooking/**`, `docs/validation/reference-images.md`, `docs/validation/cook-acceptance.md`, `docs/validation/cook-acceptance/**`, and `docs/demo/**`. Other contributors must not implement these assignments. New cards remain Backlog until Jenna begins. Coordinate shared interfaces and PR bases on the cards; no automatic takeover when a dependency is blocked.

## Complete board map

The 29 linked cards contain acceptance criteria and dated evidence; `docs/backlog.json` is the publisher manifest. The dependency column records completion gates, not a prohibition on preparing independent fixtures or checklists. Terry's existing underway integration assignments remain his. Done means only the finite scope described on that card, never inferred live MVP acceptance.

| Card | Owner | State | Completion dependencies |
| --- | --- | --- | --- |
| [SS-001: Configure Firebase, App Check and Gemini for the real demo](https://github.com/terryhh/SousSight/issues/4) | @terryhh | Done | None |
| [SS-002: Verify live camera vision and two-way voice with Gemini](https://github.com/terryhh/SousSight/issues/6) | @terryhh | InProgress | SS-001, SS-008 |
| [SS-003: Integrate Gemini-generated cooking panels and cook clarification](https://github.com/terryhh/SousSight/issues/13) | @terryhh | InProgress | SS-002 |
| [SS-004: Implement source-backed cooking research and substitutions](https://github.com/terryhh/SousSight/issues/14) | @terryhh | Done | SS-001 |
| [SS-005: AGY: build the grounded answer and substitution panel](https://github.com/terryhh/SousSight/issues/15) | @jennajh | Done | None |
| [SS-006: Finish persistent timers and opt-in visible-change alarms](https://github.com/terryhh/SousSight/issues/16) | @terryhh | InProgress | SS-002, SS-003 |
| [SS-007: Connect reviewed dinner-ready messages through Vonage](https://github.com/terryhh/SousSight/issues/17) | @terryhh | InProgress | SS-001, SS-003, SS-021 |
| [SS-008: Deploy and smoke-test protected ephemeral Live tokens](https://github.com/terryhh/SousSight/issues/5) | @terryhh | Done | SS-001 |
| [SS-009: Compile and verify private cooking Firestore rules](https://github.com/terryhh/SousSight/issues/18) | @terryhh | Done | None |
| [SS-010: Run phone, desktop and failure-path integration checks](https://github.com/terryhh/SousSight/issues/20) | @terryhh | InProgress | SS-002, SS-003, SS-004, SS-005, SS-006, SS-007, SS-008, SS-009, SS-013, SS-023 |
| [SS-011: Publish the stacked PRs and populate the SousSight project](https://github.com/terryhh/SousSight/issues/21) | @terryhh | Done | None |
| [SS-012: Record the DevFest demo and explain Central Florida impact](https://github.com/terryhh/SousSight/issues/22) | @terryhh | InProgress | SS-010, SS-011, SS-024 |
| [SS-013: Replace checkpoint placeholders with real visual examples](https://github.com/terryhh/SousSight/issues/19) | @terryhh | InProgress | SS-001, SS-022 |
| [SS-014: Maintain infrastructure cost and credit ledger](https://github.com/terryhh/SousSight/issues/26) | @terryhh | InProgress | None |
| [SS-015: Review and execute infrastructure teardown after the demo](https://github.com/terryhh/SousSight/issues/27) | @terryhh | Backlog | SS-014 |
| [SS-016: Deploy merged main through GitHub Actions](https://github.com/terryhh/SousSight/issues/29) | @terryhh | Done | SS-020 |
| [SS-017: Configure twenty dollar infrastructure spending controls](https://github.com/terryhh/SousSight/issues/30) | @terryhh | Done | None |
| [SS-018: Preserve explicit GitHub card assignees in backlog publishing](https://github.com/terryhh/SousSight/issues/32) | @terryhh | Done | None |
| [SS-019: Make the cooking workspace responsive in mobile Chrome](https://github.com/terryhh/SousSight/issues/34) | @terryhh | InProgress | None |
| [SS-020: Isolate Live deployment from unconfigured Vonage secrets](https://github.com/terryhh/SousSight/issues/36) | @terryhh | Done | None |
| [SS-021: Set up Vonage account and delivery configuration](https://github.com/terryhh/SousSight/issues/39) | @jennajh | InProgress | None |
| [SS-022: Prepare real cooking reference photos and evaluation fixtures](https://github.com/terryhh/SousSight/issues/40) | @jennajh | InProgress | None |
| [SS-023: Run physical cook acceptance and report reproducible failures](https://github.com/terryhh/SousSight/issues/41) | @jennajh | InProgress | SS-016, SS-002, SS-003, SS-004, SS-005, SS-006 |
| [SS-024: Prepare a repeatable cooking demo story and recording checklist](https://github.com/terryhh/SousSight/issues/42) | @jennajh | Backlog | None |
| [SS-025: Critical reconnect, media lifecycle and reviewed-send regressions](https://github.com/terryhh/SousSight/issues/46) | @terryhh | Done | None |
| [SS-026: Integrate Jenna research panel with the live learner workspace](https://github.com/terryhh/SousSight/issues/58) | @terryhh | Done | SS-005, SS-004 |
| [SS-027: Add optional Google account sign-in and saved cooking sessions](https://github.com/terryhh/SousSight/issues/59) | @terryhh | Backlog | SS-001, SS-009 |
| [SS-028: Keep input and stop controls stable during generated workspace updates](https://github.com/terryhh/SousSight/issues/63) | @terryhh | InProgress | None |
| [SS-029: Guard repository history and browser builds against secrets](https://github.com/terryhh/SousSight/issues/65) | @terryhh | InProgress | None |

## Integration and release gates

Terry completes production deployment and protected Live tokens (SS-016/SS-008), then verifies the actual camera/voice loop (SS-002). Generated panels and confirmed facts (SS-003), grounded research provider plus Jenna's panel (SS-004/SS-005), timers/watches (SS-006), and reviewed notification integration plus Jenna's setup (SS-007/SS-021) all remain required. SS-013 consumes Jenna's SS-022 fixture pack. SS-010 gathers these end-to-end outcomes and Jenna's SS-023 physical acceptance evidence before SS-012 final recording/submission; SS-024 supplies its script.

Run 42422724152 attempt 2 successfully released main d350601; production Chrome research returned a sourced answer. SS-001 setup and SS-016 CD are Done. SS-008 is now Done after run 42423984364 and a real protected hosted-token request returned Gemini Live audio. Terry confirmed audible desktop coach playback in the earlier brief test. SS-002 still requires distinct microphone recognition and hosted verification of the merged transcript fix; SS-003 now has real hosted model-generated step, timer and comparison panels verified; explicit cook question/answer and deployed stale-step rejection remain open. Earlier browser attempts were blocked by native Chrome permission denial and an unavailable access host. Native Chrome subsequently worked: the simulated mobile-PR-35 build at localhost:7358 fit a 360×740 DevTools viewport, a five-minute timer visibly counted down to 4:59 then 4:48, and the dinner review dialog fit. No message was sent and no physical media was tested. This rehearsal evidence does not replace Jenna’s real phone and deployed-service report. Unavailable services should be recorded as blocked with a responsible card, never silently replaced by simulated success.

SS-014 continues cost/credit reconciliation under the accepted $20 gross monthly soft budget; eligible credit balances remain unverified. Reuse short focused test sessions and record usage. SS-015 is a future teardown request, not authorization to delete resources now. No extra paid service, notification or fabricated deadline is introduced by assigning this plan.

SS-025 automated regression coverage is complete after PRs #47/#49 passed CI and merged, including the duplicate dinner-confirmation callback fix. These fake transport/media and widget tests do not close Jenna’s SS-023 physical acceptance or the live integration cards.

## Current board reconciliation

Read-back on November 7: **28 cards: 11 Done, 13 In progress, 0 In review, 4 Backlog**, all with actual GitHub assignees. This is workflow inventory, not a completion percentage. Jenna’s independent SS-005 panel/demo handoff is Done after PR #45; PR #57 brings her unchanged work to main. Her SS-022 and SS-023 cards are already In progress and stay hers. SS-026 is the started Terry-owned shared learner adapter, preserving one research request and the coordinator evidence-to-Live flow. SS-027 optional Google sign-in is Backlog only, with guest/account linking and session ownership safeguards; no provider configuration started.

PRs #50/#53/#54/#55 are merged. PR #56 stale-workspace guard stays under SS-003, which remains open for real hosted generated-panel acceptance. PR #57 handoff is open; no duplicate Jenna implementation is assigned. Run 42425656543 succeeded for the dynamic workspace; cache rollout 42425937906 was pending at this read-back.

Remaining practical MVP gates are distinct microphone recognition and hosted transcript behavior; real generated panels and confirmed facts; Jenna panel/shared-adapter integration; real timer/watch lifecycle; Vonage setup and an explicitly authorized reviewed send; physical Android acceptance, real reference-photo evaluation and final demonstration. Optional Google login is outside the immediate MVP verification priority. User-confirmed audible coach playback is already verified and does not establish microphone recognition.

The latest hosted check rendered real Gemini panels and a visibly advancing timer without manual tool injection. Input displacement prevented verified question submission; SS-028 is underway to stabilize shared input/stop controls, including mobile keyboard focus. SS-003 remains open for explicit clarification and deployed stale-step guard checks; distinct microphone recognition is still unverified.

Latest read-back supersedes the earlier snapshot: **29 cards — 12 Done, 14 In progress, 0 In review, 3 Backlog**, all assigned. SS-026 finite adapter is Done after merged integration and the hosted nine-source panel. Explicit fact confirmation remains unverified under SS-003. Jenna’s Vonage setup is In progress; her photo/physical-acceptance PRs #67/#68 await review. SS-029 secret protection has green PR #66 CI but remains In progress until completion.
