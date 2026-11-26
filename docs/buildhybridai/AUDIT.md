# Prior-work, media and branding audit

> Card SS-078 (#165). Compiled 2026-11-25 against `origin/main` at `dd0f90c`. That commit equals the
> baseline `430747b` plus `docs/buildhybridai/PLAN.md`, `DESIGN.md` and an `AGENTS.md` section
> (`git diff --stat 430747b dd0f90c`).
> **Evidence level:** repository reading and `git` only. No console, live service or device was
> checked. Every "confirm" item below is still open.
> Secrets and personal data are reported by path only, never by value.

## (a) Inherited features and new work

**Baseline.** Commit `430747b` (2026-11-10 01:20 EST, merge of PR #131) is the last commit before
the submission period opened on November 11. The repository started on 2026-11-07, and the
project took 3rd place at DevFest Florida on November 8. PLAN §6 tags this commit as
`pre-buildhybridai` and cuts a release from it. As of this audit, no tag exists in the
repository (`git tag --list` is empty).

### Inherited (built November 7–10, before November 11)

All of the following exist at `430747b`. All of it is cloud inference.

| Feature | Main files |
|---|---|
| Pantry scan from a photo, a voice clip or typed text; one structured Gemini Flash call through Firebase AI Logic | `lib/pantry/pantry_client.dart`, `pantry_models.dart`, `pantry_screen.dart`, `pantry_ui.dart`, `pantry_flow.dart`, `wav.dart` |
| AI recipe draft from cook-confirmed items, with safety rules applied in code | `lib/pantry/recipe_draft_client.dart`, `recipe_draft.dart`, `lib/learner/draft_recipe_chip.dart` |
| Three reviewed recipes | `assets/recipes/*.json`, `lib/pantry/recipe_catalog.dart` |
| Gemini Live coach: camera, microphone, spoken replies, tool calls, resumption | `lib/live/*`, `web/soussight_live.js` |
| Ephemeral-token Live transport and its token function | `lib/live/ephemeral_live_transport.dart`, `lib/data/live_token_provider.dart`, `functions/src/live-token.js`, `token-quota.js` |
| `FirebaseLiveTransport`, an adapter that is not selected by any real build | `lib/live/firebase_live_transport.dart` |
| GenUI / A2UI trusted cooking catalog and validator | `lib/genui/*` |
| Cooking screen, coordinator, real timers, opt-in visible-change watches | `lib/learner/cooking_app.dart`, `cooking_coordinator.dart` |
| Allergy-first check and allergen chip | `lib/learner/allergen_chip.dart`, `recipe_allergens.dart` |
| Google Search–grounded research and the research panel (Jenna's) | `lib/ai/cooking_research_client.dart`, `lib/research/**`, `lib/learner/research_panel_client.dart` |
| Nearby food help with Grounding with Google Maps | `lib/nearby/*` |
| Reviewed dinner-ready text, signed delivery-status webhook, simulated outcomes | `lib/learner/dinner_review.dart`, `lib/data/dinner_messages.dart`, `dinner_status.dart`, `functions/src/dinner-ready.js`, `vonage-status.js` |
| Meal-complete moment | `lib/learner/meal_complete.dart` |
| "How it works" sheet | `lib/app/how_it_works.dart` |
| Rehearsal mode (`FAKE_BACKEND`) | `lib/core/fakes.dart`, `lib/learner/demo_live.dart` |
| Anonymous Auth, App Check (web only), Firestore repositories and rules | `lib/data/firebase_services.dart`, `firestore_repositories.dart`, `firestore.rules`, `test/rules/` |
| GA4 analytics counts | `lib/core/analytics.dart`, `lib/data/firebase_analytics_sink.dart` |
| CI/CD with gitleaks scanning and auto-deploy | `.github/workflows/`, `.gitleaks.toml` |
| Reference photo fixtures (Jenna, SS-022) | `assets/reference-cooking/**`, `docs/validation/reference-images.md` |
| DevFest-era documents | `docs/devpost/SUBMISSION.md`, `docs/demo/**`, `docs/handoffs/**`, `docs/validation/cook-acceptance*` |

### New work (November 25 onward, for #BuildHybridAI 2026)

At the time of this audit, the only new work on `main` is documentation: `docs/buildhybridai/PLAN.md`,
`DESIGN.md`, the `AGENTS.md` section, and this PR. Everything else is in progress on
`buildhybridai` branches and in PRs (DESIGN §9). Nothing in that list has been run against a live
model or on a device yet.

| Card | New work |
|---|---|
| SS-061 | Hybrid bridge contract and fake (`packages/ai_logic_hybrid`), plus the app-side dispatcher types (`lib/ai/hybrid/`) |
| SS-062 / 063 / 064 | Web, Android and iOS bridge backends |
| SS-083 | Gate harness (`lib/main_hybrid_gate.dart`) and integration |
| SS-065, SS-066 | Hybrid pantry scan; recipe draft that only requires confirmed ingredients |
| SS-067 | Local watch: a camera-only on-device loop |
| SS-068 | Coach Lite |
| SS-069 | Label check |
| SS-070, SS-071 | Trust surface (source badges, ledger) and first-run states |
| SS-072 | Offline support for an already-open session |
| SS-073, SS-074 | Native runtime; Live through Firebase AI Logic |
| SS-075 | Evidence |
| SS-076, SS-077, SS-079 | Remote Config, device TTS, CI |
| SS-084 | Judge-safe simulated dinner mode |
| SS-078, SS-080 | Reframe, this audit, submission and release docs |

**For SS-080.** The submission's "Built during the submission period" list should name only items
that merged after `430747b` and passed their gate. The rewritten `README.md` and `docs/SPEC.md` are
the reframing of inherited documents. They are not new features.

## (b) Third-party media and licenses

Source: `assets/reference-cooking/fixtures.json` and `docs/validation/reference-images.md`. Both
are Jenna's (SS-022) and were read, not changed. All eight files are photographs downscaled to
768 px. The images contain no people or faces.

| File | Photographer | Source | License |
|---|---|---|---|
| `cp_mash_target_coarse.jpg` | phil_g | flickr.com/photos/68975104@N00/27978676 | CC BY-SA 2.0 |
| `cp_mash_obscured_rim_angle.jpg` | phil_g | flickr.com/photos/68975104@N00/27978405 | CC BY-SA 2.0 |
| `cp_mash_diff_whole_unmashed.jpg` | PersonalCreations.com | flickr.com/photos/127294011@N07/16272507722 | CC BY 2.0 |
| `cp_mash_diff_smooth_paste.jpg` | Dennis S. Hurd | flickr.com/photos/43296902@N00/4784294128 | CC0 1.0 |
| `cp_mix_target_folded_salad.jpg` | Vegan Feast Catering | flickr.com/photos/25128194@N02/3986173540 | CC BY 2.0 |
| `cp_mix_diff_unfolded_toppings.jpg` | Stacy Spensley | flickr.com/photos/21001756@N06/4384433772 | CC BY 2.0 |
| `cp_mix_obscured_blur_defocus.jpg` | Stacy Spensley | flickr.com/photos/21001756@N06/4384432428 | CC BY 2.0 |
| `cp_mix_diff_pooled_dressing.jpg` | jules:stonesoup (Jules Clancy) | flickr.com/photos/58367355@N00/22469785778 | CC BY 2.0 |

What this means:
- **Not shipped in the app.** `pubspec.yaml` declares only `assets/recipes/` and
  `assets/recipes/chickpea_wrap_v1/`. These photos stay in the repository and are not in the web
  build. `assets/recipes/chickpea_wrap_v1/target_*.jpg` are 857-byte placeholders, not these
  photos.
- **Attribution.** CC BY and CC BY-SA require title, author, source and license wherever the
  photos are reproduced. `reference-images.md` covers this inside the repository.
  - **If any photo appears in the demo video, slides or Devpost gallery** (SS-075, SS-080),
    credit it on screen or in the description with author, title, link and license.
  - **CC BY-SA 2.0 (the two phil_g photos):** an adapted version, such as a crop with
    annotations, must be shared under CC BY-SA. An unmodified frame shown in a video only needs
    attribution.
  - **Evidence results** that publish these images (SS-075, `docs/buildhybridai/EVIDENCE.md`)
    should link `reference-images.md` for credits.
- **The CC licenses are separate from AGPL-3.0.** The photos are not covered by the code license.
  The README says so.
- **App icons are the default Flutter logo.** `web/favicon.png`, `web/icons/*.png`,
  `android/app/src/main/res/mipmap-*/ic_launcher.png` and
  `ios/Runner/Assets.xcassets/AppIcon.appiconset/*` are the unchanged Flutter template icons
  (added in `400dab6`). The Flutter logo is a Google trademark, so these are third-party branding.
  `TRADEMARKS.md` also claims a "SousSight logo and icon" that the repository doesn't contain.
  - **Recommendation for the integration owner:** replace them with an original SousSight icon
    before the judged build (`web/` and `android/app/` are shared or integration-owned), or
    remove the icon claim from `TRADEMARKS.md`.
- **No other images, fonts, audio or video files are in the repository.** The app uses Material
  Icons and Cupertino Icons from the Flutter SDK, which come with their licenses through Flutter's
  `LicenseRegistry`.
  - **Open question:** the app has no `showLicensePage` entry. Add one if the integration owner
    wants package notices visible in the app.
- **Text links only, no logos.** The README and SPEC link UCF pages for context. SPEC states they
  are not partnerships.

## (c) Required attributions

| Surface | Requirement | Where it's handled | Status |
|---|---|---|---|
| Grounding with Google Search: research answers | Show grounded results only with their Search Suggestions. Don't modify them or intersperse other content, and put nothing between a suggestion and its destination ([Gemini API Additional Terms](https://aistudio.google.com/docs/terms), "Grounding with Google Search", read 2026-11-25). | `lib/research/search_suggestions_web.dart:18-55` renders the provider's `searchEntryPoint.renderedContent`, unchanged, in a sandboxed `srcdoc` iframe (`allow-popups allow-popups-to-escape-sandbox`, no scripts, `no-referrer`). Sources come from grounding metadata (`lib/ai/cooking_research_client.dart:101`). | Web: implemented. Confirm three things on the hosted build: tapping a suggestion chip opens Google Search in a new tab; the 160 px frame shows the whole chip row; the light and dark styling renders without scripts. The Terms also forbid "framing" Search Suggestions. Whether a sandboxed `srcdoc` iframe of the provider HTML counts as framing is a question for Terry. |
| Same, on Android and iOS | Same as above | `lib/research/search_suggestions_stub.dart:33-35` shows "Open SousSight on the web to view Google Search suggestions." instead of the suggestions. | **Gap for native builds.** If grounded research ships on Android or iOS (SS-073, SS-074), the suggestions must be rendered there too, for example in a WebView, or research must stay web-only. `lib/research/**` is Jenna's, so coordinate through her card. |
| Grounding with Google Maps: nearby food help | "Sources: Google Maps" next to the results, with the text unmodified, plus Maps links for each place | `lib/nearby/nearby_sheet.dart:330-480` (`GoogleMapsAttribution`, per-place "open in Google Maps" links) | Implemented. No change needed. |
| CC BY / CC BY-SA photos | Credit (see b) | `docs/validation/reference-images.md` | Needs doing in video and slides if the photos are shown. |
| Hybrid bridge | Describe it as unofficial; don't imply Google endorsement | PLAN §3, DESIGN §2 | SS-061 / SS-080 should keep "unofficial" in the plugin README and in the submission. |

## (d) Firebase client configuration

Files: `lib/firebase_options.dart` (web and Android options) and
`android/app/google-services.json` (Android). Both contain a Google API key (`AIza…`), app IDs,
the project number, project ID `devfest-flutter-a59e8`, the storage bucket and the GA4
measurement ID.

**These are public client identifiers, not secrets.** Firebase's documentation says API keys for
Firebase services only identify the project and app, and "API keys restricted to Firebase
services do not need to be treated as secrets"
([Firebase API keys](https://firebase.google.com/docs/projects/api-keys), read 2026-11-25). Every
Firebase web app ships this configuration to the browser, so removing it from Git would protect
nothing. Access is controlled by Auth, Firestore rules, App Check and server-side checks. The web
and Android options use two different keys. The Android key in `firebase_options.dart` matches
`google-services.json`.

`.gitleaks.toml` allowlists these exact key values, and only in these two files, so the same
keys anywhere else are still caught. If a key is rotated, update `.gitleaks.toml` too.

**Confirm in the console (Terry or the integration owner; nothing here was checked):**

1. **API restrictions on both keys.** The allowlist must include the Firebase AI Logic API
   (`firebasevertexai.googleapis.com`) and otherwise only the Firebase services the app uses.
   - Those services are Identity Toolkit (Auth), Firestore, Firebase Installations, App Check,
     Analytics, and Remote Config if SS-076 lands.
   - The allowlist must not include the Generative Language API: "never include the Gemini
     Developer API in the allowlist for a publicly accessible API key"
     ([Firebase API keys](https://firebase.google.com/docs/projects/api-keys);
     [AI Logic production checklist](https://firebase.google.com/docs/ai-logic/production-checklist)).
2. **Application restrictions.**
   - **Web key:** HTTP referrers limited to `https://devfest-flutter-a59e8.web.app/*` and
     `https://devfest-flutter-a59e8.firebaseapp.com/*`, plus a `localhost` entry only if local
     development needs it.
   - **Android key:** package `dev.soussight.soussight` plus the SHA-1 of the signing
     certificate. Release builds currently sign with the debug config
     (`android/app/build.gradle.kts`, DESIGN §3), so this must be updated when real signing lands
     (SS-073).
   - **iOS:** has no Firebase app yet. When one is registered (SS-073), restrict its key to the
     bundle ID.
3. **App Check enforcement** is on for Firebase AI Logic and Cloud Firestore. The production
   checklist says AI Logic enforcement was applied automatically on November 2, 2026; confirm
   it in the console rather than assuming.
   - Cloud Functions check App Check in code (`functions/src/live-token.js`, `dinner-ready.js`).
   - Consider replay protection and authenticated-users mode, which the checklist recommends.
4. **Native App Check provider.** `lib/data/firebase_services.dart:22-28` activates App Check
   only with `providerWeb`. Android (and iOS, when added) have no provider, so under enforcement
   every native AI Logic and Firestore call will fail until SS-073 adds Play Integrity and
   App Attest / DeviceCheck.
5. **App Check debug tokens.** None are in the repository: `APPCHECK_DEBUG_TOKEN` is read from
   an ignored `dart_defines.local.json`, and no UUID-shaped token appears in `lib/` or `web/`.
   Before judging, revoke any debug tokens registered in the console, and confirm the deployed
   `main.dart.js` contains none (SS-079 adds that check).
6. **reCAPTCHA Enterprise site key** (`RECAPTCHA_SITE_KEY`, a CI variable, public): its domain
   list is limited to the two hosting domains.
7. **Auth authorized domains** are limited to the hosting domains and `localhost`.

## (e) DevFest, sponsor and third-party branding left in code (for the integration owner)

None of these files is owned by SS-078. Changing them requires the owner listed.

| Location | What | Suggested action | Owner |
|---|---|---|---|
| `lib/app/how_it_works.dart:195`, `:201-202`, `:210` | `_DevFestXRayCard` class and `ValueKey('devfest-x-ray-card')`. The visible title is "ARCHITECTURE AT A GLANCE", without DevFest. DESIGN §6 (SS-080) requires "no DevFest card". | Rename or replace it. Its rows also describe the old build: "WebSocket w/ Ephemeral Auth" (`:241`) won't be true of an AI Logic Live build, and the card makes no hybrid or on-device statement. | Integration owner (SS-083) |
| `test/learner/allergy_how_it_works_test.dart:244` | Finds the card by the `devfest-x-ray-card` key | Update it together with the card | Integration owner |
| `lib/app/how_it_works.dart:21-31` | "Built with" list ends with "Vonage Messages API with signed status webhooks", and has no hybrid or on-device entry | Add the hybrid stack once it passes its gate; the provider name can stay | Integration owner |
| `lib/app/how_it_works.dart:131`; `lib/data/dinner_status.dart:44-51`; `lib/data/dinner_messages.dart:101,160` | User-facing "Vonage" in rehearsal and delivery-status text | Factual provider naming, not sponsor framing. Optional: make it neutral ("the SMS provider"). SS-084's simulated mode should not imply that a Vonage send happened. | Integration owner / SS-084 |
| `lib/data/firebase_services.dart:21` | Comment: "Debug token for the hackathon" | Reword when next touched | Integration owner |
| `web/favicon.png`, `web/icons/*`, `android/app/src/main/res/mipmap-*/ic_launcher.png`, `ios/Runner/Assets.xcassets/AppIcon.appiconset/*` | Default Flutter logo used as the app icon (see b) | Replace with an original icon | Integration owner (+ SS-073 for iOS) |
| Project ID `devfest-flutter-a59e8` | In the hosted URL, `lib/firebase_options.dart:56-67`, `android/app/google-services.json:4-5`, `firebase.json:6,13`, `.github/workflows/firebase.yml:19,80,196-212,229`, `functions/src/firebase-app.js:8`, `functions/src/dinner-index.js:20`, `functions/test/live-token.test.js:22`, `tool/smoke_hosted.sh:12` | A project ID can't be renamed. If the "devfest" URL matters, add a second Hosting site with a neutral name in the same project; it stays free. That also requires updating the allowed-origins default in `functions/src/firebase-app.js:8`, the CI origins and the reCAPTCHA and API-key referrers. Terry decides. | Terry / SS-079 |
| `lib/nearby/nearby_client.dart:17` (`'Orlando, FL'` hint); `lib/pantry/pantry_screen.dart:64` (simulated Orlando position) | Regional defaults from the Central Florida audience | Not branding. Keep or generalize. | Integration owner / SS-065 |

Documents with DevFest or sponsor framing that SS-078 doesn't own:

- **Jenna's, through her cards:** `docs/demo/*`, `docs/validation/cook-acceptance.md` (17 hits),
  `docs/validation/reference-images.md:19`.
- **Historical records, left as they are:** `docs/devpost/SUBMISSION.md` (the DevFest Devpost
  copy), `docs/handoffs/*`.
- **Project ID only:** `docs/COST-LEDGER.md`, `docs/TEARDOWN.md`, `docs/AUTODEPLOY.md`,
  `functions/README.md`.
- **Recommendation for SS-080:** the new `docs/buildhybridai/SUBMISSION.md` should not link
  `docs/devpost/SUBMISSION.md` as current copy.

## (f) Possible PII or secrets found

Scanned: all tracked files. Patterns: Google API keys, private-key headers, GitHub/OpenAI/Slack/AWS
tokens, OAuth access tokens, service-account JSON, billing-account IDs, UUID-shaped tokens, e-mail
addresses, phone numbers, coordinates, and tracked `.env` / `dart_defines` / keystore files.

| Path | Finding | Assessment |
|---|---|---|
| `lib/firebase_options.dart`, `android/app/google-services.json`, `.gitleaks.toml` | Google API keys | Public Firebase client keys, allowlisted on purpose (see d). Not secrets, provided the restrictions in (d) hold. |
| `test/learner/dinner_review_test.dart`, `test/data/dinner_messages_test.dart`, `test/learner/household_analytics_test.dart`, `lib/learner/dinner_review.dart` (hint text), `functions/test/dinner-ready.test.js`, `functions/README.md`, `docs/validation/cook-acceptance.md` | Phone numbers | All in the 555 range. Most are in the reserved fictional 555-01XX block. A few in `functions/test/dinner-ready.test.js` and `cook-acceptance.md` are other 555 numbers; switching them to 555-01XX would be safer. No real numbers found. |
| `functions/test/vonage-status.test.js` | UUID-shaped strings | Test message IDs, not credentials. |
| `test/nearby/nearby_client_test.dart:112` | Coordinates | Downtown Orlando city centre, a public location. Not a home address. |
| `docs/RULES-REVIEW.md:39`, `test/nearby/nearby_client_test.dart:53` | E-mail-shaped strings | Placeholder or test values, not real mailboxes. |
| Docs generally | First names (Terry, Jenna) and GitHub handles of the two collaborators | Already public on the repository; nothing more sensitive found. The phrase "sister's" was removed from `docs/SPEC.md`. |

Nothing that looks like a live secret was found. No `.env`, `dart_defines.local.json`, keystore or
service-account file is tracked; `.gitignore` and `functions/.gitignore` exclude them.

**Not covered:** Git history beyond the current tree, the demo video, and screenshots outside
this repository. PLAN §5N asks for the video to be checked too. That falls to SS-080 once the
video exists: check for visible phone numbers, the console, tokens or a real household recipient.
