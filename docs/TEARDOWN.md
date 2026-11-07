# SousSight teardown plan

Owner: Terry (`terryhh`). Scope: Firebase/Google Cloud project **`devfest-flutter-a59e8`** and only the Vonage resources dedicated to SousSight. Updated November 7, 2026. **This is a plan, not an executed teardown.** Begin only when Terry explicitly says the demo/work is finished or requests shutdown. Writing this plan does not authorize deleting data or disabling the live MVP today.

The operating constraint is credits only, with no intended out-of-pocket spending. Credit expiration does not delete resources or stop all usage. Review the [cost ledger](COST-LEDGER.md) before the last covered day and stop usage before coverage ends; do not wait for a delayed billing alert.

## 1. Record scope and preserve evidence

- Record approval time, operator, intended shutdown date, and whether this is a temporary pause or permanent teardown in the ledger.
- Inventory resources actually deployed; source code is not proof that a function or secret exists. Record names, regions, retention decisions and later deletion timestamps. Capture only metadata, never secret values, payment details, photos or transcripts in Git.
- Preserve repository history and Jenna's assigned work. Do not delete branches, worktrees, her research implementation, another Firebase project, shared credentials, shared Vonage senders or the Cloud Billing account.
- Review CI workflows, scheduled jobs and local deployment processes so they cannot recreate resources after shutdown. Preserve source and deployment instructions, but prevent unintentional redeployment.

Read-only inventory commands (Firebase CLI 15.35.0 syntax verified):

```sh
firebase functions:list --project devfest-flutter-a59e8 --json
firebase hosting:sites:list --project devfest-flutter-a59e8 --json
firebase firestore:databases:list --project devfest-flutter-a59e8 --json
```

Also inventory Hosting preview channels/releases, Secret Manager versions and access bindings, generated Cloud Run services, Artifact Registry images, build/source buckets, logging sinks/storage, App Check providers/debug tokens, API keys, Auth users, and any later-added schedulers or subscriptions. Record failed inventory calls as unknown, not absent.

## 2. Stop new usage first

- Stop every cooking session and local rehearsal server. Confirm camera/microphone indicators turn off; disconnect Gemini Live WebSockets and cancel timers/visible-change watches. Closing Hosting alone does not end already-open browser sessions or their direct Gemini connections.
- Disable dinner sending. If retaining the deployed service temporarily, set the existing `ENABLE_DINNER_MESSAGES` parameter to `false` in the ignored project-specific functions environment file and redeploy only `dinnerReady`; a local edit alone has no remote effect. Alternatively, delete that exact function in step 3. Do not send a test message to prove shutdown.
- Stop token minting by removing `liveToken` in step 3. Existing ephemeral tokens/sessions may outlive endpoint removal; verify sessions have ended, then revoke a dedicated backend Gemini API key when approved. Never revoke the Firebase web configuration key as a substitute without checking its other consumers.
- Disable this Hosting site and remove any active preview channels after checking their exact IDs. Pause further test runs and automated clients. Do not weaken App Check or Firestore rules to accomplish shutdown.

The following is a **future approved shutdown command**, not a command to run during setup:

```sh
firebase hosting:disable --site devfest-flutter-a59e8 --project devfest-flutter-a59e8
```

The command stops serving the site; it is not proof that stored Hosting releases or other billable resources were removed.

## 3. Remove compute and credentials deliberately

After Terry approves the exact removal list, remove only the two known functions in their configured region. If inventory differs, stop and reconcile it first. Keep confirmation prompts; do not add `--force`.

```sh
firebase functions:delete liveToken dinnerReady --region us-central1 --project devfest-flutter-a59e8
```

- Verify both functions are absent and their associated generated Cloud Run services are gone. Inspect remaining regions rather than deleting by wildcard.
- Review Secret Manager metadata for `GEMINI_API_KEY`, `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_FROM`, and `VONAGE_ALLOWED_TO`. Disable dedicated secret versions first when a recovery period is desired; destroy them only after an explicit retention decision and approval. Remove SousSight-only access bindings. Do not remove default/shared service accounts or project-wide IAM roles blindly.
- Revoke dedicated provider API credentials and remove dedicated Vonage sandbox registrations/webhooks as appropriate. Verify whether a sender/number/subscription has recurring fees; release it only if it belongs solely to this demo and Terry approves. Deleting a Cloud Function does not cancel a Vonage account or subscription.
- Inspect Artifact Registry deployment images and build/source buckets. Remove only the identified SousSight artifacts after the rollback-retention choice; function deletion alone is not proof that storage costs stopped. A cleanup policy can reduce future accumulation but is not proof of immediate removal. [Firebase function and artifact management](https://firebase.google.com/docs/functions/manage-functions)
- Review dedicated log buckets, retention and export sinks. Keep needed security/audit and cost evidence, remove unnecessary dedicated exports after approval, and check destination storage separately. Retained artifacts, backups and logs must stay on the ledger until removed or accepted for retention.

## 4. Decide on data before deleting it

Present Terry with the exact data to retain or delete: cooking sessions, checkpoint photos, confirmed facts, legacy requests, token quotas, dinner notification/meal deduplication ledgers, Auth users, backups and exports. Keep privacy rules enforced while data remains.

Choose one explicitly:

1. **Retain temporarily:** record who needs the data, the retention deadline, expected storage exposure and its verified credit coverage. This is not a zero-resource teardown.
2. **Export then delete:** approve the export destination, permissions, expected reads/storage/transfer cost and credit eligibility first. Verify the export is usable and protected before deleting the source. Managed Firestore export requires billing and incurs operations/storage charges; do not enable billing or start an export merely because this plan mentions it. [Firestore export requirements](https://firebase.google.com/docs/firestore/manage-data/export-import)
3. **Delete without export:** obtain explicit approval that the named records are disposable. Delete only the agreed resources in `devfest-flutter-a59e8`; this plan deliberately contains no recursive deletion command.

Auth users and Firestore records are separate: removing one does not establish that the other is gone. Decide whether to disable anonymous sign-in, preserve specific identities or delete named demo users. Do not export password hashes or user/contact data into Git. Include any backup/export buckets in the eventual deletion check.

## 5. Disable APIs and project billing last

- Once functions, data-retention choices and dependent resources are resolved, inventory enabled APIs and disable only those dedicated to SousSight that are no longer needed. Do not interrupt teardown tooling or retained resources by disabling their APIs first. Remove dedicated App Check debug registrations and reCAPTCHA keys only after verifying no remaining app relies on them.
- If billing was ever linked, review the final resource inventory before asking Terry to unlink billing from **this project only**. Disabling project billing can stop services and make resources unavailable; it is not a backup strategy. Do not close the shared billing account, delete payment methods, cancel unrelated subscriptions or discard credits used by other projects. [Google Cloud project billing](https://docs.cloud.google.com/billing/docs/how-to/modify-project)
- If the project stayed on Spark with no linked billing, record that fact and skip unlinking. Do not delete the whole project unless Terry separately approves that exact action after retention decisions.

## 6. Verify shutdown and reconcile costs

Record evidence for every applicable item:

- Hosting no longer serves the app; preview channels are removed or documented.
- No active browser media capture, watch loop, Gemini session, scheduled caller or deployment automation remains.
- Functions and dedicated compute are absent; token and dinner endpoints cannot execute their former handlers. Do not mint a token or send a message for this check.
- Provider credentials/registrations and cloud secrets are disabled or removed as approved.
- Firestore, Auth, backups, build artifacts, log/export storage and other retained resources each have a disposition and owner.
- The latest billing/usage reports show no new usage after the shutdown window, allowing for reporting lag. Reconcile gross charges, credits applied and net charges in the ledger; mark the total **provisional** until reports settle. Check again the next day and after the relevant billing statement becomes available. Stopping resources does not cancel usage already incurred. [Billing changes and previously incurred charges](https://docs.cloud.google.com/billing/docs/how-to/modify-project)

Close the teardown card only after the evidence and final retention/cost decisions are recorded. If any resource cannot be inspected, record the unresolved risk and owner instead of claiming that all costs stopped.
