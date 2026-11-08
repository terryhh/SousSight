# SousSight: Devpost submission draft

> Draft for review before pasting into Devpost (DevFest Florida 2026). Each claim is checked against the merged code and the hosted acceptance cards. Verified on production: real Vonage SMS delivered with a signed **Delivered ✓** callback (#39/#112), pantry typed input to meals (#109), Maps grounding (#110), and grounded research (#111).

## Inspiration

Our inspiration started here in Central Florida with [UCF's *"How Does Your Garden Grow?"*](https://www.ucf.edu/pegasus/how-does-your-garden-grow/) and [FreshU cooking demonstrations](https://whps.sswb.ucf.edu/cooking-demos-classes/). They show how campus gardens and food pantries supply students and households with fresh produce and pantry staples.

Getting the groceries is only half the battle. When a student or novice cook comes home with a pantry bag of bread, a jar of peanut butter, canned beans and a tomato, the real hurdle is **knowing what to make and having the confidence to make it**:
- *"What can I actually cook with what I got?"*
- *"Did I spread this evenly, or is there a thick mound in the middle?"*
- *"Someone at the table is allergic to peanuts. What can I use instead?"*
- *"How do I get help when my hands are sticky?"*

We built SousSight so anyone can walk into their kitchen with everyday pantry ingredients and leave with a meal. It isn't an AI that takes over. **The cook stays in the loop.**

## What it does

**SousSight** is a live, multimodal cooking companion for the web. It turns what you got from the pantry into a meal, watches your counter, talks you through each step, and reshapes its Flutter workspace as you cook. Our demo is a hands-on *Peanut Butter Sandwich* session.

1. **Start with your pantry haul, whatever's in it.** Show it to the camera, say it out loud, or type it. **Gemini Flash** (multimodal input, structured JSON output) lists the items it spots, but nothing counts until you tap to confirm it.
2. **Make a real meal from it.** **Make a meal from these ingredients** creates a recipe from exactly what you confirmed, even a random mix. It's built in our recipe format, checked before use, and safety rules are applied in code: thermometer reminders for meat, poultry, fish and eggs, no doneness claims, and the major allergens listed. It's labelled **AI-drafted · not reviewed**. Our reviewed recipes that fit are offered as alternatives.
3. **Find food help nearby.** Need more groceries? **Grounding with Google Maps** lists nearby food pantries and stores, with Google Maps links. Location is opt-in and never stored, and you can type a city or ZIP instead.
4. **Allergy check first.** Before giving any guidance, the coach asks whether anyone eating has an allergy to the recipe's allergens (for example peanut and wheat). An allergen chip stays on screen.
5. **Live camera and two-way voice.** Prop your phone on the counter and talk while your hands are busy. **Gemini Live** sees the prep board and talks back, with live captions. It can also reply in the cook's language, such as Spanish.
6. **Dynamic GenUI / A2UI workspaces.** Instead of a long chat, Gemini uses **Flutter GenUI** to compose cooking panels on the fly from a trusted, schema-validated widget catalog: step cues, comparisons, cook questions and timers.
7. **The cook decides.** When something is open (jam or no jam, which spread you have), the coach asks a targeted question and records only your explicit answer. Choices you haven't confirmed are never treated as confirmed.
8. **Grounded substitution research.** Ask *"Can I use sunflower seed butter instead?"* and SousSight runs a separate **Gemini Flash** request grounded with **Google Search**, showing clickable source links. A suggested swap changes nothing until you confirm it.
9. **Technique checks and opt-in watches.** Ask *"Am I doing this right?"* or turn on a visual watch to check spread coverage, such as bare corners or a mound in the middle. Vision handles visible technique only. It never certifies internal temperature, freshness or the absence of an allergen.
10. **Dinner-ready texts through Vonage.** A cook-reviewed "dinner's started" message and then a "dinner is ready" message, each sent through the **Vonage Messages API** only after the cook reviews the recipient and the exact text. Signed **delivery-status webhooks** report delivered or failed, and on failure the app shows the reason and offers a fresh, reviewed retry. It never resends on its own.
11. **"You made it!"** Finishing the last step shows a meal-complete moment: the pantry items you confirmed, the live coach paused to save cost, and next steps.

## How we built it

* **Flutter Web and Generative UI (Flutter, GenUI, A2UI):** a responsive, mobile-first web app that captures camera frames and microphone audio in the browser and renders cooking panels from a trusted widget catalog. Every generated panel is validated before rendering, so Gemini can redesign the workspace for each step without breaking app state.
* **Google Gemini (Gemini 3.8 Live and Gemini 3.8 Flash through Firebase AI Logic):** each model does what it's best at.
  - **Gemini Live** handles two-way voice, counter vision and workspace tool calls over WebSockets, with session resumption and context compression.
  - **Gemini Flash** handles the pantry scan (image, audio or text in; structured JSON out), **recipe creation** from any confirmed ingredients, **Google Search** grounding for cited research, and **Google Maps** grounding for nearby food help.
* **Firebase (Auth, Firestore, App Check, Cloud Functions, Hosting, Secret Manager):**
  - Anonymous Auth means no account is needed.
  - Owner-scoped Firestore sessions keep progress across reloads.
  - Cloud Functions protected by **reCAPTCHA Enterprise App Check** mint short-lived, single-use Gemini Live tokens, so no permanent API key ever reaches the browser.
* **Vonage Messages API:** a Cloud Function checks auth, App Check, session ownership and the recipient allowlist. It builds the message from server-side templates and claims an idempotency ledger entry before sending. A second endpoint verifies Vonage's signed status webhooks and mirrors delivery status to the app in real time.
* **Cost guardrails:**
  - Live sessions cap at 8 minutes with a warning and an idle stop.
  - Video frames go at low media resolution.
  - Visual watches check every 15 seconds and expire.
  - Token minting is limited per user, per day and project-wide.

  The whole demo runs on a $10 Gemini budget.
* **Rehearsal and live modes:** injectable service contracts let the app run as a clearly labelled, zero-credential **rehearsal** or connected to live cloud services.
* **Delivery:** GitHub Actions deploys every merge to `main` through Workload Identity Federation (no stored keys). Automated tests cover the Flutter UI, browser media, Firestore security rules and Cloud Functions.

## Challenges we ran into

1. **Securing Live WebSockets in the browser.** Browser WebSockets can't carry App Check headers, and shipping a long-lived Gemini key is unsafe. An App Check-protected Cloud Function verifies the client first, then mints a short-lived ephemeral token locked to the Live model and settings.
2. **Live conversation vs. grounded search.** Mixing real-time custom tool calls with Google Search grounding in one session caused tool conflicts. Splitting the work across two models, Gemini Live for the kitchen conversation and Gemini Flash for grounded research, gave fast voice replies plus verifiable sources.
3. **Keeping cooking state in sync.** A cook may move to the next step while an earlier camera check or search is still running. Generated panels, watch reports and research results carry **step IDs, watch IDs and request epochs**, so late results from an earlier step are rejected instead of overwriting newer state.
4. **Timers that survive a changing UI.** Gemini recomposes the workspace constantly, and naive replacement would reset countdowns. Timers run from absolute deadlines in the state layer, so they stay accurate through UI changes, and the active timer survives a page reload.
5. **Proving delivery, not just acceptance.** Our first real send was rejected with error 1120 (Illegal Sender Address), even though Vonage had accepted the request. That taught us to treat acceptance and delivery as different things. We now verify Vonage's signed status callbacks and show the cook the real outcome. A real text sent from the hosted app reached the phone, and the app showed **Delivered ✓** from the signed callback. For repeatable demos, a clearly labelled mode runs simulated delivered and failed events through that same handler without spending SMS credit.

## Accomplishments that we're proud of

* **Truly human-in-the-loop.** Pantry items, answers, substitutions, step changes and every message all need the cook's explicit confirmation.
* **From pantry bag to plate in one flow:** scan, choose a meal, cook with a live coach, text the household.
* **Production-grade web security.** No Gemini or Vonage secrets in client code, owner-isolated Firestore rules, signed webhooks, and rate limits on every protected endpoint.
* **Accessible and zero-install.** It runs in Chrome on Android and desktop with no account or app install, which matters for students and busy households.
* **Transparent engineering.** We keep clear lines between simulated and live output, and between a provider accepting a message and a phone receiving it.

## What we learned

* **Generative UI works best with guardrails.** A curated catalog of validated Flutter components gives far more reliable, accessible kitchen interfaces than open-ended chat.
* **Asking beats guessing.** Having the coach ask a targeted question, then predict before checking (*Ready / Not yet / Not sure*), turns passive instruction into real confidence.
* **Give each model one clear job.** Separating live voice and vision from grounded research and pantry analysis kept the system robust, fast and easy to reason about.

## What's next for SousSight

* **Reviewed recipe library:** promote well-tested AI-drafted recipes into reviewed ones, with input from local pantries and campus gardens.
* **Community kitchen field testing:** hands-on sessions with student groups and local pantries to measure cooking confidence and food use.
* **Channel failover:** fall back from SMS to WhatsApp or another channel when delivery fails, using the delivery-status pipeline already in place.
* **Fully bilingual experience:** go from a coach that replies in the cook's language to a bilingual interface, starting with Spanish.

## Built with

Flutter · Dart · GenUI / A2UI · Gemini Live API · Gemini Flash · Firebase AI Logic · Grounding with Google Search · Grounding with Google Maps · Firebase Authentication · Firebase App Check (reCAPTCHA Enterprise) · Cloud Firestore · Cloud Functions for Firebase (Cloud Run) · Secret Manager · Firebase Hosting · Vonage Messages API · GitHub Actions · Workload Identity Federation

**Try it:** https://devfest-flutter-a59e8.web.app · **Code:** https://github.com/terryhh/SousSight
