# Agent instructions: work the SousSight #BuildHybridAI board

**To the agent reading this (Claude Code, Antigravity or another):** this file is your whole brief.
Follow it as written. You'll work alongside other agents on the same GitHub project board, which is
the only ledger of who is doing what. Work through the loop in §2 until no card is left for you,
then stop and report.

Run this as Jenna (GitHub `jennajh`) unless the person starting you says otherwise. That login is
written as `<me>` below.

---

## 0. The rules that override everything else

1. **The board is the ledger.** The GitHub issue and the project "SousSight" (owner `terryhh`)
   say who owns a card. Your memory, chat history or a local file do not.
2. **Never grab without notifying.** Before you write any code for a card, claim it on the card
   itself: assign `<me>`, move it to **In progress**, and post a claim comment (§2 step 3).
3. **Never take a card someone else has claimed.** A card is claimed if *any* of these is true:
   - it's In progress, In review or Done;
   - it has an assignee other than `<me>`;
   - its latest claim comment is from someone else and hasn't been released.

   If a claimed card looks abandoned, comment asking, tag `@terryhh` (and the claimant if they're a
   person), and wait for Terry's OK before you take it over.
4. **Deadline: Mon Nov 30, 2026, 2:00 pm PT (5:00 pm EST).** Commits pushed after that are not
   judged. Stop starting new cards after Mon 10:00 am PT; finish and hand off.
5. **Don't merge.** Terry's session merges PRs after Codex approves them.

## 1. What we're building (read once)

SousSight is entered in Google's **#BuildHybridAI 2026** hackathon
(https://firebasehybridaihackathon.devpost.com/rules); the goal is the Grand Prize. Judges score
four things equally:
- how well it uses **Firebase AI Logic hybrid inference**: on-device when a local model is
  available, cloud fallback when it isn't;
- design;
- potential impact;
- quality of the idea.

Platforms are Web (Chrome), Android and iOS. The idea: **"What happens at the counter stays at the
counter"**, a sous-chef for food-pantry cooks that runs on the device when it can and calls the
cloud only when it earns it.

Read these in the repo before your first card:
1. `AGENTS.md`: the working agreement, including file ownership.
2. `docs/buildhybridai/PLAN.md`: what and why.
3. `docs/buildhybridai/DESIGN.md`: how. Contract, routing/consent/ledger rules, per-card designs,
   gates, and the branch and file-ownership table in §9.

**Product rules you must never break:**
- Every model call in the judged build goes through **Firebase AI Logic**; no direct Gemini endpoints.
- **Strict local-only always wins** over retries, fallbacks, quotas and Remote Config.
- **Consent is for one exact payload in one session.**
- **"On this device" / "sent" wording comes from the recorded inference legs**, never from settings.
- **Vision never certifies** doneness, temperature, freshness or allergen safety. The cook decides,
  and the app asks the cook targeted questions instead of guessing.
- **Free tier only.** If something would bill, stop and comment on the card for Terry. Never send
  a real SMS.
- **No credentials** in Git or bundles. No third-party logos or sponsor/DevFest framing.
- **Never call a real model or cloud service from tests.** Use `FakeHybridInference` /
  `FakeHybridDispatcher`. Label every claim by evidence (fakes / emulator / live / physical
  device); never write "tested" when only a fake ran.

## 2. The loop

Repeat until step 2 finds nothing:

**1. Sync.**
```sh
gh auth status                         # must show <me>
git -C <repo> fetch origin
```

**2. Find a card you may take.**
```sh
gh issue list -R terryhh/SousSight --label buildhybridai --state open \
  --json number,title,assignees,labels --limit 100
```
- Only consider issues with **no assignee**, or assigned only to `<me>`.
- For each candidate, read the whole card:
  `gh issue view <n> -R terryhh/SousSight --comments`.
- Skip it if it is claimed (rule 0.3), or if its "Depends on" cards aren't Done.
- Check the board status (§3); only take cards in **Backlog** or **Ready**.
- Prefer, in order: cards that touch Jenna's own areas (§4), then P0 over P1 over P2.
- Cards whose owner text says **Terry** are human tasks: skip them.

**3. Claim it, which is the notification.** Do all three, then re-check:
```sh
gh issue edit <n> -R terryhh/SousSight --add-assignee <me>
gh issue comment <n> -R terryhh/SousSight --body "Claimed by <me> via <Claude|Antigravity> agent. Branch: hybrid/<NN>-<slug>. Plan: <one line>."
# move to In progress (§3)
```
Re-read the card a few seconds later. If someone else's claim comment landed before yours, or
another assignee appeared, back off: unassign yourself, comment "Releasing; <who> claimed first",
and return to step 2.

**4. Build it in a worktree.**
- **Base and target:** DESIGN §9's table is authoritative for each card's branch name, the branch
  to create it from, its PR target, and its owned files. Some cards stack on another card's
  branch (for example SS-075 on `hybrid/12-watch`); use exactly what the row says. Where the row
  says "trunk", that's `hybrid/integration`. Docs-only cards come from `origin/main` and target
  `main`. If a stacked parent has already merged, use the trunk instead and say so in the PR.
- **Worktree:** `git worktree add -b hybrid/<NN>-<slug> .worktrees/<slug> origin/<base>`
- **Ownership:** edit only files your card owns. Shared files (`cooking_app.dart`,
  `cooking_coordinator.dart`, `live_controller.dart`, `live_types.dart`, `pantry_flow.dart`,
  `firebase_services.dart`, `firestore_repositories.dart`, `firebase_options.dart`,
  `how_it_works.dart`, `pubspec.yaml/.lock`, `android/app/`, `firebase.json`, `AGENTS.md`,
  `DESIGN.md`) belong to Terry's integration owner. Put the exact wiring you need under
  "Integration needed" in your PR.
- **Before each commit, check Codex's recurring rejection reasons (§5)** and add a test for each that applies.

**5. Check.**
```sh
flutter pub get
flutter analyze && flutter test
(cd packages/ai_logic_hybrid && flutter test)
node --test test/hybrid/ test/live/browser_media_test.cjs
./tool/build_web.sh --dart-define=FAKE_BACKEND=true
```
Toolchain: Flutter **3.47.9** (the CI pin). On a Mac where `git`/`python3` complain about the Xcode
license, either accept it (`sudo xcodebuild -license accept`) or prefix commands with
`export DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

**6. Commit and open the PR.**
- **Commits:** sign off every one (`git commit -s`) and use your tool's own attribution lines.
- **Branch hygiene:** never force-push; never rebase a published branch (merge the trunk in instead).
- **Open the PR:**
  ```sh
  gh pr create -R terryhh/SousSight --base <target> --head <branch> \
    --label buildhybridai --milestone "#BuildHybridAI 2026" --assignee <me>
  ```
- **Body sections:** Why · What changed · Integration needed · Checks (commands and results) ·
  Evidence level · `Refs #<card>`.
- **Board:** move the card to **In review** (§3) and comment the PR link on the card.

**7. Respond to review.** A Codex session reviews every PR adversarially and scores it out of 100.
It posts as a review by `terryhh` with inline comments; **approval means a score above 85 at the
current head**. Poll:
```sh
gh api repos/terryhh/SousSight/pulls/<pr>/reviews --jq '.[-1] | "\(.commit_id[0:7]) \(.body)"'
gh api repos/terryhh/SousSight/pulls/<pr>/comments --jq '.[] | "\(.path):\(.line) \(.body)"'
```
- Fix every finding at the current head with a regression test.
- If your PR's base moved, merge **that base** in first: the trunk for trunk PRs, the parent
  branch for stacked PRs, `origin/main` for docs PRs. Never merge the trunk into a docs PR.
- Push, then reply with `gh pr comment <pr>` summarizing each fix.
- Repeat until it's approved, then go back to step 1. Terry's session merges approved PRs and marks the card Done.

**8. If you get stuck** on missing access, a design gap or a decision only Terry can make: comment
on the card with the exact question, leave it In progress with your claim, and move to another
card. Don't silently abandon a claim. If you stop working a card, release it properly:
unassign yourself, move it back to **Ready** (or **Backlog** if it's blocked; §3), and comment
"Released: <why / where it stands / what blocks it>". A card left In progress still counts as
claimed.

## 3. Moving a card on the board

```sh
PROJECT=PVT_kwHOANaanM4BqpiZ
STATUS_FIELD=PVTSSF_lAHOANaanM4BqpiZzho_uUc
# Option ids: Backlog=f75ad846 Ready=61e4505c "In progress"=47fc9ee4 "In review"=df73e18b Done=98236657
ITEM=$(gh project item-list 1 --owner terryhh --limit 400 --format json \
  --jq '.items[] | select(.content.number==<n>) | .id')
gh project item-edit --id "$ITEM" --project-id $PROJECT --field-id $STATUS_FIELD \
  --single-select-option-id 47fc9ee4      # In progress
```
To add a new PR to the board: `gh project item-add 1 --owner terryhh --url <pr-url>`, then set its
status the same way. Your token needs the `project` scope: `gh auth refresh -s project`.

## 4. Jenna's own areas (owned per AGENTS.md; other agents don't edit these)

- **SS-005 research panel:** `lib/research/**`, `test/research/**`, `lib/main_research_demo.dart`.
- **SS-022 reference photos:** `assets/reference-cooking/**`, `docs/validation/reference-images.md`.
- **SS-023 cook acceptance:** `docs/validation/cook-acceptance.md`, `docs/validation/cook-acceptance/**`.
- **SS-024 demo prep:** `docs/demo/**`.

**Good first cards for this agent** (claim only if still unclaimed):
- **SS-075 Evidence (#162).** Score the local watch against the eight labelled photos in
  `assets/reference-cooking/fixtures.json`, using the predeclared three-part score in DESIGN §6
  SS-075 (verdict, observation, action). Also prepare the filmed cook-through protocol. The
  filming itself is a human task.
- **Native Search suggestions** (in `lib/research/**`). Android/iOS show a "view on web" notice
  instead of Google's Search-suggestion content, which the grounding terms require to be
  displayed. If there's no card yet, ask Terry on #141 to create one, or create it with the
  `buildhybridai` label and claim it.
- **SS-085 App icon (#179).** Original SousSight icon for web, Android and iOS to replace the
  Flutter logo. Get Terry's OK on the artwork before the PR.
- **SS-076 Remote Config (#163)** and **SS-077 device text-to-speech (#164)**, lower priority.
- **Demo/video prep for SS-081 (#168), in `docs/demo/**`.** A ≤3-minute shot list for the hero
  journey (pantry scan → private watch → connection drops → Coach Lite → ledger) on each platform
  that passed its gate.

## 5. Codex's recurring rejection reasons (check before every PR)

1. **Stale async:** after every `await`, re-check that you're still current
   (epoch/token/session/step). Stop, step change, session change, backgrounding and Live takeover
   must also cancel work that is still starting, including camera capture.
2. **Re-check privacy at send time:** read `localOnly(...)`, `CloudRoutes` and connectivity
   immediately before any cloud send or handoff. A declined, cancelled or blocked operation never
   authorizes a later send.
3. **Use the right feature key:** a sub-step must also honour its parent feature's local-only setting.
4. **Malformed model output abstains:** validate required fields, types and enums before accepting
   any positive result.
5. **Claims come from legs:** "sent" only when a leg proves it; unknown-but-permitted is "may have
   been sent"; never "nothing was sent" when unsure.
6. **Reset state:** clear stored verdicts, errors and notices when their step, session or the latest call changes.
7. **Bind to the session you started with:** snapshot identity at the start of a multi-step flow and
   stop if it changes.
8. **No secret-looking strings in tests or code.** The repo's Gitleaks scan checks all history.
   Build synthetic fixtures at runtime, or allowlist the exact value, path and rule.

## 6. Verified facts (don't re-derive)

- **Flutter has no hybrid API.** `firebase_ai` lacks one, so the repo has its own plugin,
  `packages/ai_logic_hybrid`, over the official SDKs:
  - Web: Firebase JS `firebase/ai` with `InferenceMode` (Chrome's built-in Gemini Nano).
  - Android: `firebase-ai` + `firebase-ai-ondevice` (Gemini Nano through AICore).
  - iOS: Apple's Foundation Models for local, plus Firebase `GeminiLanguageModel` in Apple's
    `LanguageModelSession` for cloud. Firebase iOS SDK 13.0 removed `HybridModel`.
- **On web, the Firebase SDK doesn't pass the system instruction or JSON schema to the local
  model.** The bridge sets `initialPrompts` / `responseConstraint` itself.
- **Device requirements:**
  - Android: docs list the Pixel 9 as **Gemini Nano 3**, and Nano 4 on Pixel 10/11 and Galaxy S25/S26.
  - iOS: local needs iOS 26+; Firebase's cloud model in Apple sessions needs iOS 27+.
- **App Check** has been enforced for AI Logic since Nov 2, 2026. Debug tokens are accepted for submissions.
- **The hosted app**, https://devfest-flutter-a59e8.web.app, auto-deploys from `main`; the trunk
  `hybrid/integration` doesn't deploy.
