# SousSight demo preparation (SS-024)

Owner: Jenna (`jennajh`), card [SS-024 #42](https://github.com/terryhh/SousSight/issues/42).
Hands off to Terry for [SS-012 #22](https://github.com/terryhh/SousSight/issues/22): final recording, checking the official requirements and deadline, and submission. This folder does not state a deadline and does not submit anything.

Live app: https://devfest-flutter-a59e8.web.app · Repository: https://github.com/terryhh/SousSight

| File | What it is for |
|---|---|
| [runbook.md](runbook.md) | Pantry-to-plate recipe runbook: ingredients, physical setup, camera framing, permissions, test-recipient prerequisites, and reset/retry, so another cook can repeat the story |
| [script-and-shots.md](script-and-shots.md) | Beat-by-beat spoken script, shot list, and the honest disclosure line for each beat |
| [central-florida.md](central-florida.md) | Household benefit narrative for Central Florida, with no unmeasured impact claims |
| [pitch.md](pitch.md) | The 3-minute DevFest pitch (SS-052): filled skeleton, spoken script, judging-criteria map, Q&A and failure drill |
| [recording-checklist.md](recording-checklist.md) | Asset and recording checklist, links, and the handoff to Terry |

This folder sits next to Terry's technical run sheet, [CONFERENCE-PEANUT-BUTTER.md](../handoffs/CONFERENCE-PEANUT-BUTTER.md). That sheet is the on-stage sequence. This folder is the repeatable story, recording plan and disclosure.

## Evidence status by segment

Labels:
- **Live**: verified on the hosted app with a real service, with the card that records it.
- **Rehearsal**: shown only in the labelled rehearsal build (`FAKE_BACKEND=true`) or local checks.
- **Pending**: built and merged, but the hosted check has not been recorded yet.
- **Blocked**: cannot be shown live without a prerequisite or approval that is missing.
- **Simulated by design**: a labelled demo action that runs through the real handler without spending money.

Snapshot from the GitHub cards on **2026-11-08** (refreshed for SS-052). Re-read the linked cards before recording and update this table. Do not promote a row without a card entry that backs it.

| # | Segment | Status | Evidence / gating card |
|---|---|---|---|
| 1 | Pantry scan: photo, voice or typed, cook confirms candidates | **Live** (typed) · Pending (photo, voice) | [SS-044 #109](https://github.com/terryhh/SousSight/issues/109): typed `bread, peanut butter` passed in hosted desktop Chrome after fix #124. Android photo and voice still unchecked |
| 1b | Find food help nearby (Grounding with Google Maps) | **Live** (typed city) | [SS-045 #110](https://github.com/terryhh/SousSight/issues/110): typed Orlando returned providers with Maps links and attribution in hosted desktop Chrome. Location-permission path unchecked |
| 2 | Live camera and two-way voice (Gemini Live) | **Live** | [SS-002 #6](https://github.com/terryhh/SousSight/issues/6): hosted Live audio, Terry's speech understood, physical Android phone |
| 3 | Gemini-generated GenUI panels and targeted cook clarification | **Live** | [SS-003 #13](https://github.com/terryhh/SousSight/issues/13): hosted step, timer, comparison and cook-question panels; explicit choice recomposed the workspace |
| 4 | Allergy check first (peanut, wheat) | **Live** (chip) · Pending (spoken question) | [SS-046 #111](https://github.com/terryhh/SousSight/issues/111): hosted allergen chip shows wheat and peanut. The spoken allergy question is unchecked |
| 5 | Grounded substitution with sources (sunflower seed butter) | **Live** (typed) | [SS-046 #111](https://github.com/terryhh/SousSight/issues/111): typed sunflower-butter question returned a source-backed answer with six sources in hosted desktop Chrome |
| 6 | Real timer | **Live** | [SS-006 #16](https://github.com/terryhh/SousSight/issues/16): hosted timers persist across reload, expire and dismiss. The sandwich has no timed step; use the salsa meld timer (see runbook) |
| 7 | Opt-in visible-change watch | Pending | Moved to [SS-040 #95](https://github.com/terryhh/SousSight/issues/95) |
| 8 | Spanish exchange | Pending | [SS-046 #111](https://github.com/terryhh/SousSight/issues/111) |
| 9 | Vonage "started cooking" and "dinner is ready", reviewed, delivered and failed outcomes | Simulated by design | [SS-047 #112](https://github.com/terryhh/SousSight/issues/112) (closed). Vonage is not contacted by the simulation buttons |
| 10 | Real SMS delivered from the app | **Live** (one send) | [SS-047 #112](https://github.com/terryhh/SousSight/issues/112): on Nov 8 Terry authorized one hosted send; the dialog reported Delivered and Terry confirmed handset receipt. Any new send needs fresh explicit approval of the recipient and text. Provider setup stays on [SS-021 #39](https://github.com/terryhh/SousSight/issues/39) |
| 11 | Meal-complete moment | Pending | Merged in #116, no hosted check recorded |
| 12 | New cook between takes | Pending hosted | [SS-033 #83](https://github.com/terryhh/SousSight/issues/83) is closed; re-check the card for a hosted repeatability entry before relying on it |
| 13 | Backup demo video | Pending | [SS-048 #113](https://github.com/terryhh/SousSight/issues/113) |

The camera never establishes internal temperature, freshness, food safety or the absence of an allergen. The script says so wherever vision comes up.
