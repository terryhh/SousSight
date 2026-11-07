# Firestore privacy review — 2026-11-07

The current product keeps the cook in control, with AI clarification and research.
There is no external instructor workflow. The rules preserve existing collection
names while making private cooking records accessible only to their owning cook.

## Findings and changes

| Previous behavior | Impact | Change |
| --- | --- | --- |
| Privileges derived solely from an email string; email verification was not checked | Anyone able to register a reserved demo email could obtain broad privileges | Removed email-based roles. An Admin-provisioned `soussightCatalogEditor: true` custom claim permits catalog edits only |
| A session owner could rewrite `learnerId` | Ownership could be transferred to a different account, exposing private facts and photos | Ownership, recipe identity/version and creation time are immutable |
| Coordinator accounts could read, alter and delete every session | Old board privileges contradicted the private coach product | Sessions and checkpoints permit only the session owner; catalog claims do not grant access |
| Instructor accounts could read all requests and rewrite their identity fields | Legacy question photos and text could leak or change ownership | Requests are owner-only; identity fields and Functions-owned `notify` cannot change |
| Session and checkpoint writes accepted arbitrary document shapes | Malformed or oversized records could break the app; cross-path checkpoint references were possible | Added bounded field/type checks and required checkpoint `sessionId` to match its parent |

Authenticated queries must constrain `learnerId` to the caller's UID, as the
existing repository does. The backend uses Admin SDK privileges, so each function
must continue verifying Auth, App Check and session ownership independently of
these client rules.

Explicit client denials cover `_liveTokenLimits`, `_dinnerNotifications`, and
`_dinnerMealClaims`, alongside private contact collections. Those collections were
already denied implicitly; explicit entries make the boundary clear. A final
default-deny match covers new collections and nested paths.

## Compatibility

- Empty ingredient maps are valid. Ingredient values are `have`, `missing`, or
  `substituted`; the map is limited to 64 entries.
- `timerId`, `timerLabel`, `timerDeadline`, and `confirmedFacts` are supported.
  Optional fields may be absent on older records. Facts are limited to 100 entries.
- Session revisions cannot decrease; unchanged revisions are allowed for timer
  persistence. User-confirmed changes should still increment the revision in code.
- Checkpoint capture identity and photo bytes are immutable after creation. The
  owner may add an assessment and update their confirmation. Photos are capped at
  768 KiB, below Firestore's document limit.
- Catalog seeding must use Admin SDK or a separately provisioned catalog editor
  custom claim. Merely logging in with `coordinator@soussight.demo` grants nothing.
- The unused instructor board can no longer read questions or reset private
  sessions. This is intentional. Legacy records are retained for their owners;
  existing answer text is not an attestation from a privileged instructor.
- These checks validate list size and container types, not every nested list
  element. Client parsing must still validate stored/model-derived content.

## Verification and remaining checks

Reviewed the rules against `CookingSession.toMap`, `CheckpointRecord.toMap`, the
Firestore repository's owner-filtered session query, and the new server-only
ledger collection names. `git diff --check` passes. The machine has no Java runtime
(`java_home -V` reports none), so the Firestore emulator cannot run here. **These
rules have not been compiled or exercised in the emulator, and have not been
deployed.** Text-matching tests would not establish authorization correctness.

Before deployment, run emulator assertions covering:

1. Anonymous cook A can create/read/update/delete their session, including empty
   ingredients, timer fields and confirmed facts; cook B cannot read or modify it.
2. A cannot create a session owned by B, transfer an existing session to B, change
   recipe identity, roll back its revision, or add unexpected top-level fields.
3. A can save and assess their checkpoint; B cannot access it. Wrong parent IDs,
   oversized bytes and changes to an existing photo are denied.
4. Reserved demo email identities, even with the catalog editor claim, cannot read
   another cook's sessions, photos, legacy requests, or server-only ledgers.
5. Catalog edits require the custom claim. Ordinary authenticated users may read
   recipes and demo roster data, and only `/config/demo` is client-readable.
6. Legacy request owners can read/delete their records, but cannot rewrite identity
   or `notify`; another cook cannot access them.
7. An owner can delete checkpoints and their session in one batch; an unfiltered
   session/request collection query and all client ledger operations are denied.

The implementation uses Firebase's documented [field validation and changed-key checks](https://firebase.google.com/docs/firestore/security/rules-fields),
[owner conditions](https://firebase.google.com/docs/firestore/security/rules-conditions),
and [authentication/custom claims](https://firebase.google.com/docs/rules/rules-and-auth).
