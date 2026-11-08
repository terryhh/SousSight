# Conference rehearsal: peanut butter sandwich

November 8, 2026. **Hard stop: 3:00 PM Eastern today.** Prioritize deploying the sandwich flow, then meaningful live checks, with time reserved to record results and stop media. Terry requested this as the main demo recipe. This is Terry’s technical integration quickstart and rehearsal checklist, not Jenna’s SS-024 demo story or proof that the new recipe is deployed. Terry owns the recipe/integration and focused regression cards SS-031/SS-032; Jenna's separate demo preparation, research implementation and physical acceptance remain hers. No cooking or heating is needed.

The intended recipe ID is `peanut_butter_sandwich_v1`, with untimed steps `prep`, `spread`, `optional_jam`, and `close`. The peanut-butter checkpoint uses a live text cue; no reference photograph is required or expected. Existing chickpea/reference-photo assets remain intact for their separate work. The app integration makes `RECIPE_ID` default to `peanut_butter_sandwich_v1`; `chickpea_wrap_v1` remains a build-configured alternate, not a promised in-app recipe selector.

## Before opening the camera

Have bread, peanut butter, a plate and a spreading utensil ready; jam is optional. The cook confirms the ingredients suit them. Ask only what is missing: which bread they have, whether they want smooth or chunky texture, and whether they want jam. Do not silently add jam or treat a suggested substitution as confirmed.

Open [SousSight](https://devfest-flutter-a59e8.web.app) on the conference device over HTTPS. Confirm the selected recipe and visible labels actually say peanut butter sandwich. Record the deployed build/commit, browser/device and whether this is real mode or a clearly labeled simulated rehearsal. Check the camera view can show the bread and spreading surface without capturing bystanders. Keep input and Stop visible. If the deployed recipe is still chickpeas, record that mismatch and wait for the sandwich rollout rather than presenting it as complete.

## Repeatability

Use **New cook** (SS-033) to start a fresh session between runs; earlier sessions are preserved. Each dinner notification belongs to one session, so start a New cook before any repeated real send.

For a separate rehearsal identity, the user can choose a new browser profile or a fresh private session. A new private tab alone can share the existing private identity; a fresh private session requires the user to close all private windows first and then open a new one. Do not automatically close the user's windows or delete cooking data. Record which identity/session approach was used; a new identity does not prove existing-session reset behavior.

## Short live sequence

1. Start camera/voice only when ready. Say, “Help me make a peanut butter sandwich.” Confirm that the coach responds to the actual sandwich context. Ask one targeted question about the missing bread, texture or jam preference rather than reciting a long questionnaire.
2. Choose a preference explicitly, for example “smooth peanut butter, no jam.” Look for the real generated question/choice or step panel and its acknowledgement. Model generation alone is not evidence that the cook confirmed a fact; verify the explicit answer is shown as confirmed.
3. Spread peanut butter while showing the work area. Ask for a practical adjustment such as “How can I spread this without tearing the bread?” A grounded research answer should show its returned sources and provider attribution. Review any proposed change before confirming it. Do not invent a source or claim research passed if the provider is unavailable.
4. Assemble the sandwich. Let the workspace follow the current step. Spreading and assembly do not require a timer, so do not create a countdown merely to demonstrate a feature. If the cook explicitly wants a short reminder for their own reason, label it as their requested reminder rather than a recipe requirement.
5. Use a visible-change watch only if useful and explicitly requested, for example checking whether spread coverage has reached the visible edges. Show the active watch state, describe uncertainty/occlusion and ask for cook confirmation. If there is no useful watch, skip it and explain that opt-in watches remain available. Appearance cannot establish temperature or food safety.
6. Stop and confirm camera/microphone are off. A dinner-ready message can be reviewed as a separate capability, but do not click send during this rehearsal without fresh explicit authorization for the exact recipient and text. The previous one-message authorization was exhausted; no automatic retry is allowed.

## On-stage run sheet (3:00 PM showcase)

Updated November 8 for the pantry-first build. Each beat names the Google or Vonage capability it shows. Mark every beat live, rehearsal or skipped in SS-040 (#95).

| # | Beat (about 30 s each) | What the judges see | Capability |
|---|---|---|---|
| 1 | "I just got this from the UCF pantry." Scan the haul (bread, peanut butter, canned beans, corn, tomato), or say it, or type it. | Candidate items to confirm; ranked meals with matched/missing items; one clarifying question | Gemini Flash multimodal + structured output (Firebase AI Logic), GenUI |
| 2 | Pick **Peanut Butter Sandwich** and press **Start**. | Live coach greets the cook; generated step panel | Gemini Live voice + vision, GenUI/A2UI |
| 3 | "Is anyone eating this allergic to peanuts?" Answer, then ask "Can I use sunflower seed butter instead?" | Cook-question panel; grounded answer with source links and Google suggestions | `ask_cook` human-in-the-loop, Grounding with Google Search |
| 4 | Spread on camera: "Am I doing this right?" Optionally "Watch until it's spread to the edges." | Comparison panel describing visible coverage; watch status | Live vision, opt-in watch |
| 5 | Optional: speak Spanish for one exchange. | Coach answers in Spanish | Live native multilingual audio |
| 6 | **Text household: started cooking**, review, confirm. | "Sent to Vonage → Delivered ✓" | Vonage Messages API + signed status webhook |
| 7 | **Dinner is ready**, review. Then **Simulate failed delivery (demo)**. | "Simulated failure: Illegal Sender Address (1120)", plus recovery options | Vonage failure handling (challenge requirement) |
| 8 | Close on the architecture slide (README diagram): routing and storage choices. | One slide | Devs-track requirement |

Fallbacks:
- `?recipe=black_bean_corn_salsa_v1` skips the scan. The salsa has a real 5-minute meld timer.
- Rehearsal build (`FAKE_BACKEND=true`), labelled simulated.
- Backup screen recording.

Venue checklist:
- Headset mic.
- Phone stand angled at the counter.
- Camera and mic permissions pre-granted.
- Slides in a separate window, never covering the app tab: a hidden tab stops capture.
- Allow at least 3 s between Stop and Start.
- **Real SMS needs fresh explicit approval of the recipient and text, to a Vonage-verified trial number only.**

## Honest fallback and completion record

If conference connectivity or a service fails, preserve the cooking state, stop media if appropriate and state which capability is unavailable. A simulated fallback must be visibly labeled; it is not a live-service pass. A physical sandwich demonstration can continue without inventing model output.

Record the actual results on SS-032: deployed build/URL, device/browser, sandwich context, heard coach and recognized speech, generated question/choice, confirmed fact, research/source rendering, optional watch outcome if requested, and Stop cleanup. Mark pass/fail/blocked/not run for each exercised scenario. Do not include raw media, bystanders, credentials or recipient details in GitHub. Historical chickpea tests remain valid history but do not prove sandwich acceptance.

No paid service upgrade or credit purchase is part of this plan. Keep real tests short under the accepted $20 gross monthly soft budget; record available usage and unknown charges. The user's earlier $0 billing display is not a verified final cost or credit balance. Jenna retains SS-021 Vonage setup and SS-023 full physical acceptance; this short rehearsal does not close those cards or the full MVP.

## Recorded local rehearsal evidence

2026-11-08: Root inspected FAKE_BACKEND=true at localhost:7360 on the app branch before the copy correction. Chrome showed the peanut-butter title and three ingredients, neutral Watch my food, Start → Rehearsal on, Next → step 2/4 Spread peanut butter, and Check my food produced a simulated comparison matching the peanut-butter text cue without chickpea/reference-image claims. The pinned dock stayed stable as the panel grew; Stop returned Rehearsal ready. No actual media, AI request or SMS was used. Recipe copy was then corrected in PR #81 commit aacf777 to three cook-facing strings; those updated strings need their own build verification. This is local simulated UI evidence, not hosted sandwich/live-service acceptance.
