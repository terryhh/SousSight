# Demo script and shot list

Target length is about 3 minutes, with a timer insert. Each beat has a spoken line, a shot, the capability it shows, and the disclosure to use if it is not live. Before recording, check each beat's status in [README.md](README.md#evidence-status-by-segment).

Shot codes:
- **S** is a screen capture of the app.
- **H** is an over-the-shoulder shot of the hands and the device.
- **C** is the cook on camera. It is optional; keep any bystanders out of it.

| # | Shot | Cook says / does | On screen | Capability | If not live, say |
|---|---|---|---|---|---|
| 0 | C or title card | "I just picked this up from the campus pantry. Let's turn it into lunch." | Title: SousSight | — | — |
| 1 | H → S | Holds the phone over the row of items and taps **Scan**. Then taps only the correct candidates, and stays on the pantry screen. | Candidate items, ranked meals with matched and missing items | Gemini Flash multimodal structured output (Firebase AI Logic), GenUI | "This scan is from the rehearsal build. The items are simulated." |
| 1b | S | Taps **Find food help nearby**, types `Orlando, FL` and taps **Search**. Closes the sheet. | Nearby pantries and stores with Google Maps links | Grounding with Google Maps | "Rehearsal: no Maps search was run." (The app shows this text itself) |
| 2 | S + H | Picks **Peanut Butter Sandwich** and presses **Start**. "Help me make a peanut butter sandwich." | Coach greets; a generated step panel appears | Gemini Live voice and vision, GenUI/A2UI | — (Live, SS-002/SS-003) |
| 3 | S | The coach asks about peanut and wheat allergies. The cook answers: "No allergies here." | Cook-question panel, then the confirmed answer | `ask_cook`: the cook is the human in the loop | "The allergy prompt here is from rehearsal." |
| 4 | S | Coach: "Smooth or chunky? Jam?" Cook: "Smooth, no jam." | The answer shows as confirmed; the workspace recomposes | Targeted clarification | — (Live, SS-003) |
| 5 | S | "Can I use sunflower seed butter instead?" | Grounded answer with source links and Google search suggestions | Grounding with Google Search | "Research was unavailable in this take." Never read out an answer without sources |
| 6 | H + S | Spreads on camera. "Am I doing this right?" Optionally: "Watch until it's spread to the edges." | Comparison panel describing visible coverage; watch status if requested | Live vision, opt-in watch | "The camera describes what it sees. It can't tell if food is safe." |
| 7 | S | Optional, one exchange: "¿Cómo cierro el sándwich?" | The coach answers in Spanish | Gemini Live native multilingual audio | Skip the beat if it has not been checked |
| 8 | S | **Text household: started cooking** → enter the allowlisted test recipient off camera → review → **Simulate delivery (demo)** | "Delivered ✓ (simulated)" | Vonage Messages API and signed status webhook | Say: "Simulated delivery. No SMS was sent." |
| 9 | S | **Dinner is ready** → confirm the recipient is filled in (off camera) → review the text → **Simulate failed delivery (demo)** | "Simulated failure: Illegal Sender Address (1120)" and recovery options | Vonage failure handling (challenge requirement) | Say: "This is the real error we hit in setup, replayed as a simulation." |
| 10 | S + H | Closes the sandwich and finishes the last step. | "You made Peanut Butter Sandwich!", confirmed pantry items, coach paused | Meal-complete moment, cost guardrail | — |
| 11 | S | **Timer insert, separate take**: salsa, meld step. Start the timer, reload, and show the countdown continuing. | A real countdown that survives reload | App-owned timers with absolute deadlines | — (Live, SS-006) |
| 12 | S | **How it works → Under the hood**, or the README architecture diagram | Routing and storage | Devs track | — |
| 13 | C or end card | "No account, no sign-up. Point your camera at what you've got and start cooking." | App URL and repository URL | — | — |

## Lines that must stay accurate

- Do not say "it texted my family" unless a **delivered** status was recorded for that take. "Vonage accepted it" means submitted, not delivered.
- Do not say the camera checked allergens, doneness, freshness or safety.
- Do not quote cost savings, numbers of households helped, or other impact figures. None have been measured.
- If a take mixes live and simulated beats, put a caption on each simulated beat ("Simulated", "Rehearsal build" or "Recorded earlier"), not only on the end card.
- Credit "Gemini Live API", "Gemini Flash via Firebase AI Logic", "Grounding with Google Search", "Grounding with Google Maps", "Flutter GenUI / A2UI" and "Vonage Messages API". Do not cite model version numbers on screen. They are configurable and may change.

## B-roll and stills to capture

- [ ] The pantry haul on the counter, before the scan
- [ ] Hands spreading peanut butter, in close-up
- [ ] The phone on its stand, showing the app with the coach panel
- [ ] The finished sandwich on the plate
- [ ] The salsa bowl with the timer running on the phone
- [ ] Redacted screenshot of the dinner-review dialog (no recipient number visible)
