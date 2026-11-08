# SousSight: Devpost submission

> Final copy for Devpost (DevFest Florida 2026), reviewed by Jenna. Each claim matches the merged code and docs (README, SPEC and run sheet as of #137). The team reports every beat below live-tested on the hosted app on November 8, 2026, including AI recipe drafting (#135, #136), replies in the cook's language, real Vonage delivery with a signed **Delivered ✓** callback (#39, #112), the typed pantry scan (#109), Maps grounding (#110) and grounded research (#111).

## Elevator pitch

SousSight, your AI sous-chef: turn pantry staples, local community finds and seasonal produce into dinner. It sees your counter, talks you through each step by voice, and asks instead of guessing.

## Inspiration

Our inspiration started here in Central Florida with [UCF's *"How Does Your Garden Grow?"*](https://www.ucf.edu/pegasus/how-does-your-garden-grow/) and [FreshU cooking demonstrations](https://whps.sswb.ucf.edu/cooking-demos-classes/). Food pantries, community gardens, farmers markets and local farms put pantry staples, local community finds and seasonal produce into people's hands.

Getting the food is only half the battle. When a student or new cook comes home with bread, a jar of peanut butter, canned beans and a garden tomato, the real hurdle is **knowing what to make and feeling confident making it**:
- *"What can I actually cook with what I have?"*
- *"Did I spread this evenly, or is there a thick mound in the middle?"*
- *"Someone at the table is allergic to peanuts. What can I use instead?"*
- *"How do I get help when my hands are sticky?"*

We built **SousSight, your AI sous-chef**, so anyone can walk into their kitchen with whatever they have, even a random mix, and leave with a real meal. It doesn't take over. **The cook stays in the loop.**

## What it does

SousSight is a live, multimodal cooking companion in the browser. It turns what's on your counter into a meal, watches your prep, talks you through each step, and rebuilds its Flutter workspace as you cook. Our demo is a hands-on *Peanut Butter Sandwich* session.

1. **Start with what you have.** Show your ingredients to the camera, say them out loud, or type them. **Gemini Flash** lists what it thinks it sees, but only the items you tap count.
2. **Make a meal from these ingredients.** The main action turns exactly the items you confirmed, however random, into a real meal. **Gemini Flash** drafts a 3–7 step recipe in the app's recipe format, with visible cues and timers, and it's validated before use. An **AI-drafted recipe · not reviewed** label explains that no one has checked it. Any of our three reviewed recipes that fit (Peanut Butter Sandwich, Smashed Chickpea Salad Wrap, and Black Bean & Corn Salsa) are shown as alternatives. Safety rules in the code take priority: every heated step says the camera can't confirm doneness, any heated step with meat, poultry, fish, shellfish or egg tells the cook to use a food thermometer, and only the nine major allergens are listed.
3. **Find food help nearby.** **Grounding with Google Maps** lists only grounded pantries and stores nearby, each linked to Google Maps. Sharing your location is optional and never stored. You can type a city or ZIP code instead.
4. **Allergy check first.** Before anything else, the coach asks whether anyone eating is allergic to the recipe's allergens, such as peanut and wheat. If someone is, it researches a safe swap for you to confirm. An allergen chip stays on screen.
5. **Live camera and two-way voice, in any language.** Prop your phone on the counter and talk while your hands are busy. **Gemini Live** sees the prep board, talks back with live captions, and automatically answers in whatever language the cook speaks.
6. **Generated GenUI / A2UI workspaces.** Instead of a long chat, Gemini uses **Flutter GenUI** to build cooking panels on the fly: step cues, comparisons, cook questions and timers. Every panel comes from a trusted widget catalog and is checked against its schema before it renders.
7. **The cook decides.** When a fact is missing or a choice is open, like jam or no jam, the coach asks instead of guessing and records only the cook's explicit answer.
8. **Grounded substitution research.** Ask *"Can I use sunflower seed butter instead?"* and a separate **Gemini Flash** request grounded with **Google Search** answers with clickable sources and search suggestions. A suggested swap changes nothing until you confirm it.
9. **Technique checks and opt-in watches.** Ask *"Am I doing this right?"* and show the spread, the dice or the mash, or turn on a visual watch for things like bare corners or a mound in the middle. The coach describes only what it can see. It never certifies internal temperature, freshness or that food is allergen-free.
10. **Call everyone to the table with Vonage.** The cook reviews a "dinner's started" text and then a "dinner is ready" text, including the recipient and the exact words, before anything is sent through the **Vonage Messages API**. Signed status webhooks track each text live, from submitted to delivered or read, or rejected or undeliverable with Vonage's reason. On failure the app explains how to recover and offers a retry the cook reviews again. It never resends on its own.
11. **"You made it!"** Finishing the last step shows a meal-complete screen with the pantry items you confirmed. It pauses the live coach to save cost and offers three next steps: text the household (still reviewed), find food help nearby, or cook something else. It shows no invented impact numbers.

## How we built it

* **Flutter Web + GenUI / A2UI:** a responsive, mobile-first web app that captures camera frames and microphone audio in the browser. Panels render from a trusted widget catalog, so Gemini can redesign the workspace at each step without breaking app state.
* **Gemini through Firebase AI Logic:** each model does what it's best at.
  - **Gemini Live** handles two-way voice, counter vision and workspace tool calls over WebSockets, with session resumption and context compression.
  - **Gemini Flash** handles the ingredient scan (image, audio or text in, structured JSON out) and creates recipes from any confirmed mix using the app's recipe schema, with safety rules enforced in code. It also answers research questions with **Google Search** grounding and finds nearby food help with **Google Maps** grounding.
  - Model versions are configurable through environment settings, not hard-coded.
* **Firebase (Auth, Firestore, App Check, Cloud Functions, Hosting, Secret Manager):**
  - Anonymous Auth means no account is needed.
  - Firestore sessions belong to their owner, so progress survives a reload.
  - Cloud Functions protected by **reCAPTCHA Enterprise App Check** mint short-lived, single-use Gemini Live tokens. No permanent API key ever reaches the browser.
* **Vonage Messages API:** a Cloud Function checks auth, App Check, session ownership and the recipient allowlist, so real sends go only to approved numbers. It builds each message from server-side templates and records it in a ledger before sending, so the same text can't go out twice. A second endpoint verifies Vonage's signed status webhooks and pushes delivery status to the app in real time. Unsigned callbacks are refused and forged signatures are rejected.
* **Cost guardrails:**
  - Live sessions stop after 8 minutes, with a warning first, and also stop when idle.
  - Video frames are sent at low resolution.
  - Visual watches check every 15 seconds and expire.
  - Token minting is rate-limited per user, per day and project-wide.
  - The project runs on a small monthly budget with spend alerts and per-service caps.
* **Rehearsal and live modes:** swappable service connections let the app run either as a clearly labelled rehearsal that needs no credentials or connected to the live cloud services. Clearly labelled simulated Vonage delivered and failed outcomes go through the real status handler, so repeat demos cost nothing.
* **Agentic development:** AI coding agents worked in parallel on isolated branches with clear file ownership and stacked pull requests, while we set direction and reviewed every change.
* **Delivery:** GitHub Actions deploys every merge to `main` through Workload Identity Federation, with no stored keys. Automated tests cover the Flutter UI, browser media, Firestore security rules and Cloud Functions.

## Challenges we ran into

1. **Securing Live WebSockets in the browser.** Browser WebSockets can't carry App Check headers, and shipping a long-lived Gemini key is unsafe. An App Check-protected Cloud Function verifies the client first, then mints a short-lived token locked to the Live model and its settings.
2. **Live conversation vs. grounded search.** Combining real-time tool calls with Google Search grounding in one session caused conflicts. Splitting the work fixed it: Gemini Live runs the kitchen conversation, and Gemini Flash does grounded research. We got fast voice replies and verifiable sources.
3. **Keeping cooking state in sync.** A cook may move on while an earlier camera check or search is still running. Every generated panel, watch report and research result is tagged with the step and request it belongs to, so a late result from an earlier step is thrown out instead of overwriting newer state.
4. **Timers that survive a changing UI.** Gemini rebuilds the workspace constantly, which would normally reset countdowns. Timers count down to a fixed end time stored outside the UI, so they stay accurate and survive a page reload.
5. **Proving delivery, not just acceptance.** Our first real send failed with error 1120 (Illegal Sender Address) even though Vonage had accepted the request. That taught us that acceptance and delivery are different things. We now verify Vonage's signed status callbacks and show the cook the real outcome. A real text from the hosted app reached the phone, and the app showed **Delivered ✓** from the signed callback.
6. **Letting AI write recipes without overpromising.** A random pantry mix rarely matches a fixed recipe list, so we let Gemini draft one. But a generated recipe can't vouch for food safety. We constrain the output with a response schema, keep timers within sane limits, add thermometer and "the camera can't confirm doneness" notes in code rather than trusting the prompt, and label every drafted recipe as unreviewed, both on screen and to the live coach.
7. **Browser differences.** Firebase AI Logic calls failed in Firefox on the client, so we focused on Chrome for desktop and Android, our delivery target, and say so clearly in the app and docs.

## Accomplishments that we're proud of

* **Shipping at this scale with agentic workflows.** In about two days we merged 76 pull requests and 266 commits. AI coding agents worked in parallel on separate branches, with clear file ownership and stacked PRs, while we set direction, reviewed every change and tested the live app. We couldn't have built something this large in this time without them.
* **The cook is always in the loop.** Ingredients, answers, substitutions, step changes and every message need the cook's explicit confirmation.
* **Any mix to plate in one flow:** scan what you have, make a meal from those ingredients, cook with a live coach, call everyone to the table.
* **A coach that speaks your language.** Talk to it in any language and it answers in that language, with no settings to change.
* **Verified end to end on production:** a real cook-reviewed text from the hosted app reached the phone and showed Delivered ✓ from Vonage's signed callback.
* **Production-grade web security:** no Gemini or Vonage secrets in client code, Firestore rules that keep each session private to its owner, signed webhooks, allowlisted recipients, and rate limits on every protected endpoint.
* **Nothing to install:** it runs in Chrome on desktop and Android with no account or app, which matters for students and busy households.
* **Honest engineering:** we keep a clear line between simulated and live behavior, between reviewed and AI-drafted recipes, and between a provider accepting a message and a phone receiving it.

## What we learned

* **Generative UI works best with guardrails.** A curated catalog of validated Flutter components gives far more reliable and accessible kitchen interfaces than open-ended chat.
* **Asking beats guessing.** When the coach asks a targeted question and has the cook predict before checking (*Ready / Not yet / Not sure*), passive instruction turns into real confidence.
* **Give each model one clear job.** Keeping live voice and vision separate from grounded research, ingredient analysis and recipe drafting made the system fast, robust and easy to reason about.
* **Put safety in code, not just in prompts.** Thermometer reminders, doneness disclaimers and allergen limits are applied after generation, so they hold even when the model forgets.
* **Agents multiply a small team.** With isolated branches, clear file ownership and human review on every PR, two people shipped what would normally take a much larger team.

## What's next for SousSight

* **Donate what you can't use:** using the ingredients you've confirmed, suggest nearby pantries and community organizations that need those items right now.
* **More reviewed recipes built around pantry staples, local and seasonal food:** a growing catalog shaped by what pantries, community gardens and farmers markets actually hand out, with the best AI-drafted recipes promoted after review.
* **Field testing in community kitchens:** hands-on sessions with student groups and local pantries to measure cooking confidence and how much of the food gets used.
* **Channel failover:** fall back from SMS to WhatsApp or another channel when delivery fails, using the delivery-status pipeline we already have.
* **More browsers:** extend support beyond Chrome once Firefox works with Firebase AI Logic.

## Built with

Flutter · Dart · GenUI / A2UI · Gemini Live API · Gemini Flash · Firebase AI Logic · Grounding with Google Search · Grounding with Google Maps · Firebase Authentication · Firebase App Check (reCAPTCHA Enterprise) · Cloud Firestore · Cloud Functions for Firebase (Cloud Run) · Secret Manager · Firebase Hosting · Vonage Messages API · GitHub Actions · Workload Identity Federation

**Try it:** https://devfest-flutter-a59e8.web.app (Chrome on desktop or Android) · **Code:** https://github.com/terryhh/SousSight
