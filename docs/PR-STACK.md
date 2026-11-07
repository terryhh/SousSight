# SousSight PR stack

Prepared locally November 7, 2026. The cook is the human in the loop; there is no instructor workflow in the active app.

| Head branch | PR base | Contents |
|---|---|---|
| `codex/agy-cooking-research` | `stack/02-data` | Sister's Markdown assignment, working agreement, and research contract |
| `stack/03-ai` | `stack/02-data` | Structured Gemini checkpoint/triage foundation inherited from the original stack; triage is unused in the active cook-only app |
| `stack/04-live-cooking` | `stack/03-ai` | Gemini Live camera/voice, GenUI cooking workspace, cook questions, Google Search research, timers, watch alerts, and dinner-message review |
| `stack/05-services` | `stack/04-live-cooking` | Protected ephemeral tokens, Vonage endpoint, private Firestore rules, Hosting routes |
| `stack/06-integration` | `stack/05-services` | Regression tests, current documentation, build script, and GitHub backlog publisher |

The old local `codex/agy-board-handoff` branch is superseded. Do not publish it. The current assignment is [AGY-COOKING-RESEARCH.md](handoffs/AGY-COOKING-RESEARCH.md).

The original PRs #1 and #2 were recorded by the source handoff but could not be re-read remotely in this session. No new remote PR, issue, project item, merge, or deployment has been verified. `git push` failed to resolve `github.com`; `gh` could not reach `api.github.com`. GitHub plugin installation was offered and still needs account authorization.

## Checks

- Integrated Flutter static analysis passed.
- Integrated rehearsal build passed, including the Wasm compatibility dry run.
- 19 backend tests, 3 browser-media tests, and 12 backlog-publisher tests passed locally.
- Flutter test cases were added but the runner cannot bind its local socket in this sandbox. Run the complete suite in a normal development shell or CI before merging.
- Actual camera/microphone behavior, live Gemini responses, deployed Auth/App Check, Firestore rules, and Vonage delivery remain unverified. No messages were sent.
- The npm dependency lockfile still requires registry access. The backend tests inject provider boundaries and do not require installed Firebase packages.

## Publish once access is available

Push each named branch without forcing, and create PRs with the exact bases above. Publish the sister's branch first so her assignment link works. Keep implementation PRs draft until the real-service and test-runner checks are complete; the documentation assignment itself is ready for review.

Then populate the existing GitHub Project using:

```sh
python3 tool/publish_backlog.py                 # offline preview
python3 tool/publish_backlog.py --apply         # issues + project items + status
# If more than one project has the same name:
python3 tool/publish_backlog.py --apply --project-number NUMBER
```

The publisher uses `gh`, discovers the exact SousSight project, and stops on ambiguous matches. It uses stable issue markers and reuses existing issues/items on reruns. It never closes issues, changes an existing issue body, sends messages, or deploys the app.
