# Pantry-to-plate demo runbook

A repeatable runbook so any cook can rerun the SousSight story. Main recipe: **Peanut Butter Sandwich** (`peanut_butter_sandwich_v1`). Timer segment: **Black Bean & Corn Salsa** (`black_bean_corn_salsa_v1`), which has a real meld wait. No heat or stove is needed for either one.

Status labels for each segment are in [README.md](README.md#evidence-status-by-segment). This runbook describes what to do. It does not record that anything passed.

## 1. Ingredients and props

**Sandwich (main story)**
- 2 slices of bread (contains wheat)
- Peanut butter, smooth or chunky (contains peanut)
- Jam, optional; the cook decides on camera
- Plate and a butter knife or spreader

**Pantry haul for the scan beat.** Keep the labels facing the camera:
- The bread and peanut butter above
- 1 can black beans, 1 can corn, 1 tomato

**Salsa (timer segment only)**
- Black beans and corn (the cans above), tomato, 1/4 red onion, 1 lime, salt; cilantro is optional
- Can opener, colander, cutting board, knife, medium bowl, spoon
- Tortilla chips or tortillas for serving (flour tortillas contain wheat)

**Allergy note.** The sandwich contains peanut and wheat. Everyone present at the recording must be safe around peanut. If anyone is not, run the story with sunflower seed butter and say so. Never imply that the camera checked for allergens.

## 2. Physical setup

- **Device:** Android phone in Chrome, or a desktop with Chrome, opened over HTTPS at https://devfest-flutter-a59e8.web.app. These are the MVP targets. There is no APK.
- **Phone stand** angled down at the counter, about 45°, 40–60 cm above the plate.
- **Lighting:** even light from the front or side, with no strong window glare behind the plate. Use a plain, light-colored counter or cutting board.
- **Audio:** headset mic, or a quiet room. Mute notifications on the device.
- **Second device for recording** (screen recording or a camera over the shoulder) if the cooking device is recording its own screen. See [recording-checklist.md](recording-checklist.md).

## 3. Camera framing

- Frame the plate and the cook's hands only. Keep faces, other people, screens, mail, phone numbers and anything with an address out of the frame.
- Fill about two thirds of the frame with the plate, so spread coverage and edges are visible.
- For the pantry scan, line the items up in a single row with labels facing the camera, then hold the phone steady for about 2 seconds.
- For the salsa, show the bowl from above, so the dice size and color spread are visible.

## 4. Permissions and app state

1. Before the take, open the app once and allow **camera** and **microphone** for the site in Chrome. Note it if Chrome remembers the choice for the session only.
2. Confirm the header shows real mode. If it shows **Rehearsal**, that take is a rehearsal and must be labelled as one.
3. Confirm the selected recipe title says **Peanut Butter Sandwich**.
4. Keep the app tab in the foreground. A hidden tab stops capture. Slides go in a separate window.
5. Leave at least 3 seconds between **Stop** and **Start**.

## 5. Test-recipient prerequisites (Vonage)

### 5a. Simulated outcomes (beats 8–9, no SMS)

The simulate buttons never contact Vonage, but the server still validates the request first, in this order (`functions/src/dinner-ready.js`):

- [ ] **A demo recipient is entered in the review dialog.** A **New cook** starts with the field blank, and the app rejects the tap until it holds a full international number (`+` and 8–15 digits).
- [ ] That number is already in the server allowlist secret `VONAGE_ALLOWED_TO`. Otherwise the server answers `recipient-not-allowed`, even for a simulation. Use the existing verified test number. Terry gives it to the cook off-camera; never write it in GitHub or show it on screen.
- [ ] The dinner channel is configured (SMS or WhatsApp). Otherwise the server answers `not-configured`.
- [ ] `ALLOW_DELIVERY_SIMULATION=true` is set on the GitHub `production` environment and deployed. Otherwise the buttons are hidden or the server answers `simulation-disabled`.
- [ ] Leave `ENABLE_DINNER_MESSAGES=false`. Simulations do not need it, and with it off, an accidental tap on **Confirm and send** is recorded as a dry run and sends nothing.

Entering the recipient does **not** authorize a real send. Tap only the **Simulate … (demo)** buttons, and keep the "No SMS was sent" disclosure.

### 5b. Real SMS (not planned)

- [ ] Fresh, explicit approval from Terry of the exact recipient and message text, given in the chat or on the card. An earlier approval does not carry over.
- [ ] The recipient is a Vonage-verified test number on the trial account, and is in the server allowlist secret `VONAGE_ALLOWED_TO`. Without it, the server answers `recipient-not-allowed`.
- [ ] `VONAGE_FROM` is the numeric sender (Secret Manager version 3, see [SS-021 #39](https://github.com/terryhh/SousSight/issues/39)).
- [ ] `ENABLE_DINNER_MESSAGES` is switched on only for that one send, then back to `false`, and read back.
- [ ] Use a fresh cooking session (**New cook**), because each session's dinner notification is claimed once.
- [ ] For the simulated outcomes: `ALLOW_DELIVERY_SIMULATION=true` is set on the GitHub `production` environment and deployed.
- [ ] Record the outcome on the card. If the provider accepts the message, that is not delivery: only a delivered status counts. Never record the phone number in GitHub.

## 6. The run (about 4 minutes)

The script with spoken lines is in [script-and-shots.md](script-and-shots.md). In short:

1. **Scan the haul.** Confirm only the items the scan got right. Don't pick a meal yet.
2. While still on the pantry screen, tap **Find food help nearby**, type **Orlando, FL**, and tap **Search**. Show the Maps links, close the sheet, then pick **Peanut Butter Sandwich**. The nearby action is only on the pantry screen.
3. Press **Start**. Answer the coach's allergy check.
4. Answer one targeted question, for example "smooth, no jam". Check that the answer shows as confirmed.
5. Ask "Can I use sunflower seed butter instead?" Show the sources.
6. Spread on camera and ask "Am I doing this right?" Optionally: "Watch until it's spread to the edges."
7. Optionally, have one exchange in Spanish.
8. **Text household: started cooking**. A fresh cook starts with a blank recipient, and the dialog validates it even for simulations. Enter the team's allowlisted test recipient **off camera** (or blur it in the recording; never show or commit the number). Then tap **Simulate delivery (demo)**. Simulation never sends an SMS, and the screen says "Simulated — no SMS sent." Do not tap the real send. Server prerequisites are in [§5a](#5a-simulated-outcomes-beats-89-no-sms).
9. **Dinner is ready**: check that the recipient is still filled in (enter it off camera again if not), review, then tap **Simulate failed delivery (demo)**. Show the recovery options. Again, no real send.
10. Finish the last step to show the meal-complete screen. Press **Stop** and check that the camera and mic are off.
11. **Timer segment, separate take:** open `?recipe=black_bean_corn_salsa_v1` and reach the meld step. Start the real timer, show it counting down, and reload to show that it persists.

## 7. Reset and retry

| Situation | Do this |
|---|---|
| Between full takes | **New cook** → **Start new cook**. Older sessions are kept. Check that step 1 and an empty checklist come back |
| You want a completely separate identity | Use a new Chrome profile. A new private tab can share the old private identity |
| Coach is silent or the connection drops | Press **Stop**, wait 3 seconds, then press **Start**. If it fails twice, record which capability was unavailable and continue with the next beat. Do not fake the reply |
| Scan finds nothing or the wrong items | Type the items instead. Typed input is a supported path; say "typed" in the take |
| Research has no sources or fails | Say that research is unavailable. Do not read out an answer without sources |
| Simulation buttons are missing | `ALLOW_DELIVERY_SIMULATION` is not deployed. Skip beats 8–9 or use the labelled rehearsal build, and say so |
| "Enter a full international phone number" | The recipient field is blank or malformed. Enter the allowlisted demo number off-camera |
| `recipient-not-allowed` on a simulation | The number is not in `VONAGE_ALLOWED_TO`. Use the configured test number; do not add a new one mid-take |
| A beat 8 or 9 attempt already ran in this cook | Each message kind is claimed once per session. Start a **New cook** to repeat it |
| A real SMS is not delivered | Do not retry automatically. Record the status and the Vonage reason |
| Venue or network failure | Switch to the rehearsal build (`FAKE_BACKEND=true`, labelled **Rehearsal** in the UI) or the backup recording, and say on camera that it is simulated or recorded |
| Leftover state after the take | **Stop**. Close the tab. Revoke the camera and mic grant in Chrome site settings if the device is shared |

Do not delete cooking sessions or Firestore data to reset. **New cook** is the supported reset.
