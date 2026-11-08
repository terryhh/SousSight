# Cook Acceptance Evidence Directory (`SS-023`)

This directory stores dated verification artifacts, HTTP probe logs, reproducible defect records, and redacted screenshots for [`docs/validation/cook-acceptance.md`](../cook-acceptance.md) ([Issue #41 / `SS-023`](https://github.com/terryhh/SousSight/issues/41)).

## Contents

- [`hosted-http-probe-2026-11-07.txt`](./hosted-http-probe-2026-11-07.txt) — Sanitized HTTP `HEAD` and `GET` reachability/HSTS probe against the deployed production origin (`https://devfest-flutter-a59e8.web.app`) captured from `ENV-DESKTOP-WIN` on `2026-11-07` (see [`docs/MVP-READINESS.md`](../../MVP-READINESS.md) for real-mode/no-debug rollout verification).
- [`reproducible-defects.json`](./reproducible-defects.json) — Structured machine-readable defect handoff (`DEF-001` through `DEF-004`) with exact file/line references and expected vs. actual behavior for Terry's runtime fix pass (`SS-030`, `SS-003`, `SS-019`).

## Screenshot Naming & Redaction Rules

When adding physical Android Chrome and desktop Chrome screenshots from the interactive runbook (Section 5 of `docs/validation/cook-acceptance.md`):

1. **Redact all personal identifiers:** Mask any phone numbers (`Recipient` field in Dinner Review), personal email addresses, or nearby faces/private household items before staging images.
2. **Never stage synthetic or simulated screenshots as live device evidence:** Prefix simulated/rehearsal captures with `rehearsal-` and physical phone captures with `phone-` or `desktop-live-`.
3. **Expected capture filenames for the interactive phone pass:**
   - `phone-01-cold-load-large-text.png` (`320–430px` portrait, 150% font scale)
   - `phone-02-live-connected.png` (active camera preview + `LISTENING & LOOKING`)
   - `phone-03-panel-and-research.png` (generated GenUI panel + cited grounded research)
   - `phone-04-timer-and-watch.png` (active/expired countdown timer + opt-in watch status)
   - `phone-05-dinner-review-redacted.png` (dinner review dialog open above phone keyboard, recipient masked)
