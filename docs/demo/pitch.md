# SousSight: 3-minute DevFest pitch

Card: [SS-052 #130](https://github.com/terryhh/SousSight/issues/130). Owner: Jenna (`jennajh`).
Built on the DevFest Florida "3-Minute Hackathon Pitch Skeleton". It follows Terry's on-stage run sheet in [CONFERENCE-PEANUT-BUTTER.md](../handoffs/CONFERENCE-PEANUT-BUTTER.md#on-stage-run-sheet-300-pm-showcase). Facts come from the [Devpost submission](../devpost/SUBMISSION.md) and the evidence table in [README.md](README.md#evidence-status-by-segment).

Live app: https://devfest-flutter-a59e8.web.app · Code: https://github.com/terryhh/SousSight

## Evidence snapshot (November 8 records, refreshed November 10)

Re-read these cards right before going on stage. Say "live" only for a row marked hosted pass.

| Beat | Status | Card |
|---|---|---|
| Pantry scan, **typed** | Hosted pass, desktop Chrome (after fix #124) | [#109](https://github.com/terryhh/SousSight/issues/109) |
| Pantry scan, **photo or voice** | Terry confirmed Android Chrome photo scan and six-second voice input, confirmed-item handoff, Back cleanup and pending-permission cancellation | [#109](https://github.com/terryhh/SousSight/issues/109) |
| AI-drafted recipe | Terry reported a successful new pizza recipe; device/build and individual heating safety checks were not restated | [#134](https://github.com/terryhh/SousSight/issues/134) |
| Find food help nearby (Maps grounding) | Desktop typed-city/missing-ingredient searches and phone Chrome location search passed. Deny-location-then-type-city remains unrecorded | [#110](https://github.com/terryhh/SousSight/issues/110) |
| Live voice and vision coach | Hosted pass | [#6](https://github.com/terryhh/SousSight/issues/6) |
| Generated GenUI panels and cook questions | Hosted pass | [#13](https://github.com/terryhh/SousSight/issues/13) |
| Sunflower seed butter research with sources | Hosted pass, typed (six sources) | [#111](https://github.com/terryhh/SousSight/issues/111) |
| Allergen chip (peanut, wheat) | Hosted pass. The **spoken** allergy question is unchecked | [#111](https://github.com/terryhh/SousSight/issues/111) |
| Coach replies in the cook's language (Spanish) | Not checked | [#111](https://github.com/terryhh/SousSight/issues/111) |
| Real timer surviving reload (salsa) | Hosted pass | [#16](https://github.com/terryhh/SousSight/issues/16) |
| Vonage simulated delivered / failed | Simulated by design (no credit spent) | [#112](https://github.com/terryhh/SousSight/issues/112) |
| Vonage real SMS and signed status callback | Hosted send received on Terry's handset; Delivered status confirmed the signed callback on main `646bd63` | [#112](https://github.com/terryhh/SousSight/issues/112), [#39](https://github.com/terryhh/SousSight/issues/39). Webhook deployment and rejection probes passed in [#126](https://github.com/terryhh/SousSight/issues/126) |

On stage we use the **simulated** Vonage buttons and say so. A real send needs fresh approval of the exact recipient and text.

## The skeleton, filled in

| Time | Block | Job | SousSight |
|---|---|---|---|
| 0:00–0:20 | Hook plus problem | Name the pain in one sentence | "Central Florida pantries, like UCF's garden-to-pantry program, put groceries in people's hands. But a bag of bread, peanut butter, beans and a tomato isn't dinner until someone knows what to make, and has the confidence to make it." |
| 0:20–0:30 | One-line solution | What we built, in one breath | "SousSight is a live cooking coach in your phone's browser. It sees your counter, talks you through each step, and asks you instead of guessing." |
| 0:30–2:00 | Live demo | Show it working, narrate what they see | Beats 1–6 below |
| 2:00–2:30 | How it works | One diagram, one key move | Architecture slide (README diagram) or **How it works → Under the hood** |
| 2:30–3:00 | Impact and close | Who it helps, then stop | Close below |

## Spoken script

Speaker names are a suggestion. Swap them to suit the team.

### 0:00–0:20 · Hook (Jenna, holding the pantry bag)

> "I just got this from the campus pantry. Bread, peanut butter, a can of beans, a tomato. Central Florida pantries, like UCF's garden-to-pantry program, get groceries into people's hands. But a bag of groceries isn't dinner. You have to know what to make, and feel confident making it."

### 0:20–0:30 · Solution

> "SousSight is a live cooking coach in your phone's browser. It sees your counter, talks you through each step, and asks you instead of guessing. You stay in charge."

### 0:30–2:00 · Demo beats

Bullet beats, not a script. Roughly 15 seconds each. Say the label in brackets out loud whenever a beat isn't live.

1. **Pantry → meals (0:30).** Type or say the haul and tap **Find my meal**. Tap to confirm only the right items. *"Gemini Flash suggests what it sees, but nothing counts until I confirm it."* Show the ranked meals, with matched and missing items.
   - Typed, photo and voice input have recorded Chrome acceptance (#109). Use the input rehearsed on the presentation device.
   - Alternate recipe beat, as in the run sheet: confirm a different ingredient mix, then **Make a meal from these ingredients** → review the AI draft's **not reviewed** label → **Cook this draft**. A pizza draft worked in Terry's rehearsal (#134). Replace another beat to keep three minutes; do not start heating just to demonstrate a timer, and never equate timer expiry with doneness.
2. **Food help nearby (0:45).** **Find food help nearby** → `Orlando, FL` → **Search**. *"Grounded with Google Maps: real pantries and stores, with Maps links. Location is opt-in, or I just type a city."* Close the sheet.
3. **Start cooking (1:00).** Pick **Peanut Butter Sandwich** → **Start**. *"Help me make a peanut butter sandwich."* The coach greets me and a generated step panel appears. *"That panel isn't hard-coded. Gemini composed it from a vetted Flutter widget catalog."*
4. **Allergy check and research (1:15).** Point at the peanut and wheat chip. Ask: *"Can I use sunflower seed butter instead?"* *"That's a separate grounded search, with sources I can tap. The swap changes nothing until I confirm it."*
   - If the coach doesn't ask the allergy question out loud, don't claim it did. Point at the chip.
5. **Technique check (1:35).** Spread on camera: *"Am I doing this right?"* Show the comparison panel. *"It describes what it can see, like bare corners. It can't tell you food is safe, cooked through, or allergen-free."*
   - Optional, only if checked: one exchange in Spanish. Say *"It replies in the cook's language."* Skip it if #111 hasn't verified it.
6. **Vonage: started, ready, failed (1:45).**
   - **Text household: started cooking** → recipient entered off camera → review → **Simulate delivery (demo)**. Say: *"Simulated delivery, no SMS spent. I reviewed the recipient and the exact text first."*
   - **Dinner is ready** → review → **Simulate failed delivery (demo)**. Say: *"This is the real error we hit in setup, Illegal Sender Address, replayed as a simulation. The app shows the reason and offers a fresh, reviewed retry. It never resends on its own."*
   - *"We sent a real one in testing on November 8. It arrived, and the signed delivery callback updated the app."*
   - Finish the last step: **"You made Peanut Butter Sandwich!"** The coach pauses to save cost.

### 2:00–2:30 · How it works (Terry, architecture slide)

> "Each model gets one job. Gemini Live handles voice, vision and the workspace. Gemini Flash handles the pantry scan and grounded search with Google Search and Google Maps. The UI is Flutter GenUI: Gemini picks from a schema-checked widget catalog, so it can redesign the screen for every step without breaking state. No API keys in the browser: an App Check–protected Cloud Function mints short-lived Live tokens. Vonage runs server-side with an allowlist and an idempotency ledger. And it's built to run cheap: sessions cap at eight minutes, idle sessions stop, and watches expire."

### 2:30–3:00 · Impact and close (Jenna)

> "This is for students, first-time cooks and families stretching pantry staples. No account, no install, the phone browser they already have. We haven't measured outcomes yet. Our next step is testing with student groups and local pantries. So: the demo is live, the code is open. Point your camera at what you've got, and start cooking."

Stop talking.

## How it maps to the judging criteria

| Criterion | Where it lands | Line to say |
|---|---|---|
| **Impact** | Hook and close | UCF garden-to-pantry and FreshU as *inspiration*, Central Florida households, no account and no install |
| **Innovation** | Beats 1, 3, 4 | Pantry scan → live coach, Gemini-composed GenUI panels, Maps-grounded food help |
| **Technical execution** | 2:00 block | Two-model split, ephemeral Live tokens behind App Check, server-side Vonage with allowlist and idempotency, cost caps. The signed status webhook was deployed and real delivery confirmed on November 8 (#126, #39); the on-stage simulation remains labelled |
| **Presentation** | Whole flow | 3-minute timing, one human-in-the-loop story from pantry bag to plate |

## Words we never say

- No household counts, savings, adoption numbers or "proven" outcomes. None are measured.
- No partnership with or endorsement by UCF or any pantry. Their public programs inspired us.
- Not "it speaks Spanish", but "it replies in the cook's language", unless #111 records a Spanish pass.
- Not "it texted my family" for a simulated take. "Vonage accepted it" means submitted, not delivered.
- Not "the camera checked allergens, freshness, doneness or safety".
- Not "it runs on $10" as a cost result. $10 of Gemini spend is the showcase *budget* (SS-043), not a measured bill. Cost guardrails are fine to describe.
- No model version numbers on screen. They're configurable.

## Q&A, 15 seconds each

| Question | Answer |
|---|---|
| "Is that live or faked?" | "The coach, panels, research and Maps are live on the hosted app. The Vonage outcomes are simulated on stage so we don't spend SMS credit. They're labelled, and they run through the same status handler." |
| "Did a real text ever go out?" | "Yes. A hosted send on November 8 arrived on Terry's phone, and its signed delivery callback updated the app. On stage we simulate." |
| "How do you stop it hallucinating a UI?" | "Gemini can only pick from our widget catalog, and every panel is schema-checked before it renders." |
| "What about food safety?" | "Vision covers visible technique only. It never certifies temperature, freshness or allergens. That's why it asks the cook." |
| "Where are your keys?" | "Not in the browser. App Check guards a Cloud Function that mints short-lived Live tokens. Vonage credentials stay in Secret Manager." |
| "What does it cost?" | "Sessions cap at eight minutes, idle ones stop, and watches expire. Our showcase budget is ten dollars of Gemini. Happy to show you the guardrails after." |
| "Who's using it?" | "Nobody outside the team yet. Next is testing with student groups and local pantries." |

## Failure drill

If the live app stalls, switch in under five seconds. Say:

> "And here is the same flow on video."

Then cut to the backup recording ([SS-048 #113](https://github.com/terryhh/SousSight/issues/113)). The card was closed after Terry confirmed demo preparation complete, but has no recording link: locate and play the file before presenting. If it is unavailable, use the labelled rehearsal build (`FAKE_BACKEND=true`) and say "Rehearsal build, simulated."

Fallbacks from the run sheet:
- `?recipe=black_bean_corn_salsa_v1` skips the scan. It has a real 5-minute meld timer.
- Keep slides in a separate window. A hidden app tab stops capture.

## Rehearsal checklist

- [ ] Three timed full runs, out loud. One person owns the timer.
- [ ] One cold-judge run with someone new to the project. If they ask "wait, what does it do?", fix the hook.
- [ ] Q&A drill: one idea and one example per answer, 15 seconds.
- [ ] Failure drill: kill the demo mid-run and switch to the video.
- [ ] Re-read #109, #110, #111 and #112 right before going on, and update the snapshot.
