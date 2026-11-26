# Demo video script (≤ 3:00)

<!--
  Card SS-080 (#167). Shot list, voice-over and title cards for the #BuildHybridAI video.
  Resolve VERIFY comments before filming: a shot whose gate did not pass is cut or replaced with
  the fallback listed for it.
-->

**Rules from the contest:** public YouTube video, **3:00 or shorter**, in English, showing the
project working on each platform we select. The cut below runs **2:45**, leaving 15 seconds so a
slow take doesn't push it over.

**Rules from us:**
- Film the **judged build** (the hosted URL at the frozen tag, `DINNER_MODE=simulated`), not
  Rehearsal mode. If a shot uses Rehearsal mode, the on-screen *Simulated* label must be visible
  and the narration says so.
- Show only what passed its gate on that device (DESIGN.md §8). Never narrate "on-device" over
  a shot whose badge says *Cloud*.
- **Wording.** The ledger covers **AI requests** only; the cooking session itself is saved to
  Firestore, so never say "nothing left your kitchen" or that the counter "stays on your
  device". The Live coach, if shown, is a **continuous cloud camera and microphone stream** the
  cook starts, and is narrated that way. Never show or say "Gemini Nano 4".
- **Food safety.** The app suggests a timer only when the recipe step has one. Any heated step
  that appears on screen keeps the app's "the camera can't confirm doneness" wording visible.
  (This recipe has no heated step.)
- Nothing personal or secret on screen: no phone numbers, Firebase console, DevTools request
  headers, tokens, email, notifications, browser profile name or bookmarks bar. Use a clean
  Chrome profile.
- No third-party logos. If any reference photo from `assets/reference-cooking/` appears, credit
  it in the YouTube description (author, title, link, license; see `docs/validation/reference-images.md`).
- Captions on (YouTube auto-captions, corrected), so the badges and narration read without sound.
  The title cards below are written to carry the story on mute.

## Devices

| Label | Device | Used for |
|---|---|---|
| **D1** | Terry's desktop Chrome, on-device model downloaded, multimodal flag on, webcam on a stand over the counter | Every main shot (G2b, G2c passed here) |
| **D2** | Pixel 9, signed release APK | Montage only, and only if G4 passed <!-- VERIFY: gate G4. The Pixel 9 reports Gemini Nano 4 (PREVIEW) unavailable / not_enrolled; do not show or say "Nano 4" --> |
| **D3** | iPhone with Apple Intelligence on | Montage only, and only if G5 passed <!-- VERIFY: gate G5 --> |
| **Screen capture** | OBS or QuickTime on D1, 1080p, cursor highlighted | All D1 shots |
| **Phone camera** | Second phone on a tripod | Wide shots of the counter and the hand-over-the-bowl moment |

**Props:** a plain paper bag (no logos), a can of chickpeas (drained before filming), mayonnaise,
a lemon, celery, a red onion (sliced), tortillas, a small cup, a bowl and a fork or masher.

## Story in one line per beat

1. **Hook (0:00–0:12):** real hands, a pantry bag, a counter. Not a tech demo.
2. **On-device while online (0:12–0:34):** the typed scan runs on Chrome's Gemini Nano with
   Wi-Fi connected, and the badge is the SDK's report.
3. **Cook in the loop (0:34–0:50):** confirm items and allergies; start the recipe's real
   5-minute onion timer.
4. **Asks instead of guessing (0:50–1:18):** a camera-only watch while the onion pickles.
5. **The hybrid turn (1:18–2:14):** Wi-Fi off, Coach Lite still answers; the ledger shows those
   AI requests stayed on the device; Wi-Fi on, one cloud question earns its keep.
6. **One policy, warm close (2:14–2:45):** the bridge and the keep-on-device switches, then a
   rolled wrap and a simulated dinner text.

## Shot list

| Time | Beat | On screen | Device | Card |
|---|---|---|---|---|
| 0:00–0:12 | **Hook** | Wide shot of the counter: hands unpack the paper bag (chickpeas, lemon, celery, red onion, mayonnaise, tortillas) next to a bowl, with the laptop propped beside it. | Phone camera | 1 |
| 0:12–0:34 | **Scan, on-device, while online** | Wi-Fi icon visibly **connected**. Type `canned chickpeas, mayonnaise, lemon, celery, red onion, tortillas`, tap **Find my meal**. Items appear. Zoom on the badge: **On this device · Gemini Nano**. | D1 | 2 |
| 0:34–0:50 | **Cook in the loop, start the onion** | Tap to confirm items, open *Smashed Chickpea Salad Wrap*, answer the allergy check. Step 1, *Quick-pickle the onion*: onion into the cup with lemon and salt (counter cutaway), tap **Start 5-minute timer**, then **Next step →**. The timer keeps running. | D1 + phone camera cutaway | — |
| 0:50–1:18 | **Private watch: asks instead of guessing** | Live coach **off** (otherwise *Watch my food* uses Live's cloud watch). On *Mash the chickpeas*, tap **Watch my food**. Camera opens with **no microphone prompt**; status shows the on-device watch. Mash. Hold a hand flat over the bowl: the app says it's unsure and asks for a better view. Move the hand; the next check updates (*not yet* or *ready*). Onion timer still counting in the corner. | D1 + 3 s phone camera cutaway | 3 |
| 1:18–1:40 | **Wi-Fi off, Coach Lite still answers** | Click Wi-Fi **off** in the macOS menu bar. Status shows offline. Type "How smooth should this be?" Coach Lite's panel appears with an **On this device** badge. Target answer, from the step's own cue: *"Chunky, like tuna salad — a few whole chickpeas are fine."* No timer suggestion: this step has none. The onion timer is still ticking. | D1 | 4 |
| 1:40–1:54 | **Ledger: these AI requests stayed on the device** | Tap **What was sent**. Sheet *What left this device*: *Stayed on this device* lists the scan, the watch checks and Coach Lite; *Reported as sent*: "Nothing was reported as sent."; *May have been sent* empty. Hold 2 s on *What this session keeps*. | D1 | — |
| 1:54–2:14 | **Wi-Fi on: cloud only when it earns it** | Wi-Fi **on**. Tap **Research a cooking question**, ask "Can I use Greek yogurt instead of mayo?" The answer arrives with sources and Google Search suggestions; badge **Cloud · Gemini**. Flash **What was sent**: one new row under *Reported as sent*. | D1 | 5 |
| 2:14–2:30 | **One bridge, one policy** | D1: the *On-device AI* sheet with text and photo readiness and the **Keep on this device** switches; flip one. Optional 3 s inserts: the same scan on D2 with its badge; a Coach Lite answer on D3 with its badge. | D1; D2, D3 only if gated in | — |
| 2:30–2:45 | **Dinner's ready, close** | Hands roll the filling into a tortilla and cut it (2:30–2:34). D1 meal-complete screen: tap **Text the household: dinner is ready**; review sheet shows **Simulated — no SMS sent.** (2:34–2:38). End card (2:38–2:45). | Phone camera → D1 → card | 6 |

Gate notes for the shots above:

- **0:12 scan:** <!-- VERIFY: G2c passed for the typed scan, which is what is scripted. Film a photo scan only if the on-device photo scan passes in the production path first --> Default to the typed scan.
- **0:50 watch:** <!-- VERIFY: SS-075 evidence and a rehearsed take on the hosted build; G2b covered the obscured frame in the gate harness only --> Never edit a verdict in post. If the covered bowl returns *ready*, retake and log the miss for SS-075.
- **1:18 offline:** <!-- VERIFY: SS-072 scope; offline Coach Lite answer inside an already-open session on the hosted build --> The model's wording will vary. Keep a take whose answer matches the step's cue (chunky, a few whole chickpeas, not a paste). If an answer offers a timer or describes a different texture, don't use it: retake and note it against Coach Lite's prompt.
- **1:40 ledger:** if any row appears under *May have been sent* or *Reported as sent*, keep it in shot and don't narrate "every AI request stayed on this device".
- **1:54 cloud:** <!-- VERIFY: gate G1 approved the research route. Alternative if G1 did not approve research but G3 passed: tap Start (tooltip "Cook with me") for a 20 s Live coach exchange through Firebase AI Logic, narrated as a continuous cloud camera and microphone stream the cook started, not as a per-frame or on-device feature; re-record that voice-over line -->
- **2:14 bridge:** <!-- VERIFY: gates G4 and G5 for the D2/D3 inserts; cut each platform that did not pass. Optional insert of an automatic cloud fallback on a Chrome profile with no local model only if gate G2 passed --> If neither phone passed, film D1 only.
- **2:38 end card:** <!-- VERIFY: frozen <HOSTED_URL> and <FINAL_TAG> -->

## Voice-over

About 370 words, read at a relaxed pace (~150 words a minute). Each paragraph is one shot.

> **0:00** A food pantry hands you chickpeas, a lemon and tortillas. Getting the food is half of dinner. Cooking it shouldn't take an unlimited data plan, or streaming your kitchen to the cloud.
>
> **0:12** This is SousSight. I type what's in the bag and tap Find my meal. Wi-Fi is on, and Firebase AI Logic still runs this on Chrome's built-in Gemini Nano. That badge, "On this device", isn't a setting. It's what the SDK reported.
>
> **0:34** I confirm my items, pick the chickpea wrap and answer the allergy check. Nothing counts until I tap it. Step one: the onion pickles for five minutes, so I start a real timer and move on.
>
> **0:50** While it runs, I tap Watch my food. Camera only: no microphone, no live stream. Each frame is checked on this laptop. When my hand blocks the bowl, it doesn't guess. It says it's unsure and asks for a better view. And it never calls food done or safe. That's my call.
>
> **1:18** Now the Wi-Fi drops, which in a lot of kitchens is just Tuesday. I ask anyway: how smooth should this be? Coach Lite answers on the device: chunky, like tuna salad, a few whole chickpeas are fine. My onion timer is still running.
>
> **1:40** What was sent? Scan, watch, coaching: every one of those AI requests ran on this device. And it's honest about the rest: my cooking session is saved, so I can pick it up later.
>
> **1:54** Wi-Fi back on. Some questions need the web. Can I use Greek yogurt instead of mayo? That one goes to Gemini in the cloud, grounded with Google Search, with sources I can open. The badge says Cloud, and the ledger has one new entry.
>
> **2:14** Flutter has no hybrid API, so we bridged Firebase AI Logic's web, Android and Apple SDKs behind one policy. The cloud is used only when the device can't do the job, this build allows it, and my switches say yes.
>
> **2:30** Wrap's rolled. Dinner's ready, and the household text is simulated for judging. SousSight watches your counter on your device, and the cloud only comes to dinner when it earns a seat.

Line-level gates: the 0:50 paragraph needs SS-075, the 1:18 paragraph needs SS-072, and the
1:54 paragraph needs G1 (see the gate notes above). The 2:14 paragraph describes the bridge as
built and the policy, and claims no device run. If D2 or D3 footage is used, add "running on
Android" or "and on iPhone" only for a platform whose gate passed. Quote Coach Lite's answer only
if the kept take says it in substance.

## Title cards

Six short cards, timed to the shot list, written to read on mute.

| # | Time | Placement | Primary | Secondary |
|---|---|---|---|---|
| 1 | 0:00–0:04 | Lower third over the counter wide shot | **SousSight: Counter Intelligence** | An AI sous-chef for pantry cooks |
| 2 | 0:28–0:32 | Callout beside the zoomed badge | **On this device · Gemini Nano** | Reported by Firebase AI Logic, not a setting |
| 3 | 1:04–1:08 | Beside the *unsure* verdict | **Unsure? It asks. It doesn't guess.** | Camera only · no mic · never calls food done or safe |
| 4 | 1:19–1:23 | Corner pill right after Wi-Fi goes off | **Wi-Fi off. Still cooking.** | On-device coaching when the signal drops |
| 5 | 2:00–2:04 | Callout as the badge reads *Cloud · Gemini* | **Cloud only when it earns it** | Grounded with Google Search · in the ledger |
| 6 | 2:38–2:45 | Full-frame end card | **SousSight: Counter Intelligence** | It watches your counter on your device. The cloud only comes to dinner when it earns a seat. · Built with Firebase AI Logic · `<HOSTED_URL>` · github.com/terryhh/SousSight |

Cards 3, 4 and 5 follow the gates of their shots (SS-075, SS-072, G1). Card 6 needs the frozen
URL. Don't put a card over the badge or the ledger text it's describing.

**YouTube description (first line):** SousSight is a hybrid AI cooking companion for pantry
cooks, built with Firebase AI Logic: scans, camera checks and offline step help run on the
device, and Gemini in the cloud is called only when it earns it. Try it: `<HOSTED_URL>` · Code:
https://github.com/terryhh/SousSight · #BuildHybridAI. Add photo credits below it if any
reference photo appears.

## If a shot fails on the day

- **The on-device model won't load on D1:** check `chrome://on-device-internals` and free disk
  space (22 GB). Don't film a cloud badge under on-device narration.
- **The watch gives a wrong verdict on camera:** keep it if it's *unsure*, which is the point
  of the beat. Retake if it says *ready* while the bowl is covered, and note the miss for the
  evidence report (SS-075). Never edit a verdict in post.
- **The onion timer runs out mid-take:** restart the take from step 1. Don't cut around a
  finished timer as if it were still running.
- **Research is slow:** cut the wait; don't speed up the clip so it looks instant.

## After filming

- [ ] Length ≤ 3:00 on YouTube's own player.
- [ ] Watched once by someone who didn't film it, checking: no personal data, no console, no
      tokens, no real phone numbers, no third-party logos, *Simulated* label visible on the
      dinner beat, no "nothing left your kitchen" or "stays on your device" wording.
- [ ] Every platform shown is a platform selected on Devpost, and every claim in the narration
      matches `SUBMISSION.md` after its VERIFY markers are resolved.
- [ ] Uploaded as **Public** (not Unlisted), English, captions corrected. Description includes the
      repo link, hosted URL and any photo credits.
