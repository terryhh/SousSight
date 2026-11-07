# SousSight infrastructure cost ledger

Owner: Terry (`terryhh`), with Codex maintaining evidence during setup and operation.
Project: `devfest-flutter-a59e8`. Currency: USD. Last reviewed: November 7, 2026.

## Current authorization

Terry subsequently authorized a **$20 monthly SousSight budget before credits** and continued infrastructure/CD setup, accepting the previously explained delayed cap enforcement. Use eligible credits first. Configure project-wide alerts and supported service caps before paid workloads. This supersedes the earlier strict $0 instruction below; it does not authorize buying Gemini prepaid credit or changing unrelated projects. Controls are now configured and read back: whole-project gross alerts at $20/month; Gemini Developer API cap $15, Cloud Run cap $2, Cloud Run functions cap $1. The $2 remainder is monitored headroom for other infrastructure, not an enforced cap.

## Original spending constraint (superseded by $20 authorization)

Use eligible credits and free allowances; Terry does not authorize out-of-pocket spend. Do not link or upgrade billing, purchase Gemini prepaid balance, enable paid traffic, or send a paid message merely because credits are expected. Confirm the billing account, credit scope, remaining amount and expiration first. If coverage cannot be verified, leave the paid path disabled and report the blocker. Credits and alert thresholds are not a guaranteed spending ceiling.

Never put API keys, tokens, phone numbers, payment details, billing exports or billing-account identifiers in this file. Record sanitized totals and verification dates only. Do not change another project or shared billing resources to control this project's costs.

## Verified billing and credit position

| Item | Status | Evidence / next check |
|---|---|---|
| Project billing | Enabled on the user-approved existing account | User explicitly approved linking after overage risk explanation; API returned billingEnabled=true |
| $300 GCP welcome credit | User reports credit; balance, scope and expiration unverified | Check Cloud Billing → Credits. Welcome credits generally expire after 90 days and exclude current Gemini Developer API usage |
| $10 Developer Program benefit | User reports benefit; redemption, remaining balance and renewal unverified | Check Developer Program benefits and destination billing account. Eligible benefit credits can cover Gemini API; Prepay may require a positive purchased balance, which is not authorized |
| Actual billed cost | **Unknown — billing report not inspected** | Do not equate successful setup, Spark status, or zero recorded charges with a verified $0 invoice |
| Current project spending budget | **$20/month before credits** | Later user authorization; delayed overage limitation explained and accepted; controls pending |

Sources: [Google Cloud trial](https://cloud.google.com/signup-faqs), [Gemini billing and credit eligibility](https://ai.google.dev/gemini-api/docs/billing), [Developer Program credits](https://developers.google.com/profile/help/faq), [credit balance inspection](https://docs.cloud.google.com/billing/docs/how-to/resolve-issues).

## Resource inventory and cost exposure

| Resource | Observed state | Cost driver / control | Credit coverage |
|---|---|---|---|
| Firebase Authentication | Anonymous provider enabled Nov 7 | Active users and provider selection; no phone/SMS auth configured | Free allowance/eligible cloud credit; confirm before billing activation |
| Firestore `(default)`, `nam5` | Pre-existing database; private rules and indexes deployed Nov 7 | Reads, writes, deletes, stored data, index storage and network transfer | $300 eligibility/balance unverified; Spark limits currently apply |
| Firebase AI Logic + Gemini Developer API | APIs enabled; AI Logic App Check enforcement verified ENFORCED | Model tokens, search grounding, live media; API enablement is not a measured inference charge | Welcome credit excluded for current Gemini API; $10 benefit not yet verified |
| App Check web provider | Production Enterprise provider registered for the two Hosting domains; debug config remains local | Attestation-provider quotas; never publish debug tokens | Verify applicable free allowance before production registration/traffic |
| Hosting | Default site exists; root returned 404 before setup | Storage and outbound transfer | Free allowance then eligible cloud billing; no production web release made in this setup |
| Cloud Functions `liveToken`, `dinnerReady` | Not deployed by this setup; remote listing failed | Invocations, compute, network, build/artifact storage and logs | Billing enabled; credit coverage remains unverified |
| Secret Manager | Enabled; Gemini-only server key stored as GEMINI_API_KEY without printing or writing the value to disk | Active versions and access operations | Billing enabled; credit coverage remains unverified |
| Vonage | App sending disabled by default; no credentials or paid sends configured in this setup | Channel/recipient-specific message charges, sender fees | Google credits do not establish Vonage coverage; keep disabled |
| Local test/runtime resources | Temporary Java, emulator tests and simulated local web server | Local compute only; synthetic emulator project | Not a cloud deployment or billable service verification |

## GitHub Actions infrastructure

A dedicated deployment identity now uses a Workload Identity Federation provider restricted to repository ID 1449678039, owner ID 14064284, main branch, and push/manual workflow events. No service-account key was created. The GitHub production environment allows main only. The deployment gate remains false until the first PR validation passes. GitHub private-repository Actions minutes are separate from GCP credits; no paid runner or Actions spending increase is authorized.

## Change and charge ledger

Append entries after every provisioning, deployment, model/traffic-limit change, real-service test and teardown. Keep estimates separate from billed amounts.

| Date | Action / observation | Estimated charge | Verified billed amount | Result |
|---|---|---|---|---|
| 2026-11-07 | Listed Firebase project, database, Hosting site and App Check configuration | No inference or message sent | Not inspected | Existing database and enforced AI Logic App Check confirmed |
| 2026-11-07 | Enabled anonymous auth; deployed tested private Firestore rules/indexes | No billable workload deliberately started; indexing/storage can matter once billing enabled | Not inspected | CLI reported successful deployment |
| 2026-11-07 | Enabled Firebase AI Logic and Gemini Developer APIs | API enablement only; no inference request | Not inspected | CLI reported both required APIs enabled |
| 2026-11-07 | Attempted Gemini secret metadata inspection | No secret value read or created | Not inspected | Firebase blocked Secret Manager API enablement because project is Spark |
| 2026-11-07 | Read project billing status | Read-only; no billing change | Not inspected | No linked billing account; paid setup remains blocked |

| 2026-11-07 | Linked billing after explicit account-specific approval; configured/read back $20 gross alerts and $15/$2/$1 service caps | No inference request in this step | Not inspected | Caps CONFIGURED, not a hard total ceiling |
| 2026-11-07 | Registered production App Check, stored Gemini backend key, enabled deployment APIs and configured WIF identity | Secret versions and later attestation/build usage can incur charges | Not inspected | Secret values remain out of Git/browser; no service-account keys |

## Planning estimate — not a quote or cap

Using published Gemini 3.8 Live media rates checked November 7: input audio about $0.005/min, input image/video about $0.002/min, output audio about $0.018/min. A hypothetical 30-minute camera/microphone session with 5 minutes of generated speech is `30 × (0.005 + 0.002) + 5 × 0.018 = $0.30` for these streams. Text/context, research/grounding, infrastructure, taxes and Vonage are additional. Actual token metering and session behavior must be measured; this is not a total-session ceiling.

[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing), [Firebase pricing](https://firebase.google.com/pricing/), [Vonage Sandbox limits](https://developer.vonage.com/en/messages/concepts/messages-api-sandbox).

## Earlier spending-control decision (before $20 authorization)

Terry requested credit-backed limits guaranteeing no personal spend. Google’s spend-cap documentation explicitly states that caps are not hard caps and delayed overages are billed. Coverage is limited to selected services and does not establish a universal project cutoff. Therefore billing remains unlinked, no spend-cap configuration has been applied, and no paid inference/backend path has been enabled. Do not represent a proposed threshold as an enforced or guaranteed zero-cash limit.

Tracking: [SS-014 cost ledger](https://github.com/terryhh/SousSight/issues/26), [SS-015 teardown](https://github.com/terryhh/SousSight/issues/27). Both assigned to Terry; ledger is In progress, teardown is Backlog until requested.

## Required operating checks

- Before any paid operation: verify credit redemption on the project's intended billing account, service eligibility, expiry and remaining balance. Do not purchase Prepay funds to unlock promotional credit without new authorization.
- Before live traffic: choose supported service spend caps and application quotas within verified credit headroom. Budget alerts alone do not stop charges; supported spend-cap enforcement can be delayed. No caps have been configured or verified yet.
- After each live test: record duration, model/version, input/output usage, requests and provider outcome without recording user media or secrets. Reconcile actual billing after reporting catches up.
- During an active demo: review daily, and again before each credit expires. Stop traffic if coverage is unclear or projected consumption exceeds verified remaining credit. No scheduled automation has been created.
- At completion: execute the reviewed [teardown plan](TEARDOWN.md), then reconcile residual storage, artifact, log and delayed usage charges. Mark a resource removed only after a read-back check.

[Budget alerts](https://firebase.google.com/docs/projects/billing/budget-alerts), [supported spend caps and their limits](https://firebase.google.com/docs/projects/billing/spend-caps).
