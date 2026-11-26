# Agent instructions: SousSight #BuildHybridAI 2026

Give this file to your coding agent (Claude Code, Codex, Antigravity or another) at the start of a
session. It collects every instruction Terry has given for this entry so far. Where it conflicts
with older notes, this file and `AGENTS.md` win.

## 1. Mission

SousSight is being entered in Google's **#BuildHybridAI 2026** hackathon
(https://firebasehybridaihackathon.devpost.com/rules). The goal is the **Grand Prize**, not just a
valid entry.

- **Deadline: Mon Nov 30, 2026, 2:00 pm PT (5:00 pm EST).** Commits pushed after that are not evaluated.
- The judged build must stay reachable, free, through **Dec 16**.
- Judging weights four criteria equally: how well the app uses **Firebase AI Logic hybrid
  inference** (on-device when a local model is available, cloud fallback when it isn't), design,
  potential impact, and quality of the idea.
- Platforms: **Web (Chrome), Android and iOS**, all three. Multi-platform gets "strong consideration".
- Product idea: **"What happens at the counter stays at the counter."** Food-pantry cooks get a
  sous-chef that runs on the device when it can and calls the cloud only when it earns it.

Read these before doing anything, in this order:
1. `AGENTS.md`: the working agreement, including Jenna's file ownership and the hackathon section.
2. `docs/buildhybridai/PLAN.md`: what and why.
3. `docs/buildhybridai/DESIGN.md`: how. It covers the bridge contract, the routing/consent/ledger
   rules, per-card designs, gates, branch and file ownership, and the checks.
4. `docs/buildhybridai/AUDIT.md`: prior work, third-party media, attribution and branding.

## 2. Non-negotiables

- **Every model call in the judged build goes through Firebase AI Logic.** No direct Gemini endpoints.
- **Strict local-only always wins.** If the cook keeps a feature on the device, no retry, fallback,
  quota rule or Remote Config value can send its data to the cloud.
- **Consent is for one exact payload in one session.** Approving one photo doesn't approve the next.
- **Claims come from evidence.** "On this device" and "sent" wording must come from the actual
  inference legs (the SDK-reported source), never from settings or intent.
- **Vision never certifies** doneness, internal temperature, freshness or allergen safety. The cook decides.
- **The cook stays in the loop.** Ask the cook targeted questions; don't guess. No instructor
  board, help queue or expert routing.
- **Free tier only.** If anything would bill, stop and ask Terry. Never send a real SMS; judged
  builds use the clearly labelled simulated dinner message.
- **Credentials never go in Git or browser bundles.** Firebase client config is public; debug tokens are not.
- **Label simulated behaviour clearly.** Never write "tested" when only a fake or static check ran.
  In every PR, mark each claim as fakes, emulator, live service or physical device.
- **No third-party logos or sponsor framing** in the app, docs or video. Nothing that implies
  endorsement, and no DevFest competition framing.

## 3. How work flows

- **Board:** GitHub project "SousSight" (terryhh). Hackathon cards carry the label `buildhybridai`
  and the milestone **#BuildHybridAI 2026**. Older work is under `devfest-2026` / **DevFest Florida 2026**.
- **Picking a card:** take one in **Ready** whose dependencies are Done. **Respect the GitHub
  assignee**: take a card only if it's assigned to you, or Terry explicitly reassigns it. Move it to
  **In progress** and comment that you have it.
- **Branches:** start from `origin/...`, never a local `main` (it can be stale). Run `git fetch origin` first.
  - Code cards: branch from **`origin/hybrid/integration`** (the trunk) and open the PR against `hybrid/integration`.
  - Docs-only cards: branch from `origin/main` and open the PR against `main`.
  - Work in a worktree: `git worktree add -b <branch> .worktrees/<slug> origin/<base>`.
- **One writer per file.** DESIGN.md §9 lists who owns what. Shared files are edited only by the
  integration owner: `cooking_app.dart`, `cooking_coordinator.dart`, `live_controller.dart`,
  `live_types.dart`, `pantry_flow.dart`, `firebase_services.dart`, `firestore_repositories.dart`,
  `firebase_options.dart`, `how_it_works.dart`, `pubspec.yaml/.lock`, `android/app/`,
  `firebase.json`, `AGENTS.md`, `DESIGN.md`. If you need a change there, describe the exact wiring
  under "Integration needed" in your PR.
- **Commits:** sign off every commit (`git commit -s`, DCO). Use your own tool's attribution lines.
- **PRs:** add the label `buildhybridai`, the milestone `#BuildHybridAI 2026` and `Refs #<card>`.
  Body sections: Why · What changed · Integration needed · Checks (commands and results) ·
  Evidence level. Never force-push and never rebase a published branch; merge the trunk in instead.
- **Review:** a Codex session reviews every PR adversarially and scores it out of 100. Approval
  means a score **above 85** at the PR's current head. The reviews appear as "terryhh reviewed"
  with inline comments. Fix every finding with a regression test, push, and reply on the PR
  summarizing each fix. Terry's orchestrating session merges approved PRs; don't merge your own.
- **Board hygiene:** keep your card current: In progress, then **In review** when the PR is up,
  then Done when merged.

## 4. Before you open a PR: Codex's recurring rejection reasons

Every rejection so far was one of these. Check each one and add a test.
1. **Stale async:** after every `await`, re-check that you're still current
   (epoch/token/session/step). Stop, step change, session change, backgrounding and Live takeover
   must also cancel work that is still starting.
2. **Re-check privacy at send time:** read `localOnly(...)`, `CloudRoutes` and connectivity
   immediately before any cloud send or handoff. A declined, cancelled or blocked operation never
   authorizes a later send.
3. **Use the right feature key:** a sub-step, such as a cloud check of a watch, must also honour
   its parent feature's local-only setting.
4. **Malformed model output abstains:** validate required fields, types and enums before accepting
   any positive result.
5. **Claims come from legs**, not from settings.
6. **Reset state:** clear stored verdicts, errors and notices when their step, session or the latest call changes.
7. **Bind to the session you started with:** snapshot identity at the start of a multi-step flow
   (including camera capture) and stop if it changes.
8. **Never put secret-looking strings in tests.** Synthetic tokens trip the repository's
   Gitleaks scan, which checks all history. Build fixtures at runtime or allowlist them exactly.

## 5. Checks to run

```sh
export PATH="$HOME/dev/flutter/bin:$PATH"     # Flutter 3.47.9 (CI pin)
flutter pub get
flutter analyze && flutter test
(cd packages/ai_logic_hybrid && flutter test)
node --test test/hybrid/ test/live/browser_media_test.cjs
npm --prefix functions run check && npm --prefix functions test   # if functions changed
./tool/build_web.sh --dart-define=FAKE_BACKEND=true
```

Never call a real model or cloud service from tests; use `FakeHybridInference` and `FakeHybridDispatcher`.
If `git` or `python3` says the Xcode license isn't accepted, prefix commands with
`export DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

## 6. Jenna's areas

Per `AGENTS.md`, Jenna owns:
- **SS-005 research panel:** `lib/research/**`, `test/research/**`, `lib/main_research_demo.dart`.
- **SS-022 reference photo fixtures:** `assets/reference-cooking/**`, `docs/validation/reference-images.md`.
- **SS-023 cook acceptance reports:** `docs/validation/cook-acceptance.md`, `docs/validation/cook-acceptance/**`.
- **SS-024 demo preparation:** `docs/demo/**`.

Other agents don't edit those files. Hackathon work that fits these areas, to confirm with Terry before claiming:
- **Grounded-research Search suggestions on Android/iOS.** Native builds currently show a "view on
  web" notice instead of Google's Search-suggestion content, which the grounding terms require to
  be displayed. The fix lives in `lib/research/**`.
- **Evidence (SS-075, #162):** score the local watch against the eight labelled photos in
  `assets/reference-cooking/fixtures.json`, using the predeclared three-part score in DESIGN §6
  SS-075 (verdict, observation, action). Also film one consented cook-through in a kitchen not
  used for the fixtures: an obscured bowl, the cook's correction, frames uploaded counted, and
  completion after the connection drops.
- **Demo and video prep (supports SS-081, #168):** a ≤3-minute hero-journey shot list showing
  on-device, cloud fallback, the private watch, offline Coach Lite and the ledger, on each
  platform that passed its gate.

## 7. Facts worth knowing (verified)

- **Flutter has no hybrid API.** `firebase_ai` lacks one, so the repo has its own plugin,
  `packages/ai_logic_hybrid`, over the official SDKs:
  - Web: Firebase JS `firebase/ai` with `InferenceMode` (Chrome's built-in Gemini Nano).
  - Android: `firebase-ai` + `firebase-ai-ondevice` (Gemini Nano through AICore).
  - iOS: Apple's Foundation Models (`SystemLanguageModel`) for local, plus Firebase
    `GeminiLanguageModel` in Apple's `LanguageModelSession` for cloud. Firebase iOS SDK 13.0
    removed `HybridModel`.
- **On web, the Firebase SDK doesn't pass the system instruction or JSON schema to the local
  model.** The bridge sets `initialPrompts` / `responseConstraint` itself.
- **Android:** docs list the Pixel 9 as **Gemini Nano 3** and Nano 4 on Pixel 10/11 and Galaxy S25/S26.
- **iOS:** local needs iOS 26+; Firebase's cloud model in Apple sessions needs iOS 27+.
- **App Check** has been enforced for AI Logic since Nov 2, 2026. Debug tokens are accepted for submissions.
- **The hosted app**, https://devfest-flutter-a59e8.web.app, auto-deploys from `main`.
