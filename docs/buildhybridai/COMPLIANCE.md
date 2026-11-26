# #BuildHybridAI 2026 compliance matrix

> Card: business-analyst pass for the submission (#167, SS-080). Compiled **Thu Nov 26, 2026, about
> 00:15 ET** against `origin/main` at `73b411d` (PR #214 merged at 00:10 ET).
> **Rules source:** the Official Rules as quoted in `.ai-council/instructions.md`, section "The
> standard: the contest's own rules" (pasted by Terry). Quotes below come from there.
> **Evidence level:** repository reading, `git`, the gate-card comments on #142–#147, the PR #214
> description, one GitHub Actions run listing, and one unauthenticated `curl` of the hosted
> `/version.json`. Console facts come from Terry's App Check screenshot (Nov 26). No model was
> called, nothing was run on a device, and no console was opened for this document.
> **Deadline:** Mon **Nov 30, 2026, 2:00 pm PT (5:00 pm ET)**. Freeze **12:00 pm ET (9:00 am PT)**.
> Commits after the deadline are not evaluated.

Status values: **met** (evidence exists for the judged build), **partly** (some evidence, a named
gap), **not met**, **unknown** (nothing checked yet).

## 1. Stage One: pass/fail requirements

Stage One is pass/fail on "including all requirements". Any **not met** row here at 2:00 pm PT on
Nov 30 can disqualify the entry before it is scored.

| # | Requirement | Source | Status | Evidence | Gap | Owner card |
|---|---|---|---|---|---|---|
| S1 | Submitted on Devpost inside the period, by Nov 30 2:00 pm PT | Rules: submission period | **not met** | No Devpost entry exists yet (Terry, Nov 26) | Join the hackathon, create the project, add Jenna, fill the form, submit | #167 SS-080 |
| S2 | App uses the Firebase AI Logic **hybrid** SDK: "runs prompts on-device when a local model is available and falls back to the cloud when it isn't" | Rules: hybrid requirement | **partly** | Code: `packages/ai_logic_hybrid/assets/ai_logic_hybrid.js:230` calls `getGenerativeModel(ai, { mode, inCloudParams, onDeviceParams })`. On-device half: G2b and G2c passed on Terry's desktop Chrome (#143, comment 04:14Z). Cloud half: **blocked**, both requests got `401 Firebase App Check token is invalid` because the debug-token exchange returned 403 (#143, comment 04:59Z) | No run yet shows the automatic cloud fallback returning an answer. The G2 cloud re-run is in progress | #143 G2 |
| S3 | Built for at least one platform: Web (Chrome), Android with Gemini Nano 4, or iOS with Apple Foundation Models, "all through Firebase AI Logic" | Rules: platforms | **partly** | Web: on-device runs on Terry's Chrome, from a local build (#143). Android: Nano 4 Full reports `available` after enrolment, then every `generate` fails with `[ErrorCode 8]` (#145). iOS: not run (#146) | Web needs one end-to-end run on the hosted build. Android and iOS have no passing run | #143, #145, #146 |
| S4 | "your app's AI runs on Firebase AI Logic" (no direct Gemini path in the judged build) | Rules: tools | **partly** | Judged settings in #214: `LIVE_BACKEND=none`, so the ephemeral direct-Gemini Live client is not compiled in. `tool/check_web_bundle.sh` rejects `generativelanguage.googleapis.com` and ephemeral Live markers (#214 checks: OK). The G2 harness's request went only to `firebasevertexai.googleapis.com` (#143) | Not yet confirmed on the **deployed** bundle: deploy of `73b411d` was pending at 05:10Z | #207 SS-090 |
| S5 | "Firebase AI Logic requires App Check; debug tokens are accepted" | Rules: App Check | **partly** | Console (Terry's screenshot, Nov 26): Firebase AI Logic **Basic – Enforced**, replay protection off. Web activation with reCAPTCHA Enterprise: `lib/data/firebase_services.dart:34-37,75` | No AI Logic request has succeeded under enforcement yet. The registered debug token is rejected (403) for the web, Android and iOS app IDs (#143). The hosted reCAPTCHA path is untested | #143 G2 |
| S6 | New, or "significantly updated after the start of the Hackathon Submission Period" | Rules: eligibility of existing projects | **met** (repo) | Baseline `430747b` is dated Nov 10 01:20 EST, before Nov 11. `git diff --shortstat 430747b 73b411d`: 215 files, +31,985 / −517. 27 PRs merged since (#170–#214). Tag `pre-buildhybridai` → `430747b` is on `origin` (`git ls-remote --tags`) | The GitHub Release for the baseline tag was not checked | #167 |
| S7 | "disclose any other pre-existing code or work" and "provide a summary of what you built during the submission period" | Rules: eligibility | **partly** | Drafted: `SUBMISSION.md:111-137`; inventory in `AUDIT.md` (a) | Not on Devpost yet. The "built during" list has 8 VERIFY markers and still names unmerged work (SS-072 offline) and Live, which the judged build doesn't ship (section 2) | #167 |
| S8 | Repo shows Firebase AI Logic "imported and actually called ... not just named in the README" | Rules: repository | **met** | `lib/pantry/pantry_client.dart:8` (import), `:236` (`FirebaseAI.googleAI().generativeModel`); `ai_logic_hybrid.js:230`; `FirebaseHybridEngine.kt:205-227` (`OnDeviceConfig`, `generateContent`); `FoundationModelsEngine.swift:14` (`import FirebaseAILogic`) | None | — |
| S9 | Repo public with a detectable open-source license | Rules: repository | **met** | `LICENSE` is AGPL-3.0 at the root; `README.md:202`. Terry confirms the repo is public and GitHub shows AGPL-3.0 | A relicense needs both Terry and Jenna (PLAN §10). Keeping AGPL is within the rules | — |
| S10 | "capable of being successfully installed and run consistently ... must function as depicted in the video" | Rules: functionality | **unknown** | Hosted root returns HTTP 200. Hosted `/version.json` at 00:10 ET returned Flutter's default (`{"app_name":"soussight",...}`, no `commit`), so the CI-stamped judged build is **not** serving yet. Deploy run for `73b411d` was `pending` at 05:10Z | Deploy lands; `version.json` commit matches; the hero journey runs from a clean Chrome profile (RELEASE §4); the video only shows what that run showed | #207, #167 |
| S11 | Judges get free access to a working build "until the Judging Period ends [Dec 16]" | Rules: testing | **partly** | Hosted URL is up. Keep-alive owner Terry (`RELEASE.md:8-9`). G1 decision: cloud runs on the paid tier with a $15/month Gemini cap and $20 alerts (#142) | The cap is "still to verify" in the console (#142). If judges exhaust it, the cloud fallback fails for everyone. `main` auto-deploys, so any merge after the freeze changes the judged site | #142 G1, #167 |
| S12 | No "production API keys, live Google Cloud project secrets ... or PII" in the repo, form or testing instructions | Rules: testing | **partly** | Repo: `AUDIT.md` (f) found only public Firebase client identifiers and 555 numbers; gitleaks passed on `73b411d`. `JUDGES.md:164-166` documents the client config | Devpost form, video and gallery not yet made, so not checked. The App Check JS SDK prints the debug token to the console (#143): no debug-token build may be deployed, filmed or screenshotted | #167 |
| S13 | Video: ≤3 minutes, public on YouTube, "showing the Project functioning on the platform(s) for which it was built" | Rules: video | **not met** | `DEMO-SCRIPT.md` exists (2:45 cut). No footage yet | Film on the hosted judged build after the gates; upload as Public | #167 |
| S14 | No content that shows "third party advertising, slogan, logo, trademark" or implies endorsement | Rules: content | **partly** | The DevFest card is gone from `lib/app/how_it_works.dart` (no `DevFest`/`devfest-x-ray` match in `lib/`). Plugin README says "Unofficial" (`packages/ai_logic_hybrid/README.md:3`) | App icons are still the default **Flutter logo** (no change to `web/favicon.png`, `web/icons/`, Android mipmaps or the iOS app icon since `430747b`; `AUDIT.md` (b)). `TRADEMARKS.md:3` claims a SousSight logo and icon that don't exist. The hosted URL contains `devfest-flutter` (`AUDIT.md` (e)). Google Search suggestions are a required attribution, not a violation | integration owner, #167 |
| S15 | Not developed "with financial or preferential support from the Sponsor or Administrator" | Rules: eligibility | **unknown** | G6 (#147) has no answer: who funded the DevFest prize; whether the $300 trial credit or the $10 Developer Program benefit in `docs/COST-LEDGER.md` was used | Terry answers on #147; asks the hackathon manager if unclear | #147 G6 |
| S16 | Devpost platform selection matches what the video and build show | Rules: platforms + video | **not met** | No entry yet. Evidence today supports **Web only** | Select Android only if G4 passes, iOS only if G5 passes (`RELEASE.md:30-31`) | #167 |

## 2. Judging criteria and plan objectives

Scored in Stage Two (1–5 each, equally weighted). None of these is pass/fail.

| # | Objective | Source | Status | Evidence | Gap | Owner card |
|---|---|---|---|---|---|---|
| J1 | Technological implementation: "how effectively does it use Firebase AI Logic hybrid inference" | Criterion 1 | **partly** | Bridge on three SDKs merged (#182, #189, #194 via #214); 673 Flutter tests, 17 plugin, 41 node, 64 functions tests passed **on fakes** (#214) | No real automatic fallback yet (S2) | #143 |
| J2 | "Apps that run across multiple platforms will be given strong consideration" | Rules: Grand Prize | **not met** | Web only has device evidence | G4 blocked (ErrorCode 8); G5 needs Xcode and the iPhone | #145, #146 |
| J3 | Design: "a complete, coherent product experience" (hero journey, PLAN §1) | Criterion 2, PLAN §1 | **unknown** | Features merged: #176, #178, #180, #181, #184, #188 | Never run end to end on the hosted build | #207 |
| J4 | Potential impact: "a credible, specific case" (evidence K, SS-075) | Criterion 3, PLAN §5K | **not met** | `docs/buildhybridai/EVIDENCE.md` does not exist; SS-075 is not merged | Score the 8 reference fixtures and film one cook-through | SS-075 |
| J5 | Quality of idea: the private on-device watch | Criterion 4, PLAN §5C | **partly** | Code merged (#181). The obscured frame abstained on-device in the G2b harness only (#143) | No run through the production path | SS-075 |
| G1 | Free (now: capped) cloud route for each judged path; real SMS off server-side | PLAN §2 | **partly** | Decision on #142: `CLOUD_ROUTES=hybridFallback,research`, Live and Maps off, `ENABLE_DINNER_MESSAGES=false` | Cap not verified in the console. No `docs/COST-LEDGER.md` entry (RELEASE §1 asks for one). `ENABLE_DINNER_MESSAGES=false` was last read on Nov 8 (`COST-LEDGER.md:207`). The capped paid tier departs from PLAN's "free tier only"; Terry made that call on #142 | #142 |
| G2 | Same task: on-device, then cloud with SDK source and App Check | PLAN §2 | **partly** | See S2 | Cloud leg | #143 |
| G2b | Mappings and camera (harness) | DESIGN §8 | **met** (device) | #143: text, schema, system instruction, obscured frame all `onDevice` | The camera-frame probe was not run | #143 |
| G2c | Production path pantry scan | DESIGN §8 | **partly** | On-device half passed (#143). Cloud half: honest "May have been sent" badge and ledger after a 401 | Cloud half | #143 |
| G3 | Web Live through AI Logic | PLAN §2 | **not met** (not run) | Code merged (#200 via #214); judged build ships `LIVE_BACKEND=none` | Default per PLAN §9: no Live on web | #144 |
| G4 | Android signed release APK on Gemini Nano 4 | PLAN §2 | **not met** (blocked) | #145: AICore preview enrolled, `nano-v4-full` available, `generate` fails with `[ErrorCode 8]` / ML Kit `606` | Unblock or drop Android by the Fri go/no-go | #145 |
| G5 | iOS on Apple Foundation Models | PLAN §2 | **not met** (not run) | Swift backend merged (#189) | Xcode, signing, iPhone run | #146 |
| G6 | Eligibility facts | PLAN §2 | **unknown** | No answer on #147 | See S15 | #147 |
| R1 | Firestore App Check enforcement on | `RELEASE.md:93` | **not met** | Console: Firestore **Unenforced** (Terry's screenshot) | Not a contest rule. Turn it on only after a hosted run proves App Check works, or the app loses its session store | #167 |
| R2 | API-key restrictions applied, sign-in survives a token refresh | `AUDIT.md` (d) | **unknown** | — | Console check | #167 |
| R3 | README links `JUDGES.md`; README matches the judged build | `RELEASE.md:108` | **not met** | `README.md` has no `JUDGES` link. `README.md:128` says "A real text sent from the hosted app reached a phone", but the judged build is simulated | Update the README before the freeze | #167 |
| R4 | Offline for an already-open session | PLAN §5H, DESIGN SS-072 | **not met** | Not among the PRs merged since `430747b` | Merge with evidence, or drop every offline claim (section 3) | SS-072 |

## 3. Submission claims without evidence

Every `VERIFY` marker in `SUBMISSION.md` (22), `JUDGES.md` (11) and `DEMO-SCRIPT.md` (10), counted
by `grep -c` (header comments included), plus unmarked claims found while reading. "Action if
still unproven at the freeze" is what the release owner does with the text.

### SUBMISSION.md

| Line | Claim | Depends on | Status now | Action if still unproven at the freeze |
|---|---|---|---|---|
| 36 | Photo scan runs on the device | Production-path photo scan | Not run (G2c was typed) | Say "typed list" only |
| 37 | Recipe draft retries once in the cloud | #184 merged; G2 cloud fallback | #184 merged via #214; fallback unproven | Drop the retry sentence |
| 38 | Private watch compares fresh frames on-device | SS-075; filmed cook-through | Harness only | Keep the design description; drop result claims |
| 43 | Coach Lite works when the Wi-Fi drops | SS-072 | Not merged | Drop "or the Wi-Fi drops" |
| 46 | Grounded research, **nearby food help (Maps)** and **Live coach** are "cloud moments" | G1 per route; G3 | Research approved; Maps and Live **off** in the judged build (#142) | Cut nearby and Live from this item |
| 57 | Web automatic cloud fallback | G2 | Unproven | Delete the VERIFY tail; state on-device only |
| 58 | Android: "Built and unit-tested; on-device run pending" | G4; #194 merged | #194 merged. Comment is stale: after enrolment the Pixel reports `nano-v4-full` available, and `generate` fails with ErrorCode 8 | Keep "on-device run pending" wording or drop the row |
| 59 | iOS built | G5 | Not run | Same |
| 76 | Play Integrity and App Attest on native release builds | G4, G5 | Not registered or run | Drop the native App Check clause |
| 86 | Release checklist requires one genuine fallback run | G2 | Unproven | Keep as a requirement only if it passes; otherwise remove challenge 4's last sentence |
| 92 | Watch "asks for a better view when it's unsure, and doesn't guess" | SS-075 | Harness only | Qualify as "in our gate harness" |
| 115 | Bridge list with Android and iOS backends | #194 merged; G4, G5 | Merged; gates open | Keep (built during the period is true); no platform claim |
| 116 | Dispatcher etc. (#186) | #186 merged | **Resolved**: merged via #214 | Delete marker |
| 118 | Recipe gate (#184) | #184 merged | **Resolved** | Delete marker |
| 125 | Native runtime (#192), native App Check | #192 merged; G4, G5 | Merged; gates open | Keep the PR; drop "native App Check and release signing" unless a gate passes |
| 126 | Integration and gate harness (#193) | #193 merged | **Resolved** | Delete marker |
| 127 | Live coach through AI Logic | #200 merged; G3 | Code merged; G3 not run; judged build has no Live | Reword: "built, not in the judged build", or delete |
| 128 | Offline cooking for an open session | SS-072 | Not merged | Delete |
| 133 | `pre-buildhybridai` tag and release exist | Tag + Release | Tag on `origin` at `430747b`; Release not checked | Confirm the Release page, then delete marker |
| 141 | Built with: Gemini Nano on Android, Apple Foundation Models | G4, G5 | Open | Drop both unless gated in. Also drop **Grounding with Google Maps** (route off) |
| 143 | Hosted URL; license at the final tag | Deploy; tag | Deploy pending; AGPL | Fill `<HOSTED_URL>`, `<YOUTUBE_URL>`; confirm AGPL at the tag |
| 4–11 | Header comment, "Pixel 9 reports ... not_enrolled" | — | Stale (enrolled since Nov 25 23:30 ET, #145) | Delete the whole comment before pasting |

Unmarked claims in `SUBMISSION.md` that also lack evidence:

- `:44` Label check on-device: no device run of #188.
- `:45` First-run states for no model, unsupported hardware, camera blocked, network down: fakes only.
- `:78` "publishes `/version.json` with its commit, so anyone can check": the hosted file currently
  has no `commit` (deploy pending).
- `:84` Challenge 2 says the on-device model followed the instruction "on a real desktop Chrome":
  true, but from a local build, not the hosted origin.

### JUDGES.md

| Line | Claim | Depends on | Status now | Action |
|---|---|---|---|---|
| 17 | Hosted URL matches `/version.json` at the final tag | Deploy + tag | Pending | Fill in after the freeze check |
| 20–21 | "Chrome on Android also works" (unmarked) | Any Android Chrome run | No evidence | Drop or verify once |
| 39 | Pantry scan and recipe draft fall back to Cloud · Gemini | G1, G2 | G1 decided; G2 cloud unproven | If G2 fails: "say they can't run here" |
| 69 | Hosted origin runs Chrome's on-device model in a clean profile with only the listed steps | Clean-profile run on the hosted origin | G2/G2c ran on `localhost` only | Run it; if an origin trial or flag is needed, say so |
| 75 | Badge label "On this device · Gemini Nano" | Hosted build | #143 recorded "On this device" with **no model label** ("not reported by the web SDK") | Match the label the hosted build shows |
| 80 | Watch asks for a better view on the hosted build | SS-075 | Harness only | Keep the instruction; drop the promise if it fails |
| 83 | Coach Lite answers offline | SS-072 | Not merged | Remove step 4's offline part |
| 91 | Research appears as a cloud request | G1 research route; G2 App Check | Route approved; never answered under App Check | Run once on hosted |
| 125 | Android section | G4 | Blocked | Replace with "Android is not part of this entry" |
| 133 | iOS section | G5 | Not run | Replace with "iOS is not part of this entry" |
| 148–149 | Real SMS "disabled on the server for this one" (unmarked) | Deployed `ENABLE_DINNER_MESSAGES=false` | Last read Nov 8 | Re-read in the console |
| 153 | Live coach availability | G3 | Not run; `LIVE_BACKEND=none` | Say the judged build has no Live coach |

### DEMO-SCRIPT.md

| Line | Shot or line | Depends on | Status now | Action |
|---|---|---|---|---|
| 39 | D2 Pixel montage; "do not show Nano 4" | G4 | Blocked | Cut D2. Update the stale note: Nano 4 Full now reports available, generate fails |
| 40 | D3 iPhone montage | G5 | Not run | Cut D3 |
| 76 | 0:12 typed scan on-device | G2c on-device | **Passed** on Terry's Chrome (local build) | Re-take on the hosted build, then delete marker |
| 77 | 0:50 watch beat | SS-075; hosted take | Harness only | Rehearse on hosted; never edit a verdict |
| 78 | 1:18 Wi-Fi off, Coach Lite answers | SS-072 | Not merged | Replace with an on-device Coach Lite answer **online**, or cut 22 s |
| 80 | 1:54 cloud research | G1 research; working App Check | Approved; unproven | Film only after one successful hosted run |
| 81 | 2:14 bridge inserts and optional fallback insert | G4, G5, G2 | Open | Film D1 only; add the fallback insert only if G2 passes |
| 82 | 2:38 end card | Frozen URL and tag | Pending | Fill after the freeze |
| 90 VO | "Firebase AI Logic still runs this on Chrome's built-in Gemini Nano" | G2c | Passed (local build) | OK on hosted take |
| 96, 98 VO | "Now the Wi-Fi drops ... Coach Lite answers on the device" | SS-072 | Not merged | Re-record without the offline claim |

### Outside the three files

- `README.md:128` claims a real hosted SMS send; `README.md:66,99` present Vonage as part of the
  stack. Judges will read the README first. Reword for the simulated judged build.
- `TRADEMARKS.md:3` claims a SousSight logo and icon; the app ships the Flutter logo (S14).

## 4. Human tasks and deadlines

All times Eastern. Hard deadline **Mon Nov 30, 5:00 pm ET (2:00 pm PT)**; freeze **12:00 pm ET**.

| By | Task | Who | Unblocks |
|---|---|---|---|
| **Thu Nov 26, morning** | Answer G6 on #147: who funded the DevFest prize; whether the $300 trial or $10 Developer Program credit was used. If unclear, email the hackathon manager today: replies can take days | Terry | S15 (eligibility) |
| Thu Nov 26 | Register the App Check debug token for the web app `1:402211265005:web:ccbaf6d63d3a274147efe4` (or confirm which token is registered) so the G2/G2c cloud re-run can pass | Terry | S2, S5, G2 |
| Thu Nov 26 | Confirm the $15 Gemini cap and $20 alerts exist in the console; read the deployed `ENABLE_DINNER_MESSAGES`; record both in `docs/COST-LEDGER.md` | Terry | G1, S11 |
| Thu Nov 26 | Watch the deploy of `73b411d`; confirm hosted `/version.json` shows that commit; run the hero journey once from a clean Chrome profile on the hosted URL | Terry / QA | S4, S10 |
| Thu Nov 26 | Join the hackathon on Devpost, create the draft project, invite Jenna (she must accept) | Terry, Jenna | S1 |
| **Fri Nov 27 (go/no-go)** | Android: one more attempt at ErrorCode 8 (AICore / ML Kit config download), otherwise drop Android | Terry | S3, J2, S16 |
| Fri Nov 27 | iOS: install Xcode, sign, run the typed probe on the iPhone, or drop iOS | Terry | S3, J2, S16 |
| Fri Nov 27 | G3: decide Live on web (default per PLAN §9: no Live in the judged build) | Terry | SUBMISSION:46,127 |
| Fri Nov 27 | Replace the Flutter-logo app icons, or remove the icon claim from `TRADEMARKS.md`; decide on a neutral Hosting site name instead of `devfest-flutter` | Terry / integration owner | S14 |
| Sat Nov 28 | SS-075 evidence (8 fixtures, filmed cook-through); decide SS-072 merge or drop | Terry, Jenna | J4, J5, R4 |
| Sat Nov 28 | Update `README.md` (JUDGES link, simulated dinner, no real-send claim) | Integration owner | R3 |
| Sat Nov 28 | Decide Firestore App Check enforcement (currently Unenforced) after a working hosted run | Terry | R1 |
| **Sun Nov 29** | Film per `DEMO-SCRIPT.md` on the hosted build; second person reviews for PII, tokens and logos; upload **Public** to YouTube, ≤3:00 | Terry, Jenna | S13 |
| Sun Nov 29 | Resolve every VERIFY marker in section 3; paste `SUBMISSION.md` into Devpost; select platforms | Terry | S7, S16 |
| **Mon Nov 30, by 12:00 pm** | Freeze: final SHA, annotated tag, GitHub Release, CI green, hosted `version.json` matches, debug tokens revoked, `main` protected against merges (auto-deploy) | Terry | S10, S11 |
| Mon Nov 30, by 3:00 pm | Submit on Devpost; save the confirmation screenshot (2 h margin before the 5:00 pm hard close) | Terry | S1 |
| Through Dec 16 | Keep hosting up; watch the Gemini cap; no deploys to the judged site | Terry | S11 |
