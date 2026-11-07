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
| Current project spending budget | **$20/month before credits** | Later user authorization; delayed overage limitation explained and accepted; $20 gross alerts and $15/$2/$1 service caps verified CONFIGURED |

Sources: [Google Cloud trial](https://cloud.google.com/signup-faqs), [Gemini billing and credit eligibility](https://ai.google.dev/gemini-api/docs/billing), [Developer Program credits](https://developers.google.com/profile/help/faq), [credit balance inspection](https://docs.cloud.google.com/billing/docs/how-to/resolve-issues).

## Resource inventory and cost exposure

| Resource | Observed state | Cost driver / control | Credit coverage |
|---|---|---|---|
| Firebase Authentication | Anonymous provider enabled Nov 7 | Active users and provider selection; no phone/SMS auth configured | Free allowance/eligible cloud credit; credit redemption remains unverified |
| Firestore `(default)`, `nam5` | Pre-existing database; private rules and indexes deployed Nov 7 | Reads, writes, deletes, stored data, index storage and network transfer | $300 eligibility/balance unverified; project billing is now enabled |
| Firebase AI Logic + Gemini Developer API | APIs enabled; AI Logic App Check enforcement verified ENFORCED; one authenticated AI request smoke succeeded (5 prompt / 17 total tokens), content not asserted | Model tokens, search grounding, live media; API enablement is not a measured inference charge | Welcome credit excluded for current Gemini API; $10 benefit not yet verified |
| App Check web provider | Production Enterprise provider registered for the two Hosting domains; debug config remains local | Attestation-provider quotas; never publish debug tokens | Provider registered; actual attestation usage/cost and production-browser behavior remain to be measured |
| Hosting | Default site exists; root returned 404 before setup | Storage and outbound transfer | Free allowance then eligible cloud billing; no production web release made in this setup |
| Cloud Functions `liveToken`, `dinnerReady` | liveToken ACTIVE on Node 22 after successful run 42422724152 attempt 2; dinnerReady remains undeployed/disabled | Invocations, compute, network, build/artifact storage and logs | Billing enabled; credit coverage remains unverified |
| Secret Manager | Enabled; Gemini-only server key stored as GEMINI_API_KEY without printing or writing the value to disk | Active versions and access operations | Billing enabled; credit coverage remains unverified |
| Vonage | App sending disabled; Jenna owns SS-021 provider setup (Backlog); no credentials or paid sends configured in this setup | Channel/recipient-specific message charges, sender fees | Google credits do not establish Vonage coverage; keep disabled |
| Local test/runtime resources | Temporary Java, emulator tests and simulated local web server | Local compute only; synthetic emulator project | Not a cloud deployment or billable service verification |

## GitHub Actions infrastructure

A dedicated deployment identity now uses a Workload Identity Federation provider restricted to repository ID 1449678039, owner ID 14064284, main branch, and push/manual workflow events. No service-account key was created. The GitHub production environment allows main only. PR #37 passed CI and merged; the deployment gate was restored to `FIREBASE_DEPLOY_ENABLED=true` immediately before merge for the actual rollout. Run 42422724152 attempt 2 subsequently succeeded on main d350601; Hosting HTTP 200 and hosted Chrome research verified. Production deployment run [42419680055](https://github.com/terryhh/SousSight/actions/runs/42419680055), attempt 2, failed because Firebase required the missing VONAGE_API_KEY even for the Live-only deployment selection. Earlier failures are historical; the later successful release is recorded below. Redundant main run 42420643671 was canceled to conserve private-runner minutes while the isolation fix was prepared. GitHub private-repository Actions minutes are separate from GCP credits; no paid runner or Actions spending increase is authorized.

### Runtime IAM limitation

The deployment account has narrowly named deployment roles and no project Owner/Editor role. However, both pre-existing default runtime accounts (Compute Engine and App Engine) already have project Editor. Terry specifically approved granting the deployer actAs on the App Engine default account after that risk was explained. The default Compute runtime account also has pre-existing Editor. Therefore the effective deployment path must **not** be described as globally least privilege: deploying code under those runtime identities can exercise their broad existing access. Replacing them with dedicated restricted runtime identities requires a separate reviewed change and compatibility checks; no Editor binding was silently removed.

## Change and charge ledger

Append entries after every provisioning, deployment, model/traffic-limit change, real-service test and teardown. Keep estimates separate from billed amounts.

| Date | Action / observation | Estimated charge | Verified billed amount | Result |
|---|---|---|---|---|
| 2026-11-07 | Listed Firebase project, database, Hosting site and App Check configuration | No inference or message sent | Not inspected | Existing database and enforced AI Logic App Check confirmed |
| 2026-11-07 | Enabled anonymous auth; deployed tested private Firestore rules/indexes | No billable workload deliberately started; indexing/storage can matter once billing enabled | Not inspected | CLI reported successful deployment |
| 2026-11-07 | Enabled Firebase AI Logic and Gemini Developer APIs | API enablement only; no inference request | Not inspected | CLI reported both required APIs enabled |
| 2026-11-07 | Attempted Gemini secret metadata inspection | No secret value read or created | Not inspected | Firebase blocked Secret Manager API enablement because project is Spark |
| 2026-11-07 | Read initial project billing status | Read-only; no billing change | Not inspected | At that time no billing account was linked; superseded by the approved link below |
| 2026-11-07 | Linked billing after explicit account-specific approval; configured/read back $20 gross alerts and $15/$2/$1 service caps | No inference request in this step | Not inspected | Caps CONFIGURED, not a hard total ceiling |
| 2026-11-07 | Registered production App Check, stored Gemini backend key, enabled deployment APIs and configured WIF identity | Secret versions and later attestation/build usage can incur charges | Not inspected | Secret values remain out of Git/browser; no service-account keys |
| 2026-11-07 | Real Auth/App Check and AI Logic request smoke | Metered 5 prompt / 17 total tokens; monetary charge not calculated or reconciled | Not inspected | Request succeeded; response content not asserted; no Live audio/video or Vonage send |
| 2026-11-07 | Approved actAs access on App Engine default runtime account; reran GitHub production deployment (attempt 2) | Build, artifact, deployment and runtime charges may occur; private Actions minutes separate | Not inspected | Attempt failed on missing Vonage secret; both default runtime accounts retain pre-existing Editor roles |
| 2026-11-07 | Enabled firebaseextensions.googleapis.com for Firebase CLI discovery | API enablement only; no extension installed | Not inspected | No Firebase Extensions workload created |
| 2026-11-07 | Temporarily disabled GitHub production deployment gate while separate-entrypoint fix is reviewed | Prevents repeated known-failing deployments; validation can continue | Not inspected | Re-enable only as part of the reviewed fix rollout |
| 2026-11-07 | Canceled redundant main workflow run 42420643671 while deployment isolation is fixed | Avoids repeated private GitHub Actions usage; no estimate of incurred minutes | Not inspected | No successful production deployment or message send claimed |

| 2026-11-07 | Live-only rollout 42421304400 passed secret discovery, then stopped because Cloud Billing API was disabled | Private Actions minutes used; no successful function or Hosting release established | Not inspected | Enabled cloudbilling.googleapis.com with setup identity; no API-enable role added to deployer; next rollout 42421669752 started |
| 2026-11-07 | Rollout 42421669752 failed at Auth provisionFirebaseApp (403) after uploads; PR #48 passed CI and merged to omit repeated one-time Auth provisioning | Upload/build/artifact and private Actions usage may occur despite a failed release; no measured charge claimed | Not inspected | Gate enabled; run 42422724152 on main d350601 pending verification; no successful release established |
| 2026-11-07 | Chrome rehearsal check at 360×740: layout, countdown and dinner review | Local simulated build only; no model call or message send | Not inspected | Timer visibly advanced from 4:59 to 4:48; physical camera/audio and hosted App Check remain unverified |

| 2026-11-07 | One real Firebase AI Logic Google Search request with temporary Auth/App Check test identities | gemini-3.8-flash: 32 prompt + 172 candidate = 204 total tokens; search grounding may add charges, amount unreconciled | Not inspected | Nonempty answer, 3 source chunks and 5 supported segments returned; temporary identities removed; provider test, not physical UI acceptance |

## Planning estimate — not a quote or cap

Using published Gemini 3.8 Live media rates checked November 7: input audio about $0.005/min, input image/video about $0.002/min, output audio about $0.018/min. A hypothetical 30-minute camera/microphone session with 5 minutes of generated speech is `30 × (0.005 + 0.002) + 5 × 0.018 = $0.30` for these streams. Text/context, research/grounding, infrastructure, taxes and Vonage are additional. Actual token metering and session behavior must be measured; this is not a total-session ceiling.

[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing), [Firebase pricing](https://firebase.google.com/pricing/), [Vonage Sandbox limits](https://developer.vonage.com/en/messages/concepts/messages-api-sandbox).

## Successful release and subsequent usage

2026-11-07: Run 42422724152 attempt 2 succeeded with all jobs on main d350601. Hosting returned HTTP 200 and native Chrome loaded the hosted real-mode app. A benign chickpea research question rendered an actual answer with multiple source links using gemini-3.8-flash, verifying production browser Auth/App Check and AI Logic without a CI debug token. Camera/microphone permissions were not touched.

2026-11-07: The initial rollout attempt failed only at artifact cleanup after function creation. Terry explicitly approved one-day artifact retention; firebase functions:artifacts:setpolicy succeeded and read-back confirmed DELETE, tagState ANY, olderThan 86400s on gcf-artifacts. This permits automatic deletion of matching images and limits artifact-based rollback; it does not delete source history or prove immediate cleanup.

- One short failed protected Live-token request reached upstream (502); one corrected direct token mint succeeded, with no audio session. Token values were not recorded. No measured billable amount is claimed.
- One hosted browser research query returned a sourced answer; token usage for that query is unknown. Earlier direct research smoke usage remains recorded separately.
- Builds, artifact storage/cleanup and private GitHub Actions minutes may incur usage even when an attempt fails. Actual gross charges, applied credits and net charges remain uninspected; reconcile after reporting catches up. One-day retention is configured, not proof that all images have already been removed.

## Earlier spending-control decision (before $20 authorization)

Terry requested credit-backed limits guaranteeing no personal spend. Google’s spend-cap documentation explicitly states that caps are not hard caps and delayed overages are billed. Coverage is limited to selected services and does not establish a universal project cutoff. At that earlier point billing remained unlinked, no spend caps were configured, and paid inference/backend usage had not started. The later explicit $20 authorization and account-link approval superseded that hold; current state appears above. Do not represent a proposed threshold as an enforced or guaranteed zero-cash limit.

Tracking: [SS-014 cost ledger](https://github.com/terryhh/SousSight/issues/26), [SS-015 teardown](https://github.com/terryhh/SousSight/issues/27). Both assigned to Terry; ledger is In progress, teardown is Backlog until requested.

## Required operating checks

- Credit reconciliation remains outstanding: verify redemption on the project's intended billing account, service eligibility, expiry and remaining balance. Minimize usage within Terry's authorized $20 monthly gross soft budget while coverage is unverified; do not claim credit-backed or zero-cash operation. Do not purchase Prepay funds to unlock promotional credit without new authorization.
- Before live traffic: keep supported service spend caps and application quotas within the authorized $20 monthly gross budget. Budget alerts alone do not stop charges; supported spend-cap enforcement can be delayed. The $15 Gemini, $2 Cloud Run and $1 Cloud Run functions caps were read back as CONFIGURED; the $20 whole-project budget is alerts-only.
- After each live test: record duration, model/version, input/output usage, requests and provider outcome without recording user media or secrets. Reconcile actual billing after reporting catches up.
- During an active demo: review daily, and again before each credit expires. Reduce or stop traffic if projected gross consumption approaches the authorized $20 monthly budget, allowing for delayed reporting and cap enforcement. Unverified credit coverage is tracked separately and does not undo the later budget authorization. No scheduled automation has been created.
- At completion: execute the reviewed [teardown plan](TEARDOWN.md), then reconcile residual storage, artifact, log and delayed usage charges. Mark a resource removed only after a read-back check.

[Budget alerts](https://firebase.google.com/docs/projects/billing/budget-alerts), [supported spend caps and their limits](https://firebase.google.com/docs/projects/billing/spend-caps).
