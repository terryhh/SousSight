# SousSight design spec

DevFest Hackathon 2026, Devs Track: "Fix the Handoff". Last updated Sat Nov 7, 2026.

## Thesis

A recipe card is a one-way handoff. SousSight makes it two-way. The coach checks what it can see against an instructor-reviewed target. Anything it shouldn't judge goes to the right human instructor, with the evidence attached. That instructor's answer then becomes reviewed guidance that the coach reuses for the next learner.

- AI is the triage and context builder. People own the answers. (Augmentation, not replacement.)
- Learning comes first. The learner predicts before the coach checks, and every verdict names the visual cue to learn.
- Local context: UCF Knights Pantry gives out produce, and "students just didn't know what to do with it" (UCF Pegasus, Fall 2022). FreshU demos send students home with a recipe card. We use FreshU as a model, **not** as a partner.

## Demo arc (about 3 minutes)

1. **Predict, then check the mash.** The learner taps "Not yet", then "Am I doing this right?". The coach replies "Not yet, about half the chickpeas are still whole" and names the cue. The learner mashes and checks again, and gets a match.
2. **Unreviewed substitution, routed to the right human.** The checklist shows lemon as Missing. The learner asks "Can I use vinegar?". It isn't a reviewed swap, so a help sheet opens with a Gemini summary and photos. Routing rules pick Marcus (substitutions, available).
   - The board card shows *why* Marcus was picked.
   - Marcus gets a Vonage message.
   - Marcus accepts and writes the answer.
   - The learner taps "This solved it".
   - Marcus ticks **Make reusable**.
   - The next learner sees the swap credited to Marcus. No handoff needed.
3. **Safety question, no owner available.** The learner asks "My roommate has a sesame allergy, is this OK?". The coach gives a fixed reply ("can't judge allergens from a photo"). The request routes to the allergens skill. Priya, the only allergens instructor, is offline, so the card lands in the red **Needs owner** lane, showing its age and a next step. A forced failed delivery shows "Message failed, status still visible in the app".
4. **Close.** Explain the routing and storage choices and the measured accuracy. The learner sends a "Thanks, Chef!" message with a photo of the wrap.

## Scope

| ID | Capability | Status |
|---|---|---|
| B | Reviewed recipe (`assets/recipes/chickpea_wrap_v1.json`), one active step with its cue | core |
| C | Still-photo checkpoint vs reviewed target, structured outcome, validated (`core/triggers.dart`) | core |
| D | Predict-then-check: self-rating before the verdict; the verdict names the cue | core |
| L | Handoff: request packet, Gemini triage, rules routing, human accept, board lanes | core |
| M | Deterministic handoff gates: unreviewed substitution, 2 inconclusive results, safety keywords | core |
| N | Knowledge loop: approve an answer as a reviewed substitution | core |
| P | Vonage Messages API notifications + failed-delivery state | core |
| K/S | Persistence, revision guard, idempotent request IDs, offline intake | core |
| I | Timer pops up for timed steps (`timerSeconds`); deadline stored, never a countdown | stretch 1 |
| A | Ingredient checklist (Have / Missing / Substituted). Photo prefill is optional | stretch |
| E/F | Gemini Live, audio-only, push-to-talk; tools: check_now, start_timer, next_step, draft_help_request | stretch 2 |
| J | GenUI 0.10.4, custom 3-item catalog, for free-form questions only | stretch 3 |
| R/T | Duplicate "+1", Spanish↔English summary | stretch |
| — | Continuous Live video, watch-and-alarm, AI-drafted instructor replies | **cut** (see review) |

The cut watch mode is replaced by a nudge: after the learner has spent N seconds on a checkpoint step, the coach asks "Ready to check? What do you think?" and opens predict-then-check.

## Architecture

One Flutter codebase with two **web** entrypoints, served from Firebase Hosting over HTTPS. Phones open the learner URL in a browser. Android and iOS builds remain possible later; the code stays platform-neutral.

```
lib/
  core/        models, state machine, routing, triggers, service interfaces, fakes  (no Firebase)
  data/        Firestore + Auth implementations of core/services.dart, App Check init
  ai/          Gemini via Firebase AI Logic: assessment + triage clients, prompts, schemas
  learner/     learner UI (phone)          main_learner.dart
  board/       instructor board UI (web)   main_board.dart
functions/     Cloud Functions (TypeScript): Vonage notifications
tool/seed.mjs  seeds recipe + demo roster (firebase-admin)
```

- **Model calls happen only on the learner device.** The board makes no AI calls.
  - `gemini-3.8-flash`: checkpoint assessment (structured output).
  - `gemini-3.5-flash-lite`: triage, classification and summary.
  - Model IDs live in `lib/ai/ai_config.dart`.
- **Always use `FirebaseAI.googleAI()`.** `vertexAI()` no longer exists in firebase_ai 5.x.
- **App Check is enforced for AI Logic**, so the learner app activates it before any model call:
  `FirebaseAppCheck.instance.activate(providerWeb: WebDebugProvider(debugToken: ...))` in debug builds, with `ReCaptchaEnterpriseProvider(siteKey)` otherwise.
  - Pass the debug token with `--dart-define=APPCHECK_DEBUG_TOKEN=...`.
  - Register it in the console under App Check → web app → Manage debug tokens.
  - Never commit it.
- **Fake backend:** `--dart-define=FAKE_BACKEND=true` swaps in `core/fakes.dart`, so either UI runs with no Firebase.

## Firestore

Field names are the `toMap()` keys in `lib/core/models.dart`, and the models are the source of truth. The data layer converts `DateTime` ↔ `Timestamp` and `Uint8List` ↔ `Blob`.

| Path | Model | Notes |
|---|---|---|
| `recipes/{recipeId}` | `Recipe.toMap()` | Seeded. Clients may only append to `reviewedSubstitutions` (instructors). |
| `sessions/{sessionId}` | `CookingSession` | Owner-only. `revision` bumps on every learner-confirmed change. |
| `sessions/{id}/checkpoints/{cpId}` | `CheckpointRecord` | Photo is a ≤768px JPEG Blob (~60-150 KB). No Cloud Storage. |
| `requests/{requestId}` | `HelpRequest` | ID is a client UUID (idempotent). Holds ≤2 thumbnails (≤512px) so instructors never read sessions. `notify` is written by Functions only. |
| `instructors/{id}` | `Instructor` | Admin-seeded; read by signed-in users. Clients may change only `available`, and only on their own doc (coordinator: any). |
| `config/demo` | `{notifyEnabled, forceNotifyFailure, channel}` | Coordinator-writable demo switches. |

**Auth:**
- Learners sign in anonymously.
- Instructors sign in with email and password. `instructors/{uid}` links the account to a roster entry.
- Demo roster members without a login (e.g. Priya) are data-only, labeled "Demo data".

**Request lifecycle:** see the header of `core/request_machine.dart`. Every board and learner action runs the pure transition inside `RequestRepository.transact`.

**Routing:** `core/routing.dart`. An instructor is eligible if they are available and cover the needed skill. Ties go to the lowest open load, then the least recently assigned. Gemini picks the *category*; the rules pick the *owner*; a person *accepts*. Decline reroutes; no match leaves the card in Needs owner.

## AI contracts (`lib/ai/`)

**Assessment** (`gemini-3.8-flash`, `responseMimeType: application/json` + `responseSchema`):
- Inputs, each labeled in text:
  - IMAGE 1 TARGET (asset)
  - IMAGE 2 CURRENT
  - optional IMAGE 3 PREVIOUS
  - step instruction, checkpoint target, cue list, confirmed facts
- Schema: `outcome` enum(matchesTarget, adjust, uncertain, needBetterView), `observations` string[] (≤3, visible facts only), `cue`, `suggestedAction`, `adjustmentId` enum(checkpoint.allowedAdjustments) nullable, `confidence` enum(low, medium, high), `outOfScope` bool, `outOfScopeReason`.
- System rules:
  - Judge appearance for this technique only.
  - Never judge safety, doneness, freshness or allergens; set `outOfScope` instead.
  - If the bowl is not clearly visible, return needBetterView.
  - If unsure, return uncertain.
- Always run `validateAssessment()` before display.
- Discard stale results with `isStale()`.

**Triage** (`gemini-3.5-flash-lite`, structured):
- Schema: `category` enum(technique, substitution, safetyAllergen, equipment, other), `urgency`, `summaryForInstructor` (≤60 words: question, step, what was tried, what the AI could not judge), `aiUncertainty`, `englishQuestion`, `clarifyingQuestion`, `language`.
- `isSafetyQuestion()` overrides the category to safetyAllergen.
- Triage runs after `submit()`. A request can sit in `submitted` while the learner is offline.

## Learner app (phone, web)

- **Fixed chrome:**
  - Top bar: recipe title, step n/N, progress.
  - Bottom bar: **Am I doing this right?** (capture), **Ask an instructor** (with a request status badge), and the mic (stretch).
  - Camera preview always visible above the working panel.
- **Screens and panels:**
  - **Start:** recipe card. The one-recipe scope is stated.
  - **Checklist:** Have / Missing per ingredient. Missing shows the reviewed swaps and "Ask about another substitute".
  - **Step:** instruction, cue, target photo, timer card if `timerSeconds`.
  - **Predict chips** (Ready / Not yet / Not sure), required before capture.
  - **Verdict card:** outcome chip, "You said X · Coach: Y", observations, cue, action button.
  - **Help sheet:** question, summary preview, the exact thumbnails that will be shared, routing preview. Send creates the request.
  - **Request status:** timeline, next step, add details, cancel, and "This solved it" / "Still stuck".
  - **Done:** recap of cues learned and instructor tips.
- **Capture:** use the `camera` plugin for a still, then downscale to 768px JPEG q75 (`package:image`). Thumbnails are 512px q70.

## Instructor board (projector, web)

- **Lanes:** Needs owner (red, with age timer) | With instructor (Suggested / Accepted badges) | Answered | Resolved.
- **Card:** question, category/skill chips, summary, **AI could not judge** line, thumbnails, step, routing "why", history timeline, notification chips (sent ✓ / failed ✗).
- **Signed-in instructor:**
  - Availability toggle.
  - Accept, Decline (with reason), Answer box.
  - **Make reusable** checkbox on answered substitution requests.
- **Coordinator:**
  - Assign on Needs-owner cards.
  - Toggle availability for demo roster members.
  - `config/demo` switches.
  - Reset demo.
- The roster is labeled "Demo data". Large type so it's readable from 5 m.

## Vonage (`functions/`)

- A Firestore trigger on `requests/{id}` writes, comparing before and after `status`. It sends:
  - `instructorRouted`, on → suggested (to the suggested instructor);
  - `learnerAccepted`, on → accepted;
  - `learnerAnswered`, on → answered.
- `sendThanks` is a callable function: the learner's "Thanks, Chef!" message to the instructor who helped.
- **Channel:** Vonage Messages API, `config/demo.channel` = `whatsapp` (sandbox `https://messages-sandbox.nexmo.com/v1/messages`) or `sms`.
- **Phone numbers:** `instructorContacts/{id}` and `learnerContacts/{uid}` (admin-only), E.164 without `+`.
- **Secrets:** `VONAGE_API_KEY` and `VONAGE_API_SECRET`, via `defineSecret`.
- **Idempotent:** skip if `notify.<kind>.state == sent`.
- **Failures:** on error, or when `forceNotifyFailure` is set, write `notify.<kind> = {state: failed, error}`. The board shows it, and the in-app status still updates.
- **Sandbox limits:** 100 messages/month and 1 msg/s, so use `notifyEnabled=false` during rehearsals. The WhatsApp 24h window means demo phones should message the sandbox on Sunday morning.
- Requires the Blaze plan.

## PR stack

1. `stack/01-foundation`: scaffold, this spec, core models/state machine/routing/triggers, fakes, tests.
2. `stack/02-data`: Firestore/Auth repos, App Check init, rules, seed.
3. `stack/03-ai`: assessment and triage clients, prompts, schemas.
4. `stack/04-board`: instructor board.
5. `stack/05-learner`: learner app.
6. `stack/06-vonage`: Cloud Functions.
7. `stack/07-integration`: wire real backends, hosting deploy, smoke test.

Each PR stacks on the previous one. Directories don't overlap, so rebases stay trivial.

## Console checklist (humans)

1. Firebase console → AI Logic → Get started → Gemini Developer API.
2. App Check:
   - Register the web app.
   - Manage debug tokens → add one UUID and share it out-of-band.
   - The AI Logic App Check enforcement is already on.
3. Authentication: enable Anonymous and Email/Password. Create instructor accounts (ana@, marcus@, coordinator@ demo emails).
4. Upgrade to Blaze with a budget alert (needed for Functions/Vonage).
5. Vonage dashboard:
   - Messages API Sandbox → allowlist demo phones on WhatsApp.
   - Copy the API key and secret.
   - Ask the Vonage advocate at the venue if blocked.
