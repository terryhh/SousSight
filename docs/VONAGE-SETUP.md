# Vonage Dinner-Ready Messaging Setup & Cost Guide (`SS-021`)

Owner: Jenna (`@jennajh`) — [Issue #39 (`SS-021`)](https://github.com/terryhh/SousSight/issues/39)
Integration Counterpart: Terry (`@terryhh`) — [Issue #17 (`SS-007`)](https://github.com/terryhh/SousSight/issues/17)
Project: `devfest-flutter-a59e8`

This document records the provider configuration, Secret Manager resource locations, applicable Vonage/GCP pricing and free allowances, channel restrictions, and two-stage deployment gates for the cook-reviewed dinner-ready notification service (`POST /api/dinner-ready` → `dinnerReady` in `us-central1`).

> **Security & Privacy Rule:** Never commit API keys, secrets, sender numbers, or recipient phone numbers to Git, GitHub variables, Dart defines, or issue comments. Share only the Google Cloud Secret Manager resource paths below.

---

## 1. Channel, Sending Identity & Recipient Prerequisites

| Setting | Value / Requirement | Notes |
| :--- | :--- | :--- |
| **Supported Channel (`DINNER_CHANNEL`)** | `whatsapp` (default) | Uses the Vonage Messages API Sandbox (`https://messages-sandbox.nexmo.com/v1/messages`). |
| **Authentication Method** | Account-level HTTP Basic Auth (`apiKey:apiSecret`) | Supported by the Vonage Messages API Sandbox (`functions/src/dinner-ready.js`). |
| **Sending Identity (`VONAGE_FROM`)** | Vonage WhatsApp Sandbox number | Assigned in **Vonage Dashboard → Build & Manage → Messages API Sandbox → WhatsApp**. Must match `/^\+?[1-9][0-9]{7,14}$/` (digits only or a single leading `+`, no spaces, dashes, or trailing newline). |
| **Recipient Allowlist (`VONAGE_ALLOWED_TO`)** | Comma-separated E.164 phone numbers | Each recipient must: (1) be listed in `VONAGE_ALLOWED_TO` in Secret Manager, (2) be enrolled in the Vonage Sandbox allowlist under the same Vonage account, and (3) have an active **24-hour WhatsApp customer care window** initiated by messaging the Sandbox number within the past 24 hours. |

### Why `DINNER_CHANNEL=whatsapp` Instead of `sms`

In `functions/src/dinner-ready.js`, `channel === 'whatsapp'` targets `https://messages-sandbox.nexmo.com/v1/messages`, whereas `channel === 'sms'` targets the production endpoint `https://api.nexmo.com/v1/messages` (SMS is not a Sandbox channel in Vonage). Using `sms` in the United States requires purchasing a dedicated virtual number, completing US 10DLC or toll-free sender registration/approval, and incurring per-segment message and carrier fees. Keep `DINNER_CHANNEL=whatsapp` for the hackathon demo.

---

## 2. Google Secret Manager Resource Locations (`devfest-flutter-a59e8`)

All four secrets declared by `functions/src/dinner-index.js` (`defineSecret(...)`) reside in Google Cloud Secret Manager for project `devfest-flutter-a59e8`:

| Secret Name | Secret Manager Resource Location | Format Constraint (`functions/src/dinner-ready.js`) |
| :--- | :--- | :--- |
| `VONAGE_API_KEY` | `projects/devfest-flutter-a59e8/secrets/VONAGE_API_KEY` | Exact Vonage account API key; **no trailing newline or whitespace** (`vonageApiKey.value()` is not trimmed). |
| `VONAGE_API_SECRET` | `projects/devfest-flutter-a59e8/secrets/VONAGE_API_SECRET` | Exact Vonage account API secret; **no trailing newline or whitespace** (`vonageApiSecret.value()` is not trimmed). |
| `VONAGE_FROM` | `projects/devfest-flutter-a59e8/secrets/VONAGE_FROM` | Sandbox WhatsApp sender number matching `/^\+?[1-9][0-9]{7,14}$/`; **no spaces, dashes, parentheses, or trailing newline** (`vonageFrom.value()` is not trimmed; invalid format causes `status: 'failed', reason: 'invalid-sender'`). |
| `VONAGE_ALLOWED_TO` | `projects/devfest-flutter-a59e8/secrets/VONAGE_ALLOWED_TO` | Comma-separated E.164 numbers (e.g. `+14075550100`); entries are `.trim()`med and validated against `/^\+?[1-9][0-9]{7,14}$/`. |

### Cloud Shell Provisioning Commands (No Trailing Newlines)

Run in Google Cloud Shell for `devfest-flutter-a59e8` so secret values never touch local disk or shell history files:

```bash
gcloud config set project devfest-flutter-a59e8

read -rsp "VONAGE_API_KEY: " v_key && echo && printf '%s' "$v_key" | gcloud secrets create VONAGE_API_KEY --replication-policy=automatic --data-file=-
read -rsp "VONAGE_API_SECRET: " v_sec && echo && printf '%s' "$v_sec" | gcloud secrets create VONAGE_API_SECRET --replication-policy=automatic --data-file=-
read -rp "VONAGE_FROM (digits or +E.164): " v_from && printf '%s' "$v_from" | gcloud secrets create VONAGE_FROM --replication-policy=automatic --data-file=-
read -rp "VONAGE_ALLOWED_TO (comma-separated +E.164): " v_to && printf '%s' "$v_to" | gcloud secrets create VONAGE_ALLOWED_TO --replication-policy=automatic --data-file=-
unset v_key v_sec v_from v_to
```

*(If updating an existing secret, replace `gcloud secrets create <NAME> --replication-policy=automatic --data-file=-` with `gcloud secrets versions add <NAME> --data-file=-`.)*

Verify metadata only (never print secret payloads):

```bash
for s in VONAGE_API_KEY VONAGE_API_SECRET VONAGE_FROM VONAGE_ALLOWED_TO; do
  gcloud secrets versions list "$s" --project=devfest-flutter-a59e8 --limit=1
done
```

---

## 3. Applicable Charges, Free Credits & Rate Limits

### Vonage Charges & Free Allowances (USD)
- **Free Trial Credit:** New Vonage API accounts receive **$2.00 USD free promotional credit** upon signup.
- **Messages API Sandbox (`DINNER_CHANNEL=whatsapp`):**
  - **Sandbox Allowance:** Up to **100 messages per month** at no number-rental cost ($0.00/month for the shared Sandbox sender).
  - **Rate Limit:** **1 message per second** (`429` returned if exceeded).
  - **Session Window Restriction:** Free-form text messages via the WhatsApp Sandbox require an active **24-hour customer service window** opened by an inbound message from the allowlisted recipient phone to the Sandbox number.
- **Production SMS (`DINNER_CHANNEL=sms`, not used):**
  - Requires a leased US virtual number (~$1.00–$1.65 USD/month), US 10DLC brand/campaign registration fees (or toll-free verification), and outbound per-segment charges (~$0.0076+ USD per segment plus carrier surcharges). Keep `DINNER_CHANNEL=whatsapp`.

### Google Cloud Secret Manager Charges (`devfest-flutter-a59e8`)
- **Active Secret Versions:** First **6 active secret versions/month** per billing account are free; additional active versions cost **$0.06 per version/month** (prorated). With `GEMINI_API_KEY` (1 version) plus the 4 Vonage secrets (4 versions) = 5 active versions total (within the 6-version free tier if no other secrets exist on the billing account, or ≤$0.24/month gross).
- **Access Operations:** First **10,000 access operations/month** are free; $0.03 per 10,000 operations thereafter.
- **Google Credits Note:** GCP credits do not cover third-party Vonage usage.

---

## 4. Two-Stage Deployment & Authorization Gates

Per `.github/workflows/firebase.yml` and `docs/AUTODEPLOY.md`, dinner messaging is controlled by two independent GitHub configuration variables:

1. **`DINNER_SERVICE_READY` (Default: `false`)**
   - While `false`, CI sets `functions/package.json` `main` to `src/live-index.js` and omits `dinnerReady` and the `/api/dinner-ready` Hosting rewrite so `liveToken` can deploy without Vonage secrets.
   - Set `DINNER_SERVICE_READY=true` **only after** all four `VONAGE_*` secrets have active versions in Secret Manager and the Cloud Functions runtime service account has `roles/secretmanager.secretAccessor` on them.
2. **`ENABLE_DINNER_MESSAGES` (Default: `false`)**
   - Even when `DINNER_SERVICE_READY=true` and `dinnerReady` is deployed, `ENABLE_DINNER_MESSAGES=false` keeps the endpoint in **dry-run mode**: requests still validate Auth, App Check, session ownership, and the `VONAGE_ALLOWED_TO` allowlist, record the claim in `_dinnerNotifications` / `_dinnerMealClaims`, and return `{ status: "skipped", reason: "disabled" }` without calling Vonage.
   - Set `ENABLE_DINNER_MESSAGES=true` **only when explicitly authorized** to execute a live cook-reviewed test message or the final demo send.

> **Idempotency & Rehearsal Note:** `_dinnerMealClaims` permanently claims `(uid, sessionId, recipient)` on the first request—even when `ENABLE_DINNER_MESSAGES=false` returns `skipped`. After running a dry-run check, **start a new cooking session** before testing a real send with `ENABLE_DINNER_MESSAGES=true`.

---

## 5. Sanitized Verification Log (`SS-021`)

Update this table as each prerequisite and authorized check completes (never record keys, secret payloads, or phone numbers):

| Date | Step | Status | Sanitized Evidence |
| :--- | :--- | :--- | :--- |
| 2026-11-07 | Document channel (`whatsapp`), Secret Manager locations, Vonage Sandbox limits/credits, and deployment gates | Done | Recorded in `docs/VONAGE-SETUP.md` on branch `agy/ss-021-vonage-setup`. `DINNER_SERVICE_READY` and `ENABLE_DINNER_MESSAGES` remain `false`. |
| Pending | Activate Vonage WhatsApp Sandbox and enroll test recipient phone within 24h window | Pending | Record enrollment confirmation date/time only (no phone numbers). |
| Pending | Create `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_FROM`, `VONAGE_ALLOWED_TO` in `devfest-flutter-a59e8` Secret Manager | Pending | Record version numbers (`1`) from `gcloud secrets versions list` (no secret values). |
| Pending | Enable `DINNER_SERVICE_READY=true` with `ENABLE_DINNER_MESSAGES=false` and verify deployed dry-run (`status: "skipped"`) | Pending | Record workflow run ID and dry-run response status (`skipped`). |
| Pending | After explicit authorization, set `ENABLE_DINNER_MESSAGES=true`, confirm one cook-reviewed message in a new session, and verify provider acceptance (`status: "submitted"`) | Pending | Record workflow run ID, `status: "submitted"` (delivery unconfirmed), and whether WhatsApp message arrived on the enrolled test handset. |
