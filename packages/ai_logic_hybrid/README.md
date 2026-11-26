# ai_logic_hybrid

Unofficial, in-repo Flutter plugin used by SousSight. It exposes one Dart API over the official
Firebase AI Logic hybrid inference SDKs:

- Web: Firebase JS SDK `firebase/ai` (Chrome built-in Gemini Nano, cloud fallback)
- Android: `firebase-ai` + `firebase-ai-ondevice` (Gemini Nano via AICore, cloud fallback)
- iOS: `FirebaseAILogic` `HybridModel` (Apple Foundation Models, cloud fallback)

The contract is specified in `docs/buildhybridai/DESIGN.md` §4 at the repository root. This
package is not published and is not a Google or Firebase product.
