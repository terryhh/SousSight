# SousSight agent squad

These role definitions live in `.claude/agents/`. Claude Code loads them as subagent types, and any other agent (Antigravity, Codex) can be given a file as its brief. The orchestrator, Terry's main session, dispatches them, keeps them on task and on pace, and is the only one who merges.

| Agent | Role | Writes code? |
|---|---|---|
| `product-manager` | Scope, priorities, critical path, cut list | No |
| `business-analyst` | Rules and plan traceability, compliance matrix | Docs only when asked |
| `architect` | DESIGN invariants, integration risk | Docs only when asked |
| `developer` | Implements cards with heavy tests | Yes |
| `ux-designer` | Screen critique and UI polish | UI files when asked |
| `qa` | Breaks things, coverage, e2e, release acceptance | Tests only |
| `user` | Maya, a pantry cook: does it help? | No |
| `clueless-user` | Pat, non-technical: is it intuitive? | No |
| `judge` | Scores against the official criteria | No |
| `peer` | Fellow builder's candid review | No |
| `contestant` | Rival: competitive analysis | No |

**Cadence until the deadline:**
- **Every integration build:** `qa`, `clueless-user`, `user` and `ux-designer`.
- **Every few hours:** `product-manager` and `architect`.
- **After each submission-doc change:** `judge` and `business-analyst`.
- **Once early, once before freeze:** `contestant` and `peer`.

Findings become board cards. They are claimed and notified per `docs/buildhybridai/AGENT.md`.
