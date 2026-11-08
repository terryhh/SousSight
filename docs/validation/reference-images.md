# Real Cooking Reference Photos & Evaluation Fixtures (`SS-022`)

- **Ticket:** [Issue #40 (`SS-022`)](https://github.com/terryhh/SousSight/issues/40) — Prepare real cooking reference photos and evaluation fixtures (`[P1]`)
- **Owner:** Jenna (`@jennajh`)
- **Integration & Model Evaluation Counterpart:** Terry (`@terryhh`) — [`SS-013` (#22)](https://github.com/terryhh/SousSight/issues/22) (*Replace checkpoint placeholders with real visual examples*)
- **Last Updated:** `2026-11-07`
- **Base Commit (`origin/main`):** `d350601`

---

## 1. Scope, Provenance & Food-Safety Guardrails

### Ownership Boundary (`SS-022` vs. `SS-013`)
- **Jenna (`SS-022`) owns:**
  - `assets/reference-cooking/**` (8 web-sized real cooking photographs + `fixtures.json` manifest)
  - `docs/validation/reference-images.md` (this provenance, cue, limitation, and evaluation specification)
- **Terry (`SS-013`) retains:**
  - Wiring replacement target images into `assets/recipes/chickpea_wrap_v1/target_mash.jpg`, `assets/recipes/chickpea_wrap_v1/target_mix.jpg`, and `pubspec.yaml` if needed.
  - Running paid live model evaluations against `devfest-flutter-a59e8`. (The still-image `GeminiAssessmentClient` was removed in SS-034; evaluate through the Live flow.)
- **Verification Honesty (`AGENTS.md`):**
  - **Zero synthetic or AI-generated images** are used in this pack. Every image is a real food photograph captured by a human photographer under an open license (`CC0 1.0`, `CC BY 2.0`, or `CC BY-SA 2.0`).
  - **Zero paid model calls** were executed for this asset-only deliverable (`paidModelCallsExecuted: false`).

### Appearance-Only & Food-Safety Rule
- Checkpoint vision comparisons in SousSight evaluate **visible technique appearance only**:
  - **`cp_mash` (`Mash the chickpeas`):** coarse, crumbly broken pieces vs. whole round chickpeas vs. smooth puree, and whether the bowl interior is clearly visible.
  - **`cp_mix` (`Dress and fold`):** diced vegetables distributed across the bowl and lightly coated vs. clumped toppings or unmixed white dressing pools/streaks, and whether full-bowl framing is clear.
- **Vision cannot establish internal temperature, microbial food safety, freshness, spoilage, or allergen absence.**
  - No reference photo or model output may be represented as proof that food is safe to eat or free of allergens (`egg`, `mustard`, `wheat`, `sesame`, etc.).
  - Any model path that compares these fixtures must treat a safety/allergen concern as out of scope and return a fixed safety reply rather than a visual verdict.

---

## 2. Web-Sized Reference Photo Inventory (`assets/reference-cooking/`)

All 8 photographs were downscaled with high-quality bicubic resampling to match `kPhotoMaxSide = 768` (`lib/core/image_utils.dart`, JPEG quality `75`, `42.8 KB – 59.5 KB` per file) so each fixture stays well below the `60–150 KB` Firestore/inline-payload target in `docs/SPEC.md`. None of the photographs contain faces, hands, or private identifying information.

| Fixture ID | Checkpoint | Role | File Path | Web Dimensions | File Size | SHA-256 (prefix) | License & Creator |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`FIX-MASH-TARGET-01`** | `cp_mash` | Reviewed Target (`IMAGE 1 TARGET`) | `assets/reference-cooking/cp_mash_target_coarse.jpg` | `768 × 614` | `60,877 B` (`59.5 KB`) | `920774463c8af7fb...` | **CC BY-SA 2.0** — `phil_g` |
| **`FIX-MASH-DIFF-WHOLE-01`** | `cp_mash` | Clearly Different (`IMAGE 2 CURRENT`: unmashed) | `assets/reference-cooking/cp_mash_diff_whole_unmashed.jpg` | `768 × 512` | `47,788 B` (`46.7 KB`) | `6ea3b548ccfceec8...` | **CC BY 2.0** — `PersonalCreations.com` |
| **`FIX-MASH-DIFF-SMOOTH-01`** | `cp_mash` | Clearly Different (`IMAGE 2 CURRENT`: smooth paste) | `assets/reference-cooking/cp_mash_diff_smooth_paste.jpg` | `768 × 576` | `59,651 B` (`58.3 KB`) | `45800a465e3d8409...` | **CC0 1.0** — `Dennis S. Hurd` |
| **`FIX-MASH-OBSCURED-01`** | `cp_mash` | Obscured / Uncertain View (`IMAGE 2 CURRENT`) | `assets/reference-cooking/cp_mash_obscured_rim_angle.jpg` | `768 × 614` | `55,940 B` (`54.6 KB`) | `2718683ea1b638f7...` | **CC BY-SA 2.0** — `phil_g` |
| **`FIX-MIX-TARGET-01`** | `cp_mix` | Reviewed Target (`IMAGE 1 TARGET`) | `assets/reference-cooking/cp_mix_target_folded_salad.jpg` | `768 × 576` | `53,194 B` (`51.9 KB`) | `5148bf1ccbbdfe6f...` | **CC BY 2.0** — `Vegan Feast Catering` |
| **`FIX-MIX-DIFF-UNFOLDED-01`** | `cp_mix` | Clearly Different (`IMAGE 2 CURRENT`: unfolded clumps) | `assets/reference-cooking/cp_mix_diff_unfolded_toppings.jpg` | `768 × 512` | `43,813 B` (`42.8 KB`) | `8deb3f098db6ba09...` | **CC BY 2.0** — `Stacy Spensley` |
| **`FIX-MIX-DIFF-POOLED-01`** | `cp_mix` | Clearly Different (`IMAGE 2 CURRENT`: pooled dressing) | `assets/reference-cooking/cp_mix_diff_pooled_dressing.jpg` | `768 × 511` | `54,073 B` (`52.8 KB`) | `e099ac71d8b0fd9d...` | **CC BY 2.0** — `jules:stonesoup` (Jules Clancy) |
| **`FIX-MIX-OBSCURED-01`** | `cp_mix` | Obscured / Uncertain View (`IMAGE 2 CURRENT`) | `assets/reference-cooking/cp_mix_obscured_blur_defocus.jpg` | `768 × 512` | `47,431 B` (`46.3 KB`) | `74b0c924f87d4ceb...` | **CC BY 2.0** — `Stacy Spensley` |

---

## 3. Detailed Fixture Specifications, Provenance & Limitations

### 3.1 Checkpoint `cp_mash` (`stepId: "mash"` — *Mash the chickpeas*)

- **Recipe Step Instruction:** *"Put the drained chickpeas in the bowl and press with a masher or fork until most are broken."*
- **Recipe Target (`cp_mash.target`):** *"Most chickpeas are broken into coarse, crumbly pieces. Fewer than about 10 whole chickpeas are visible. It is chunky, not smooth like hummus."*
- **Recipe Cues (`cp_mash.cues`):** `["few whole chickpeas", "coarse broken pieces", "not a smooth paste"]`
- **Allowed Adjustments (`cp_mash.allowedAdjustments`):**
  - `mash_more` → `"Mash 15-20 more presses"`
  - `mash_side` → `"Focus on the side with more whole chickpeas"`
  - `fine_as_is` → `"Smoother than the target is still fine to use"`

#### `FIX-MASH-TARGET-01` — `assets/reference-cooking/cp_mash_target_coarse.jpg`
- **Role:** Reviewed Target (`IMAGE 1 TARGET` replacement candidate for `assets/recipes/chickpea_wrap_v1/target_mash.jpg`)
- **Source & Rights:**
  - **Original Title:** *Garbanzo Bake - Mixing*
  - **Photographer:** `phil_g`
  - **Source URL:** `https://www.flickr.com/photos/68975104@N00/27978676`
  - **License:** Creative Commons Attribution-ShareAlike 2.0 Generic (`CC BY-SA 2.0`, `https://creativecommons.org/licenses/by-sa/2.0/`)
  - **Privacy / Content Check:** Shows only a yellow mixing bowl, red spoon, and kitchen counter tools; no faces or personal identifiers.
- **Dimensions & Checksum:** `768 × 614 px` (downscaled from `1024 × 819 px`), `60,877 bytes` (`59.5 KB`), SHA-256 `920774463c8af7fb6474a9152ef7876c842496adc9c007103a3715687df88100`
- **Caption:** Yellow mixing bowl with a red spoon holding chickpeas broken into coarse, crumbly pieces.
- **Visible Cue Demonstrated:** Almost all chickpeas are broken into coarse, textured fragments (`few whole chickpeas`, `coarse broken pieces`, `not a smooth paste`).
- **Lighting / Occlusion / Domain Limitations:** Warm indoor kitchen lighting casts a soft shadow on the lower bowl wall, and small herb/onion flecks are present in the photographer's garbanzo mixture.

#### `FIX-MASH-DIFF-WHOLE-01` — `assets/reference-cooking/cp_mash_diff_whole_unmashed.jpg`
- **Role:** Clearly Different Texture (`IMAGE 2 CURRENT` — unmashed whole chickpeas)
- **Source & Rights:**
  - **Original Title:** *rinsed chick peas garbanzo beans in a blue mixing bowl*
  - **Photographer:** `PersonalCreations.com`
  - **Source URL:** `https://www.flickr.com/photos/127294011@N07/16272507722`
  - **License:** Creative Commons Attribution 2.0 Generic (`CC BY 2.0`, `https://creativecommons.org/licenses/by/2.0/`)
  - **Privacy / Content Check:** Overhead shot of bowl on wooden surface; no people or private content.
- **Dimensions & Checksum:** `768 × 512 px` (downscaled from `1024 × 683 px`), `47,788 bytes` (`46.7 KB`), SHA-256 `6ea3b548ccfceec8d3f94af9ff6185e11f14f56dda321d9b1cd249f08e487282`
- **Caption:** White mixing bowl with a blue rim filled with drained, intact whole chickpeas seasoned with black pepper.
- **Visible Cue Demonstrated:** Contrasts directly with `few whole chickpeas` and `coarse broken pieces`: virtually 100% of visible chickpeas are still whole and round.
- **Intended Comparison & Expected Model Output:**
  - Compare as `IMAGE 2 CURRENT` against `FIX-MASH-TARGET-01` (`IMAGE 1 TARGET`).
  - **Expected `outcome`:** `AssessmentOutcome.adjust`
  - **Expected `adjustmentId`:** `"mash_more"` (`"Mash 15-20 more presses"`)
  - **Expected Visible Observations (≤3):**
    1. Almost all chickpeas in the bowl are still whole and round.
    2. Far more than 10 whole chickpeas are visible across the bowl.
    3. Very few broken or crumbly pieces have formed yet.
- **Lighting / Occlusion / Domain Limitations:** A thin drizzle streak appears at the top center and lower layers of chickpeas are occluded by the top layer.

#### `FIX-MASH-DIFF-SMOOTH-01` — `assets/reference-cooking/cp_mash_diff_smooth_paste.jpg`
- **Role:** Clearly Different Texture (`IMAGE 2 CURRENT` — over-mashed smooth paste)
- **Source & Rights:**
  - **Original Title:** *Smashed Chick Peas*
  - **Photographer:** Dennis S. Hurd
  - **Source URL:** `https://www.flickr.com/photos/43296902@N00/4784294128`
  - **License:** Creative Commons CC0 1.0 Universal Public Domain Dedication (`CC0 1.0`, `https://creativecommons.org/publicdomain/zero/1.0/`)
  - **Privacy / Content Check:** Overhead shot of blue plastic mixing bowl and metal fork; no faces or private content.
- **Dimensions & Checksum:** `768 × 576 px` (downscaled from `1024 × 768 px`), `59,651 bytes` (`58.3 KB`), SHA-256 `45800a465e3d840910455fa4f6cff52303b5cec0dcc166b1666c92bc70472f7b`
- **Caption:** Blue fluted mixing bowl with a fork resting in chickpeas mashed into a soft, wet, paste-like consistency.
- **Visible Cue Demonstrated:** Contrasts with `not a smooth paste`: chickpeas have been mashed past coarse crumbs into a wet paste smeared up the left wall of the bowl.
- **Intended Comparison & Expected Model Output:**
  - Compare as `IMAGE 2 CURRENT` against `FIX-MASH-TARGET-01` (`IMAGE 1 TARGET`).
  - **Expected `outcome`:** `AssessmentOutcome.adjust` (or `AssessmentOutcome.uncertain` if flash glare makes texture ambiguous)
  - **Expected `adjustmentId`:** `"fine_as_is"` (`"Smoother than the target is still fine to use"`)
  - **Expected Visible Observations (≤3):**
    1. Chickpeas are mashed into a soft, wet paste with fork smears on the side of the bowl.
    2. No intact whole chickpeas remain visible.
    3. The texture is smoother than the coarse, crumbly target.
- **Lighting / Occlusion / Domain Limitations:** Direct on-camera flash creates bright reflections on the wet surface and fluted blue rim.

#### `FIX-MASH-OBSCURED-01` — `assets/reference-cooking/cp_mash_obscured_rim_angle.jpg`
- **Role:** Obscured / Uncertain View (`IMAGE 2 CURRENT` — off-target framing & bowl-wall occlusion)
- **Source & Rights:**
  - **Original Title:** *Garbanzo Bake - Diced Onions*
  - **Photographer:** `phil_g`
  - **Source URL:** `https://www.flickr.com/photos/68975104@N00/27978405`
  - **License:** Creative Commons Attribution-ShareAlike 2.0 Generic (`CC BY-SA 2.0`, `https://creativecommons.org/licenses/by-sa/2.0/`)
  - **Privacy / Content Check:** Kitchen counter, cutting board, and bowls only; no people or private identifiers.
- **Dimensions & Checksum:** `768 × 614 px` (downscaled from `1024 × 819 px`), `55,940 bytes` (`54.6 KB`), SHA-256 `2718683ea1b638f78033d6ada81be7e1435450df77b94d1860da130ad7f7a766`
- **Caption:** Red cutting board with diced onions in the foreground while the yellow mixing bowl sits in the background at a steep angle where its high wall hides most of the interior.
- **Visible Cue Demonstrated:** Tests the system rule: *"If the bowl is obscured, return needBetterView; if evidence is ambiguous, return uncertain."*
- **Intended Comparison & Expected Model Output:**
  - Compare as `IMAGE 2 CURRENT` against `FIX-MASH-TARGET-01` (`IMAGE 1 TARGET`).
  - **Expected `outcome`:** `AssessmentOutcome.needBetterView` (or `AssessmentOutcome.uncertain`)
  - **Expected `adjustmentId`:** `null`
  - **Expected Visible Observations (≤3):**
    1. The camera is aimed at diced onions on a red cutting board in the foreground.
    2. The yellow mixing bowl sits in the background with its rim blocking most of the interior.
    3. The chickpea texture inside the bowl is overexposed and partially hidden.
- **Lighting / Occlusion / Domain Limitations:** Strong highlight clipping inside the distant yellow bowl makes it impossible to count whole chickpeas or verify coarse texture.

---

### 3.2 Checkpoint `cp_mix` (`stepId: "mix"` — *Dress and fold*)

- **Recipe Step Instruction:** *"Add mayo, mustard, 1 tbsp lemon juice, celery, bell pepper, the drained onion, salt and pepper. Fold from the bottom up until evenly mixed."*
- **Recipe Target (`cp_mix.target`):** *"Red pepper and celery pieces are spread across the whole bowl, everything is lightly coated, and there are no white streaks or pools of dressing."*
- **Recipe Cues (`cp_mix.cues`):** `["vegetables spread evenly", "no dressing streaks", "no pooled liquid"]`
- **Allowed Adjustments (`cp_mix.allowedAdjustments`):**
  - `fold_more` → `"Fold 8-10 more times"`
  - `fold_from_bottom` → `"Scrape from the bottom and fold up"`
  - `add_chickpeas_if_wet` → `"If it looks wet, stir in a few more mashed chickpeas"`

#### `FIX-MIX-TARGET-01` — `assets/reference-cooking/cp_mix_target_folded_salad.jpg`
- **Role:** Reviewed Target (`IMAGE 1 TARGET` replacement candidate for `assets/recipes/chickpea_wrap_v1/target_mix.jpg`)
- **Source & Rights:**
  - **Original Title:** *Autumn Chickpea Salad*
  - **Photographer:** `Vegan Feast Catering`
  - **Source URL:** `https://www.flickr.com/photos/25128194@N02/3986173540` (also mirrored on Wikimedia Commons as `File:Autumn_Chickpea_Salad_(3986173540).jpg`)
  - **License:** Creative Commons Attribution 2.0 Generic (`CC BY 2.0`, `https://creativecommons.org/licenses/by/2.0/`)
  - **Privacy / Content Check:** Close-up of green ceramic bowl and fork tines; no people or private content.
- **Dimensions & Checksum:** `768 × 576 px` (downscaled from `1024 × 768 px`), `53,194 bytes` (`51.9 KB`), SHA-256 `5148bf1ccbbdfe6f762e31095dfb7b9595f8f0cbce933600503a27f212370510`
- **Caption:** Green ceramic bowl of chickpea salad with diced red/orange bell pepper, onion, and herbs spread evenly across the bowl and lightly coated without white dressing streaks.
- **Visible Cue Demonstrated:** `vegetables spread evenly`, `no dressing streaks`, and `no pooled liquid`.
- **Lighting / Occlusion / Domain Limitations:** Warm side lighting; several chickpeas in this licensed photograph are whole or halved rather than pre-mashed, so its reference role in `cp_mix` specifically anchors **even vegetable dispersion and light, streak-free coating**.

#### `FIX-MIX-DIFF-UNFOLDED-01` — `assets/reference-cooking/cp_mix_diff_unfolded_toppings.jpg`
- **Role:** Clearly Different Texture (`IMAGE 2 CURRENT` — unfolded ingredients clumped in separate zones)
- **Source & Rights:**
  - **Original Title:** *chickpea salad sandwich* (prep bowl stage before folding)
  - **Photographer:** Stacy Spensley
  - **Source URL:** `https://www.flickr.com/photos/21001756@N06/4384433772`
  - **License:** Creative Commons Attribution 2.0 Generic (`CC BY 2.0`, `https://creativecommons.org/licenses/by/2.0/`)
  - **Privacy / Content Check:** Close-up inside a white mixing bowl; no faces or private content.
- **Dimensions & Checksum:** `768 × 512 px` (downscaled from `1024 × 683 px`), `43,813 bytes` (`42.8 KB`), SHA-256 `8deb3f098db6ba095b8addd2df8985e11d603fcba663f368dbe455b86f8befe7`
- **Caption:** Mixing bowl where chopped green herbs, diced celery and onion, lemon zest, capers, and mashed/broken chickpeas sit in separate unmixed clusters before folding.
- **Visible Cue Demonstrated:** Contrasts with `vegetables spread evenly`: greens are piled in the lower-left quadrant, diced onion/celery in the center, capers on the right, and chickpeas at the top.
- **Intended Comparison & Expected Model Output:**
  - Compare as `IMAGE 2 CURRENT` against `FIX-MIX-TARGET-01` (`IMAGE 1 TARGET`).
  - **Expected `outcome`:** `AssessmentOutcome.adjust`
  - **Expected `adjustmentId`:** `"fold_more"` (`"Fold 8-10 more times"`) or `"fold_from_bottom"` (`"Scrape from the bottom and fold up"`)
  - **Expected Visible Observations (≤3):**
    1. Chopped green herbs are clumped on the lower left instead of spread across the bowl.
    2. Diced celery, onion, and chickpeas sit in separate unmixed zones.
    3. Ingredients have not been folded together into an even coating.
- **Lighting / Occlusion / Domain Limitations:** Macro depth of field blurs the upper-left chickpeas; this real kitchen prep photo uses capers and lemon zest rather than red bell pepper.

#### `FIX-MIX-DIFF-POOLED-01` — `assets/reference-cooking/cp_mix_diff_pooled_dressing.jpg`
- **Role:** Clearly Different Texture (`IMAGE 2 CURRENT` — unmixed white dressing pools on top)
- **Source & Rights:**
  - **Original Title:** *Chickpea & Za'atar Cabbage Wraps*
  - **Photographer:** `jules:stonesoup` (Jules Clancy)
  - **Source URL:** `https://www.flickr.com/photos/58367355@N00/22469785778`
  - **License:** Creative Commons Attribution 2.0 Generic (`CC BY 2.0`, `https://creativecommons.org/licenses/by/2.0/`)
  - **Privacy / Content Check:** Food on ceramic plates over a wooden table; no people or private content.
- **Dimensions & Checksum:** `768 × 511 px` (downscaled from `1023 × 681 px`), `54,073 bytes` (`52.8 KB`), SHA-256 `e099ac71d8b0fd9d78b15a6a7e187bcf36ffda6c9378301d54f289d88ec56078`
- **Caption:** Chickpeas held in a purple cabbage leaf with two thick white dollops of creamy dressing sitting unmixed on the left and right sides.
- **Visible Cue Demonstrated:** Contrasts directly with `no dressing streaks` and `no pooled liquid`: thick white dressing sits in two unmixed pools rather than coating the mixture evenly.
- **Intended Comparison & Expected Model Output:**
  - Compare as `IMAGE 2 CURRENT` against `FIX-MIX-TARGET-01` (`IMAGE 1 TARGET`).
  - **Expected `outcome`:** `AssessmentOutcome.adjust`
  - **Expected `adjustmentId`:** `"fold_from_bottom"` (`"Scrape from the bottom and fold up"`) or `"fold_more"` (`"Fold 8-10 more times"`)
  - **Expected Visible Observations (≤3):**
    1. Two thick white dollops of dressing sit unmixed on top of the chickpeas.
    2. The chickpeas in the center are not evenly coated with the white dressing.
    3. Diced vegetables are not spread evenly through the bowl.
- **Lighting / Occlusion / Domain Limitations:** Presented in a purple cabbage cup with a second out-of-focus portion in the upper-right background.

#### `FIX-MIX-OBSCURED-01` — `assets/reference-cooking/cp_mix_obscured_blur_defocus.jpg`
- **Role:** Obscured / Uncertain View (`IMAGE 2 CURRENT` — extreme close-up & shallow-focus occlusion)
- **Source & Rights:**
  - **Original Title:** *chickpea salad sandwich* (shallow depth-of-field herb foreground)
  - **Photographer:** Stacy Spensley
  - **Source URL:** `https://www.flickr.com/photos/21001756@N06/4384432428`
  - **License:** Creative Commons Attribution 2.0 Generic (`CC BY 2.0`, `https://creativecommons.org/licenses/by/2.0/`)
  - **Privacy / Content Check:** Macro shot of herbs and bowl interior; no people or private content.
- **Dimensions & Checksum:** `768 × 512 px` (downscaled from `1024 × 682 px`), `47,431 bytes` (`46.3 KB`), SHA-256 `74b0c924f87d4cebbf2df1ac5dbb26880ca92742ff38e0092fac805c02d0deac`
- **Caption:** Extreme close-up where chopped green parsley fills the foreground while the chickpeas and bowl behind it are blurred out of focus.
- **Visible Cue Demonstrated:** Tests camera-distance / defocus handling when the full bowl cannot be inspected.
- **Intended Comparison & Expected Model Output:**
  - Compare as `IMAGE 2 CURRENT` against `FIX-MIX-TARGET-01` (`IMAGE 1 TARGET`).
  - **Expected `outcome`:** `AssessmentOutcome.needBetterView` or `AssessmentOutcome.uncertain` (or low/medium-confidence `AssessmentOutcome.adjust` noting that only an unmixed herb clump is in focus)
  - **Expected `adjustmentId`:** `null` (when `needBetterView` / `uncertain`)
  - **Expected Visible Observations (≤3):**
    1. Chopped green herbs fill almost the entire foreground at close range.
    2. Chickpeas in the upper background are blurred out of focus.
    3. The whole bowl is not clearly visible to confirm even mixing across the batch.
- **Lighting / Occlusion / Domain Limitations:** Shallow macro depth of field (`f/2.8`-style blur) obscures everything outside the front herb cluster.

---

## 4. Handoff Instructions for Terry (`SS-013`)

1. **Machine-Readable Manifest:** Read `assets/reference-cooking/fixtures.json` for all fixture IDs, asset paths, SHA-256 hashes, and expected `Assessment` fields.
2. **Replacing the 857-byte Placeholder Target Assets in `SS-013`:**
   - Copy `assets/reference-cooking/cp_mash_target_coarse.jpg` (`FIX-MASH-TARGET-01`) → `assets/recipes/chickpea_wrap_v1/target_mash.jpg`
   - Copy `assets/reference-cooking/cp_mix_target_folded_salad.jpg` (`FIX-MIX-TARGET-01`) → `assets/recipes/chickpea_wrap_v1/target_mix.jpg`
3. **Recommended `SS-013` Real-Model Evaluation Matrix (`GeminiAssessmentClient` / `gemini-3.8-flash`):**

| Eval Case ID | Checkpoint | `IMAGE 1 TARGET` | `IMAGE 2 CURRENT` | `IMAGE 3 PREVIOUS` | Expected `outcome` | Expected `adjustmentId` | Pass Criteria for `SS-013` |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`EVAL-MASH-01`** | `cp_mash` | `FIX-MASH-TARGET-01` | `FIX-MASH-DIFF-WHOLE-01` | *(none)* | `adjust` | `mash_more` | Names whole-chickpea cue; selects reviewed `mash_more` action; `outOfScope == false`. |
| **`EVAL-MASH-02`** | `cp_mash` | `FIX-MASH-TARGET-01` | `FIX-MASH-DIFF-SMOOTH-01` | `FIX-MASH-DIFF-WHOLE-01` | `adjust` / `uncertain` | `fine_as_is` / `null` | Notes smooth paste texture vs. coarse target; never describes `PREVIOUS` as current state. |
| **`EVAL-MASH-03`** | `cp_mash` | `FIX-MASH-TARGET-01` | `FIX-MASH-OBSCURED-01` | *(none)* | `needBetterView` / `uncertain` | `null` | Rejects obscured background bowl; never fabricates a `matchesTarget` verdict. |
| **`EVAL-MIX-01`** | `cp_mix` | `FIX-MIX-TARGET-01` | `FIX-MIX-DIFF-UNFOLDED-01` | *(none)* | `adjust` | `fold_more` or `fold_from_bottom` | Identifies clumped/unfolded herbs and vegetables; selects reviewed folding action. |
| **`EVAL-MIX-02`** | `cp_mix` | `FIX-MIX-TARGET-01` | `FIX-MIX-DIFF-POOLED-01` | *(none)* | `adjust` | `fold_from_bottom` or `fold_more` | Identifies unmixed white dressing pools; selects reviewed folding action. |
| **`EVAL-MIX-03`** | `cp_mix` | `FIX-MIX-TARGET-01` | `FIX-MIX-OBSCURED-01` | *(none)* | `needBetterView` / `uncertain` | `null` | Flags close-up blur/partial bowl view; never claims `matchesTarget` or food safety. |
