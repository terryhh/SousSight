# Release and submission checklist

<!-- Card SS-080 (#167). Fill in each blank as you go; link evidence rather than pasting it. -->

**Deadline:** Monday, November 30, 2026, **2:00 pm PT (5:00 pm ET)**. Later commits are not
judged.
**Freeze:** **12:00 pm ET (9:00 am PT)** on November 30. Submit on Devpost by 3:00 pm ET.
**Keep alive:** the judged build stays reachable, free of charge, through **December 16, 2026**.
Owner: Terry.

A claim goes into the submission only if its gate passed on that platform (DESIGN.md §8).

## 1. Gates and evidence

| Gate | Result | Evidence link (card comment or doc) |
|---|---|---|
| G6 Eligibility (prize funding, credits) | | |
| G1 Free cloud routes, real SMS off server-side | | `docs/COST-LEDGER.md` entry |
| G2 Web hybrid fallback (same task: on-device, then cloud with SDK source and App Check) | | |
| G2b Web mappings and camera (harness) | **Passed** on Terry's desktop Chrome: text, schema, system instruction and obscured frame all on-device | |
| G2c Production path (pantry scan) | On-device half **passed** (badge on Terry's desktop Chrome); cloud half: | |
| G3 Web Live through AI Logic | | |
| G4 Android (signed release APK, on-device result, attested fallback) | Pixel 9 enrolled (Nov 25, 23:30 ET); reports `nano-v4-full` available, `generate` fails with ErrorCode 8 (Nov 26). Blocked | |
| G5 iOS (signed build, local text probe, cloud leg attested) | | |
| SS-075 watch evidence (8 fixtures + filmed cook-through) | | `docs/buildhybridai/EVIDENCE.md` |

- [ ] Every `VERIFY` comment in `SUBMISSION.md`, `JUDGES.md` and `DEMO-SCRIPT.md` resolved
      against this table: kept (gate passed, comment deleted) or claim removed.
      `grep -rn "VERIFY" docs/buildhybridai/` returns nothing in those three files.
- [ ] Platforms to select on Devpost: Web, plus Android only if G4 passed, plus iOS only if G5
      passed: __________

## 2. Freeze the code

- [ ] All entry PRs merged to `hybrid/integration`, and `hybrid/integration` merged to `main`
      by PR. List anything left out: __________
- [ ] CI green on `main` at the final commit (validate, judged compile, bundle check, deploy,
      hosted `version.json` check).
- [ ] Final SHA: `__________`
- [ ] Annotated tag pushed: `git tag -a buildhybridai-2026 <SHA> -m "#BuildHybridAI 2026 entry"`
      then `git push origin buildhybridai-2026`. Tag name used: __________
- [ ] Baseline tag `pre-buildhybridai` exists at `430747b` with a GitHub Release, as disclosed
      in `SUBMISSION.md` under "Prior work".
- [ ] GitHub Release for the final tag, with the APK attached if G4 passed.
- [ ] **No merges to `main` after the freeze until December 16.** Merges to `main` auto-deploy,
      so a later merge would change the judged site. Either protect `main` or point judges at a
      pinned deploy.

## 3. Build configuration of the judged web build

Set as GitHub repository variables (read by `.github/workflows/firebase.yml`), then confirmed in
the hosted `version.json`.

| Name | Judged value | Rule |
|---|---|---|
| `CLOUD_ROUTES` | `hybridFallback,research` (G1, #142) | Only routes G1 approved (`hybridFallback`, `research`, `nearby`, `live`). Empty if none |
| `LIVE_BACKEND` | `none`, or `aiLogic` only if G3 passed | **Never `ephemeral`.** `aiLogic` also needs `live` in `CLOUD_ROUTES` |
| `DINNER_MODE` | `simulated` | CI's `--judged` check requires it |
| `FAKE_BACKEND` | absent / `false` | The judged build is not Rehearsal mode |
| `RESEARCH_MODEL` | __________ | A model G1 confirmed free on this project. The workflow forwards this define (repo variable, default `gemini-3.8-flash`). **It is also the effective hybrid cloud model**: `HYBRID_CLOUD_MODEL` defaults to `RESEARCH_MODEL` (`lib/app/hybrid_runtime.dart`) |
| `HYBRID_CLOUD_MODEL` | not set | **Not forwarded by `.github/workflows/firebase.yml` today**, so a repo variable has no effect. Leave it unset and pick the model with `RESEARCH_MODEL`. Using a different hybrid model would first need the workflow to forward it and `check_web_bundle.sh` / `version.json` to report it |
| `APPCHECK_DEBUG_TOKEN` | absent | Never in a deployed or released build |
| Server: `ENABLE_DINNER_MESSAGES` | `false` | Real SMS disabled server-side (G1) |

- [ ] Hosted check from a machine with no developer session:
      `curl -s <HOSTED_URL>/version.json`
      - `commit` equals the final SHA;
      - `config.LIVE_BACKEND`, `config.DINNER_MODE`, `config.CLOUD_ROUTES` equal the table.
      - `version.json` does not report the model. Confirm `RESEARCH_MODEL` from the repository
        variable (Settings → Secrets and variables → Actions → Variables; unset means the
        workflow default `gemini-3.8-flash`) and record it in `docs/COST-LEDGER.md` next to the
        G1 entry.
- [ ] `tool/check_web_bundle.sh` passed in the deploy job (no debug token, no
      `generativelanguage.googleapis.com`).

## 4. Release acceptance (clean Chrome profile, public URL)

From DESIGN.md §6 (SS-080):

- [ ] Served SHA matches the tag (section 3).
- [ ] Production App Check works: AI Logic and Firestore requests succeed with enforcement on.
- [ ] One feature shows an **on-device** result; then, with the local model unavailable, the
      same feature returns an **automatic cloud** result through the hybrid SDK (badge
      *Cloud · Gemini*, not *Cloud*).
- [ ] A computer with no on-device model gets a usable path: readiness panel, next steps,
      on-device-only features explain themselves.
- [ ] The simulated dinner flow completes, labelled "Simulated — no SMS sent."
- [ ] No DevFest card in *How it works*.
- [ ] `JUDGES.md` section 4, followed step by step, works as written.

## 5. App Check and keys

- [ ] App Check enforcement on for Firebase AI Logic and Cloud Firestore (console).
- [ ] reCAPTCHA Enterprise site key limited to the hosting domains.
- [ ] All App Check debug tokens revoked in the console.
- [ ] Native (only for platforms selected): Play Integrity registered with the release signing
      SHA-256; App Attest / DeviceCheck registered for the iOS app.
- [ ] API key restrictions applied as listed in `AUDIT.md` (d), and sign-in still works after
      an ID-token refresh.

## 6. Repository

- [ ] Public, with `LICENSE` visible at the root (AGPL-3.0 unless Terry and Jenna both approved
      the Apache-2.0 change) and named in the README.
- [ ] `gitleaks` clean in CI. No production keys, secrets, tokens or personal data in the
      repository, the Devpost form or the testing instructions. Firebase client config is public
      identifiers (AUDIT.md (d)).
- [ ] README links `docs/buildhybridai/JUDGES.md` and the hosted URL.
- [ ] The plugin is described as **unofficial** in its README and in the submission.
- [ ] App icon is not the default Flutter logo, or `TRADEMARKS.md` no longer claims a SousSight
      icon (AUDIT.md (b)).

## 7. Android and iOS (only if selected)

- [ ] **Android (G4):** signed release APK, clean install on the enrolled phone, SHA-256
      `__________`, download link in `JUDGES.md` and the GitHub Release.
- [ ] **iOS (G5):** shown in the video; build instructions in `JUDGES.md`.

## 8. Video

- [ ] Follows `DEMO-SCRIPT.md`; ≤ 3:00; English; captions corrected.
- [ ] **Public** on YouTube. URL: __________
- [ ] Shows the project working on every platform selected.
- [ ] Reviewed for personal data, console, tokens, phone numbers and third-party logos.
- [ ] Photo credits in the description if any reference photo appears.

## 9. Devpost form

- [ ] Project name: *SousSight: Counter Intelligence*
- [ ] Tagline (from `SUBMISSION.md`)
- [ ] About the project: `SUBMISSION.md` with all VERIFY comments and the header comment removed
- [ ] Built with (from `SUBMISSION.md`)
- [ ] Try it out: hosted URL; repository URL
- [ ] Video URL
- [ ] Testing instructions: link to `JUDGES.md` at the final tag, plus the hosted URL. No keys
      or personal data.
- [ ] Platforms selected (section 1)
- [ ] Existing-project disclosure: the "Built during the submission period" and "Prior work"
      sections, with the `pre-buildhybridai` tag
- [ ] Team members joined (Terry, Jenna)
- [ ] Gallery images: screenshots of the judged build only, no personal data
- [ ] Submitted before 2:00 pm PT; confirmation screenshot saved

## 10. Final consistency check

The tag, the hosted SHA, the platforms selected, the video footage and the prior-work disclosure
all describe the same pre-deadline build.

- [ ] Checked by: __________ at __________ (time, ET)

## 11. After submitting, through December 16

- [ ] Hosting, Functions, Auth and Firestore stay up; no teardown (`docs/TEARDOWN.md`) before
      December 17.
- [ ] Budget alerts on; free-tier quotas for the approved cloud routes watched, so judges don't
      hit an exhausted quota.
- [ ] No deploys to the judged site. Fixes, if any, go to a separate branch or Hosting channel.
