# Firestore rules verification

This suite compiles the repository's actual `firestore.rules` in a local Firestore emulator, then exercises allowed and denied client operations. It uses the fixed `demo-soussight-rules` project and synthetic records, never production Firebase data or credentials. The test harness refuses to run without a loopback emulator address.

Prerequisites: Node compatible with Firebase JS SDK 13, Java 21+, and Firebase CLI (validated with 15.35.0). Install dependencies and run:

```sh
cd test/rules
npm ci
npm test
```

The emulator listens on `127.0.0.1:8185`. `initializeTestEnvironment` reads the repository rules directly and installs them before any test. The isolated emulator config does not deploy rules or depend on production project configuration.

Coverage includes session ownership and owner-filtered queries; session schema, immutable fields, revisions, timers and confirmed facts; checkpoint ownership, immutable photos and size limits; server-only token and notification ledgers; catalog-editor privilege boundaries; and default denial of the retired `/requests`, `/instructors` and `/config` collections.

These checks verify local rules behavior. They do not establish that the rules were deployed or that production Auth, App Check, Gemini or Vonage work.

References: [Firebase rules testing](https://firebase.google.com/docs/rules/unit-tests), [Emulator Suite configuration](https://firebase.google.com/docs/emulator-suite/install_and_configure).

Verified November 7, 2026: all 10 tests passed against Firestore emulator 1.22.0, Firebase CLI 15.35.0, Firebase JS SDK 13.2.0 and rules-unit-testing 6.0.0. The existing rules compiled without changes. Java 21 was provided from a temporary Temurin runtime; no system Java installation was made.

Re-verified November 8, 2026 after SS-034 removed the retired collections: all 10 tests passed against the local Firestore emulator using a temporary Temurin 21 runtime.
