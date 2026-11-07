# Automatic production deployment

`.github/workflows/firebase.yml` validates every pull request and every push to `main`. After a merge lands on `main`, its successful validation job gates a real-service build and deployment to **`devfest-flutter-a59e8`**. A manual workflow run is permitted only from `main`. Production jobs are serialized and never cancelled midway through deployment.

## What runs

Validation uses Flutter 3.47.9 / Dart from that SDK, Node 22, Java 21 and Firebase CLI 15.35.0. It enforces the Dart lockfile, installs locked npm dependencies, runs Flutter analysis/tests, browser-media tests, backend syntax/tests, publisher tests and the isolated Firestore emulator suite, then builds a visibly simulated rehearsal. That rehearsal artifact is never deployed.

The deployment job builds `lib/main_learner.dart` again with `FAKE_BACKEND=false`, the production reCAPTCHA site key, and the configured research model. It deploys Auth providers, Firestore rules/indexes, `liveToken`, and Hosting; it also deploys `dinnerReady` when `DINNER_SERVICE_READY=true`. For Live-only deployment, the workflow selects `functions/package.json` main=`src/live-index.js` for both function discovery and the uploaded runtime package. The repository default `src/index.js` re-exports the separate Live and dinner entry modules for full deployment. It does not use `--force`, destroy unknown functions, lift spend caps, create secrets, send notifications or run paid Gemini smoke tests. The final Hosting GET only checks that the site responds; it does not establish live camera/voice, App Check, AI or Vonage correctness.

## One-time setup

1. Complete the reviewed billing/credit setup and service controls in `docs/COST-LEDGER.md`. A GitHub workflow does not provide a hard spending cap. Cloud builds, artifacts and repeated deployments can consume resources, and private-repository GitHub Actions minutes have their own quota/billing independent of GCP credits.
2. Enable the required Firebase/Cloud APIs, configure anonymous Auth, register production reCAPTCHA Enterprise App Check for the two Hosting domains, and preserve AI Logic App Check enforcement.
3. Provision `GEMINI_API_KEY` in Google Secret Manager for `liveToken`. Before enabling `DINNER_SERVICE_READY`, also provision `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_FROM`, `VONAGE_ALLOWED_TO`. **The dinner function requires its declared secrets even when sending is disabled.** Do not put these values in repository variables, workflow YAML, Dart defines or service-account JSON files. Do not fabricate credentials to make deployment appear successful.
4. Create a dedicated Google deployment service account and Workload Identity Federation provider for this repository. The provider's attribute condition must require numeric repository ID `1449678039`, owner ID `14064284`, `ref == refs/heads/main`, and event name `push` or `workflow_dispatch`. Bind `roles/iam.workloadIdentityUser` on that service account only to this repository's mapped principal. Do not trust the whole GitHub issuer or owner namespace.
5. Scope deployment IAM to this project and the required runtime service accounts. Provide Hosting, Firebase Rules, Firestore index, Auth-provider and Cloud Functions deployment permissions, Service Usage Consumer, and `iam.serviceAccounts.actAs` only on the runtime accounts. Pre-provision runtime secret access and any invoker bindings; do not grant Owner/Editor or billing-administration roles to the deployer. Resolve documented missing permissions individually during the first run instead of granting broad project ownership. Runtime functions need their own scoped Firestore/secret permissions, not the deployment identity.
6. Create the GitHub environment `production`, restricting deployment branches to `main`. Protect `main` with review and the `Tests and rehearsal build` check; review workflow changes carefully. Required environment reviewers are optional, but enabling them makes deployments wait for approval instead of being fully automatic.
7. Set the variables below. Enable `FIREBASE_DEPLOY_ENABLED` only after the prerequisites are verified. The workflow can be merged with the gate unset: tests run and deployment is skipped.

## Verified setup and current run

As of November 7, the scoped GitHub WIF provider, main-only production environment, deployment variables, production reCAPTCHA Enterprise provider and dedicated Gemini server secret are configured. Validation passed; deployment is temporarily disabled with `FIREBASE_DEPLOY_ENABLED=false` while the separate-entrypoint fix is reviewed. The gate must be deliberately re-enabled for the fix rollout. Production run [42419680055](https://github.com/terryhh/SousSight/actions/runs/42419680055), attempt 2, failed after the approved runtime actAs permission change: Firebase CLI required missing VONAGE_API_KEY even when only liveToken was selected. The new separate-entrypoint strategy addresses that discovery path. Its 23 Node 22 tests include installed Firebase SDK manifest discovery for the Live-only and full entrypoints: the Live-only manifest omits dinner parameters and Vonage secrets. A successful deployed run of the fix is still required. No successful release is claimed. Redundant run 42420643671 was canceled while this blocker is resolved.

The deployed identity permissions are not globally least privilege. Both existing default Compute Engine and App Engine runtime accounts have project Editor. Terry explicitly approved the deployer actAs grant on the App Engine default account after being informed of that broad existing role. Granting actAs permits deploying code under that runtime identity. The deployer itself has no Owner/Editor role, but this does not remove the effective privilege exposure. Any later replacement with dedicated runtime accounts needs separate reviewed deployment and compatibility verification; do not silently strip existing roles.

A real Auth/App Check and AI Logic request smoke succeeded with 5 prompt / 17 total tokens, but response content was not asserted. This does not verify Android Chrome camera/voice or the deployed Live token path.

## GitHub variables

Use repository or `production` environment variables for values consumed by deployment steps. `FIREBASE_DEPLOY_ENABLED` must be a repository variable because the job condition is evaluated before the environment is entered.

| Variable | Required / default |
|---|---|
| `FIREBASE_DEPLOY_ENABLED` | Repository variable; exact `true` enables deployment after tests |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full `projects/NUMBER/locations/global/workloadIdentityPools/POOL/providers/PROVIDER` name |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | Dedicated deployment service-account email |
| `RECAPTCHA_SITE_KEY` | Production public Enterprise site key; missing value fails deployment before authentication |
| `LIVE_MODEL` | Optional; `gemini-3.8-live` |
| `LIVE_API_VERSION` | Optional; `v1beta` |
| `RESEARCH_MODEL` | Optional; `gemini-3.8-flash` |
| `DINNER_SERVICE_READY` | Optional; `false`; set `true` once the four Vonage secrets and runtime bindings exist |
| `DINNER_CHANNEL` | Optional; `whatsapp`; `sms` requires separately configured sender/registration |
| `ENABLE_DINNER_MESSAGES` | Optional; `false`; set `true` only after approved Vonage configuration and reviewed-send validation |

Jenna owns provider/credential setup under [SS-021](https://github.com/terryhh/SousSight/issues/39); assignment does not authorize a send. SS-007 remains the app/backend integration task.

Until `DINNER_SERVICE_READY=true`, CI selects the Live-only package entrypoint, omits the dinner function from deployment and removes its Hosting rewrite from the temporary deployment configuration. A function-name filter alone is insufficient: Firebase discovers secrets from the imported source graph before filtering deployment targets. The Live-only entrypoint must not import the dinner module or declare its Vonage secrets. When dinner is ready, CI uses the full index instead. Runtime exports do not depend on a special environment flag, and no dummy credentials are introduced. Dinner messaging is unavailable, not simulated; no credentials are fabricated. This leaves a recorded MVP gap until real Vonage setup is complete. Switching the flag off later does not delete an already-deployed function; use the shutdown plan for that.

The workflow writes public browser configuration to ignored `dart_defines.local.json` and non-secret backend parameters to ignored `functions/.env.devfest-flutter-a59e8`. It fixes allowed origins to the project's two Hosting domains. No local debug token or developer config is copied into CI. A fresh build is created before Google authentication; no credentials or production artifacts are uploaded as workflow artifacts.

## Authentication and verification

GitHub OIDC and `google-github-actions/auth` create short-lived, automatically cleaned Application Default Credentials immediately before deployment. Firebase CLI consumes ADC; no `FIREBASE_TOKEN` or long-lived service-account key is used. Only the deploy job receives `id-token: write`; pull-request tests have read-only repository permission and no Google credentials. Actions are pinned to verified commit SHAs.

The workflow and YAML were statically validated during authoring. A successful local test suite is not proof that GitHub IAM, deployment or real services work. For the first authorized run, inspect the Actions result, Cloud Audit Logs and deployed resource versions, then record the commit SHA, costs and any remaining live-service gaps in the ledger. Firebase deploy can partially succeed before another target fails; inspect remote state before retrying. Auth or configuration errors must fail the run rather than fall back to a fake build.

For rollback, revert the code through a reviewed PR; the resulting merge is validated and deployed like any other change. This does not restore deleted data or secret versions. To pause automatic deployment, set `FIREBASE_DEPLOY_ENABLED=false`; that does not stop already deployed services or an in-flight job. Use `docs/TEARDOWN.md` for shutdown.

References: [Firebase CLI ADC in CI](https://firebase.google.com/docs/cli#cli-ci-systems), [Google GitHub authentication action](https://github.com/google-github-actions/auth), [GitHub OIDC with Google Cloud](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-google-cloud-platform), [Flutter action](https://github.com/subosito/flutter-action).
