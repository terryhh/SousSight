# AGY task: grounded cooking answers and substitutions

Owner: Terry's sister, using Google Antigravity (AGY). Updated November 7, 2026 after the user's product correction.

## Product and your task

SousSight is a live cooking companion. The cook shows ingredients and progress to the camera, talks naturally, and receives Gemini-generated Flutter panels. **The cook is the human in the loop.** The AI asks the cook questions when context is missing, and researches answers when needed. There is no external instructor, board, help queue, or expert handoff.

Build the **grounded answer and substitution experience**: a polished Flutter workspace where a cook asks “I don't have lemon—can I use vinegar?”, confirms relevant missing facts, sees a source-backed answer, and explicitly chooses whether to use the suggested substitution. Preserve live video, audio, GenUI, timers, and watch mode; other agents own those.

## Start

Repository: `git@github.com:terryhh/SousSight.git` (private; your GitHub account needs access).

```sh
git clone git@github.com:terryhh/SousSight.git
cd SousSight
git fetch origin
git switch -c agy/cooking-research origin/codex/agy-cooking-research
flutter pub get
```

Read `AGENTS.md` and `lib/core/cooking_research.dart`. The latter is your provider-independent contract. A basic Gemini + Google Search implementation is being built in parallel; your UI receives a `CookingResearchClient`, so fake results make your work independent of API credentials. Older instructor-centric spec/handoff text is superseded by this document and the user's correction.

## Files you own

- `lib/research/**`
- `test/research/**`
- `lib/main_research_demo.dart` (isolated demo entrypoint)
- Optional `docs/RESEARCH.md`.

Do not change shared models/contracts, dependencies, main learner entrypoint, GenUI catalog, Live transports, Firebase rules, or backend functions. Propose integration changes in your PR description. Work on your own branch/worktree.

## Public integration API

Expose `CookingResearchPanel` in `lib/research/cooking_research_panel.dart`. Constructor parameters:

- `required CookingResearchClient client`
- `required CookingResearchQuery query`
- `required void Function(String fact) onCookConfirmed`
- `void Function(CookingCitation citation)? onOpenSource`

Use the existing query/result/citation contract. Keep HTTP, Gemini credentials, and provider setup out of the widget. Codex will connect it to the live workspace and generated panels.

## Required behavior

1. Show loading, answer, sources, clarification, and retry states. Keep the original question visible. A retry cannot apply an older result over a newer question.
2. If the result contains `clarifyingQuestion`, ask the cook in a short editable field. Submit a new research query containing that answer and the existing confirmed facts. Never invent an answer or treat a camera guess as confirmed.
3. Show source titles with clickable citation callbacks; only allow valid HTTPS links. Distinguish answers without returned citations from source-backed answers. Never fabricate a source to fill an empty list.
   Preserve the provider's `searchSuggestionsHtml` attribution using the isolated `SearchSuggestions` widget built alongside the basic client; do not discard required Google Search suggestions or render model-authored HTML as attribution.
4. For a substitution question, let the cook explicitly confirm a chosen fact such as “Using 1 tbsp lemon juice instead of vinegar.” Use an editable confirmation field; the cook reviews it before `onCookConfirmed` fires. The widget must never silently modify the recipe, mark ingredients present, or claim food is safe from an image.
5. Keep text readable on a phone, with generous tap targets. On desktop, use available width without stretching reading lines excessively. Provide an obvious close/dismiss integration affordance if needed, without destroying a pending result.
6. Build a camera-free, clearly labelled demo using fake clients: missing lemon → clarification → cited answer → cook confirms; no citations; timeout/retry; and a late response to an old question. Do not claim the scripted demo called Google.

## Verify and deliver

- `flutter analyze` passes.
- Meaningful tests cover clarification preserving context, stale-result rejection, citation validation, retry preserving the question, and explicit-only confirmation.
- `flutter build web -t lib/main_research_demo.dart` passes.
- Check the demo at narrow and desktop widths; include screenshots in the PR.
- Push `agy/cooking-research` and open a draft PR against `codex/agy-cooking-research`. Codex will retarget it onto the implementation stack before integration. Do not merge other branches, deploy, or send messages.

Paste this document into AGY and say: **“Implement this task on the specified branch. The cook supplies human direction; there are no instructors. Finish the feature, validate it, and open the draft PR.”**
