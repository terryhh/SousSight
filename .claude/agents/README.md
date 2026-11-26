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

## Which model does which work

The orchestrator (Claude Code) gives each role to the model best at it. Every model runs read-only unless the work is writing files in its own scratch folder or worktree. Only Claude Code agents open PRs. Codex reviews them, and the orchestrator merges.

| Work | Model | Why | How it's run |
|---|---|---|---|
| Implementation, integration, refactors, tests (`developer`, `qa`, `ux-designer` when coding) | **Claude** (Claude Code subagents) | Strongest at multi-file code changes, following repo rules and long agentic runs | Agent tool, a worktree per card |
| Adversarial PR review and scoring, mechanical defects, cross-document contradictions | **Codex** (`gpt-6.2-astra`) | Finds contradictions and mechanical bugs; already the review gate (>85 to merge) | Separate Codex session reviewing every PR |
| Raster image generation (icons, thumbnails, mock screens) | **Codex** (`image_generation` tool), with **Antigravity** as a second source | Codex CLI has a stable image-generation tool | `codex exec -s workspace-write -C <scratch dir>` |
| Vector and visual-design concepts, storyboards, video script and narration, framing and "wrong story" critique | **Antigravity** (Gemini 4 Neon) | Strong on story, framing and multimodal design | `agy --mode accept-edits --print=…` in a scratch dir under the repo |
| Google/Firebase/Chrome knowledge checks, competitive research with web search (`contestant`), judge simulation as a second opinion | **Antigravity** (Gemini) | Closest to the sponsor's ecosystem and perspective | `agy --print`, read-only |
| Personas (`user`, `clueless-user`, `judge`, `peer`, `product-manager`, `business-analyst`, `architect`) | **Claude** first; **Antigravity** for a second opinion on `judge` and `contestant` | Consistent role-play over screenshots and docs | Agent tool with the role file as the brief |
