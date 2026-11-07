# SousSight working agreement

- Preserve the user's product: a live cooking companion with camera vision, two-way voice, and Gemini-generated Flutter web panels using GenUI/A2UI. These are core features, not stretch goals.
- The cook is the human in the loop. Ask the cook targeted questions when context is missing; use grounded AI research for factual answers. Do not add an external instructor board, help queue, or expert routing workflow.
- Include dynamic real timers, opt-in visible-change watches, and a reviewed dinner-ready message through Vonage. Vision cannot establish internal temperature or food safety.
- Use current Google capabilities, verified against primary documentation and installed SDK APIs. Keep model/API versions configurable. Never claim a live service was tested when only fakes or static checks ran.
- Work in parallel with isolated branches/worktrees and clear file ownership. Use stacked PRs for all work. Do not silently stop at a plan.
- Before starting work, check GitHub card ownership. Do not take over another person’s assigned work without explicit user authorization. Jenna (`jennajh`) owns SS-005 and its research-panel implementation: `lib/research/**`, `test/research/**`, and `lib/main_research_demo.dart`. Leave that work and those files to her; coordinate shared interfaces without implementing her task.
- Credentials stay out of Git and browser bundles. Clearly label simulated demo behavior.

The user's November 7 corrections supersede the older instructor-centric handoff and design.

## Infrastructure cost control

- Terry authorizes credits/free allowances only, with $0 out-of-pocket spend. Verify credit eligibility, remaining balance and expiry before paid usage. Do not treat budget alerts or delayed spend caps as a guaranteed ceiling; do not link paid billing or buy Gemini Prepay funds under the current zero-spend constraint.
- Keep `docs/COST-LEDGER.md` current after infrastructure changes and live tests, distinguishing estimates, verified billed amounts and unknowns. Track shutdown in `docs/TEARDOWN.md`; execute deletion only on explicit teardown authorization with retention decisions.
