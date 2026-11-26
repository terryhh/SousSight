# Demo video script (≤ 3:00)

<!--
  Card SS-080 (#167). Shot list for the #BuildHybridAI video. Resolve VERIFY comments before
  filming: a shot whose gate did not pass is cut or replaced with the fallback listed for it.
-->

**Rules from the contest:** public YouTube video, **3:00 or shorter**, in English, showing the
project working on each platform we select. Aim for **2:50** so a slow cut doesn't push it over.

**Rules from us:**
- Film the **judged build** (the hosted URL at the frozen tag, `DINNER_MODE=simulated`), not
  Rehearsal mode. If a shot uses Rehearsal mode, the on-screen *Simulated* label must be visible
  and the narration says so.
- Show only what passed its gate on that device (DESIGN.md §8). Never narrate "on-device" over
  a shot whose badge says *Cloud*.
- Nothing personal or secret on screen: no phone numbers, Firebase console, DevTools request
  headers, tokens, email, notifications, browser profile name or bookmarks bar. Use a clean
  Chrome profile.
- No third-party logos. If any reference photo from `assets/reference-cooking/` appears, credit
  it in the YouTube description (author, title, link, license; see `docs/validation/reference-images.md`).
- Captions on (YouTube auto-captions, corrected), so the badges and narration read without sound.

## Devices

| Label | Device | Used for |
|---|---|---|
| **D1** | Terry's desktop Chrome, on-device model downloaded, multimodal flag on, webcam on a stand over the counter | Every main shot (G2b, G2c passed here) |
| **D2** | Pixel 9, signed release APK | Montage only, and only if G4 passed <!-- VERIFY: gate G4. The Pixel 9 reports Gemini Nano 4 (PREVIEW) unavailable / not_enrolled; do not show or say "Nano 4" --> |
| **D3** | iPhone with Apple Intelligence on | Montage only, and only if G5 passed <!-- VERIFY: gate G5 --> |
| **Screen capture** | OBS or QuickTime on D1, 1080p, cursor highlighted | All D1 shots |
| **Phone camera** | Second phone on a tripod | Wide shots of the counter and the hand-over-the-bowl moment |

**Props:** a can of chickpeas, mayonnaise, a lemon, celery, red onion, tortillas, a bowl and a
fork or masher. Chickpeas already drained so the mash happens on camera.

## Shot list

| Time | Beat | On screen | Device | Narration (voice-over) |
|---|---|---|---|---|
| 0:00–0:10 | **Hook** | Wide shot: a pantry bag on the counter, a laptop propped beside the bowl. Title card: *SousSight: Counter Intelligence*. | Phone camera | "Pantry cooks get the food. What they don't get is a sous-chef, or a data plan that can stream video to one. So we put the sous-chef on the device." |
| 0:10–0:35 | **Pantry scan, on-device** | Type the items (or hold up the can for a photo), tap **Find my meal**. Items appear; tap to confirm. Zoom on the badge: **On this device · Gemini Nano**. | D1 | "Type it or show it. Chrome's built-in Gemini Nano reads the list right here, through Firebase AI Logic's hybrid SDK. The badge isn't a setting. It's what the SDK reported." <!-- VERIFY: photo scan on-device in the production path; otherwise film the typed scan only (G2c) --> |
| 0:35–0:45 | **Pick the recipe** | Tap *Smashed Chickpea Salad Wrap*. Allergy question, then step 2, *Mash the chickpeas*. | D1 | "The cook confirms every item and every allergy answer. Nothing counts until they tap it." |
| 0:45–1:20 | **Private watch** | Live coach **off** (otherwise *Watch my food* uses Live's cloud watch). Tap **Watch my food**. Camera opens, **no microphone prompt**, status: on-device watch. Start mashing. Put a hand over the bowl: the app says it's unsure and asks for a better view. Move the hand; next verdict: *not yet, keep mashing* or *ready*. | D1 + phone camera cutaway | "The watch opens the camera only. No microphone, no live stream. Each frame is checked on this laptop against the step's cue. When I block the bowl, it doesn't guess. It asks for a better view. And it never tells you food is done or safe. That's still your call." <!-- VERIFY: SS-075 evidence and a rehearsed take on the hosted build; G2b covered the obscured frame in the harness only --> |
| 1:20–1:45 | **Connection drops, Coach Lite answers** | Turn off Wi-Fi on screen (macOS menu bar, or DevTools Offline). Status shows offline. Type "How smooth should this be?" Coach Lite's panel appears with an **On this device** badge and a timer suggestion; tap **Start timer**, the timer ticks. | D1 | "Now the Wi-Fi drops, which in a lot of kitchens is just Tuesday. I ask about the step anyway. Coach Lite answers on the device with a small panel from our trusted GenUI catalog. The model can suggest a timer, but only I can start it." <!-- VERIFY: SS-072 scope; offline Coach Lite answer on the hosted build --> |
| 1:45–2:00 | **Ledger: these AI requests stayed on the device** | Tap **What was sent**. Sheet *What left this device*: *Stayed on this device* lists the scan, watch checks and Coach Lite; *Reported as sent*: "Nothing was reported as sent."; *May have been sent* absent or empty. Hold on the *What this session keeps* note for a beat. | D1 | "The ledger is written as each AI request goes out. Scan, watch, coaching: every one of those AI requests ran on this device. And it's honest about the rest: your cooking session is saved so you can pick it up later, and it says so." <!-- Don't say "nothing left your kitchen": the session itself is saved to Firestore. If a row appears under May have been sent, keep it in shot and don't narrate "all on this device" --> |
| 2:00–2:20 | **One cloud moment that earns it** | Wi-Fi back on. Tap **Research a cooking question** and ask "Can I use Greek yogurt instead of mayo?" Grounded research answers with sources and Google Search suggestions. Badge **Cloud · Gemini**; ledger shows one new row under *Reported as sent*. | D1 | "Some questions need the web. A substitution check goes to Gemini in the cloud, grounded with Google Search, with sources you can open. It's in the ledger too." <!-- VERIFY: gate G1 approved the research route. Alternative if G3 passed: tap Start (tooltip "Cook with me") for a 20 s Live coach exchange through Firebase AI Logic, narrated as a continuous cloud camera and microphone stream the cook started, not as a per-frame or on-device feature --> |
| 2:20–2:40 | **Multi-platform montage** | Split screen or quick cuts: the same scan on D2 with its badge; a Coach Lite answer on D3 with its badge; D1's *On-device AI* sheet with the keep-on-device switches. | D2, D3, D1 | "Same Flutter app, same rules on Android with Gemini Nano through AICore, and on iPhone with Apple's Foundation Models. One policy decides what may leave the device, everywhere." <!-- VERIFY: gates G4 and G5. Cut each platform that did not pass, and its words; if both fail, use D1 shots of the readiness panel and the keep-on-device switches --> |
| 2:40–2:50 | **Close** | Roll the wrap. On the meal-complete screen tap **Text the household: dinner is ready**: review sheet, *Simulated — no SMS sent.* visible. End card: tagline, hosted URL, repo URL, "Built with Firebase AI Logic". | Phone camera + D1 | "Dinner's ready. The text is simulated for judging. SousSight: it watches your counter on your device, and calls the cloud only when it earns it." |

Running time: **2:50**, leaving 10 seconds of margin.

## If a shot fails on the day

- **The on-device model won't load on D1:** check `chrome://on-device-internals` and free disk
  space (22 GB). Don't film a cloud badge under on-device narration.
- **The watch gives a wrong verdict on camera:** keep it if it's *unsure*, which is the point
  of the beat. Retake if it says *ready* while the bowl is covered, and note the miss for the
  evidence report (SS-075). Never edit a verdict in post.
- **Research is slow:** cut the wait; don't speed up the clip so it looks instant.

## After filming

- [ ] Length ≤ 3:00 on YouTube's own player.
- [ ] Watched once by someone who didn't film it, checking: no personal data, no console, no
      tokens, no real phone numbers, no third-party logos, *Simulated* label visible on the
      dinner beat.
- [ ] Every platform shown is a platform selected on Devpost, and every claim in the narration
      matches `SUBMISSION.md` after its VERIFY markers are resolved.
- [ ] Uploaded as **Public** (not Unlisted), English, captions corrected. Description includes the
      repo link, hosted URL and any photo credits.
