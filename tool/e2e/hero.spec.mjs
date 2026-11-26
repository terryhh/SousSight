// The SousSight hero journey, driven through Flutter's semantics tree in the
// installed Chrome with a fake camera and microphone:
//
//   home -> Type it -> "bread, peanut butter, banana" -> Find my meal ->
//   result + source badge -> Cook Peanut Butter Sandwich -> cooking screen ->
//   ask a question (Coach Lite) -> Watch my food -> "What was sent" ledger ->
//   On-device AI sheet
//
// Build modes. A rehearsal build (--dart-define=FAKE_BACKEND=true) may or may
// not carry a (simulated) hybrid runtime; when it does not, Coach Lite, the
// local watch, the ledger and the On-device AI sheet are absent and the
// journey checks the rehearsal's own answers instead. Which surfaces exist is
// detected from the page, not assumed from the mode. Automation Chrome has no
// Gemini Nano, so a real build shows its unavailable/cloud states.
//
// The network guard and the evidence listeners are installed before the
// first navigation. With E2E_MODE=auto the first load runs under a
// conservative provisional policy (Firebase, AI, dinner and analytics
// blocked); once the mode is detected the policy is refined, and a real build
// is reloaded so it can reach Firebase.
import { expect, test } from '@playwright/test';
import {
  Evidence,
  enableSemantics,
  bringIntoView,
  inViewport,
  regionStats,
  seen,
  typeInto,
} from './flutter.mjs';
import { configProblems, initialPolicy, looksLikePreview } from './policy.mjs';

const PANTRY = 'bread, peanut butter, banana';
const QUESTION = 'How thick should I spread the peanut butter?';
const requestedMode = process.env.E2E_MODE ?? 'auto';
const allowAi = process.env.E2E_ALLOW_AI === '1';
const requirePreview = process.env.E2E_REQUIRE_PREVIEW === '1';

test('hero journey', async ({ page }, testInfo) => {
  expect(configProblems(process.env), 'e2e configuration').toEqual([]);
  const ev = new Evidence(page, {
    outDir: process.env.E2E_OUT,
    project: testInfo.project.name,
    policy: initialPolicy(requestedMode),
    allowAi,
  });
  await ev.install();

  const findMeal = page.getByRole('button', { name: 'Find my meal' });
  const loaded = async () => {
    await enableSemantics(page);
    await expect(findMeal.or(seen(page, 'Could not connect to your kitchen'))).toBeVisible({
      timeout: 60_000,
    });
  };

  let mode;
  let previewChecked = false;
  try {
    // ---- 1. Home (detect the mode) -------------------------------------------
    await page.goto('/');
    await loaded();
    const detected = (await seen(page, /^Rehearsal mode ·/).isVisible())
      ? 'rehearsal'
      : 'real';
    ev.note(`detected mode: ${detected} (E2E_MODE=${requestedMode})`);
    if (requestedMode !== 'auto') {
      expect(detected, `build looks like ${detected}, E2E_MODE=${requestedMode}`).toBe(
        requestedMode,
      );
    }
    mode = detected;
    const provisionalCount = ev.provisionallyBlocked.length;
    if (ev.refine(mode)) {
      ev.note(`reloading with the real policy (${provisionalCount} requests blocked provisionally)`);
      ev.setAsideProvisionalErrors();
      await page.reload();
      await loaded();
    }
    await expect(findMeal, 'pantry screen loaded').toBeVisible();
    await ev.shot('home');

    // ---- 2. Type it ----------------------------------------------------------
    await page.getByRole('button', { name: 'Type it' }).click();
    const pantryText = page.getByRole('textbox', { name: /canned black beans/ });
    await expect(pantryText).toBeVisible();
    await typeInto(page, pantryText, PANTRY);
    await ev.shot('typed-pantry');

    // ---- 3. Find my meal -> result with a source badge ----------------------
    // A real build without Gemini Nano and without an approved cloud route
    // cannot match ingredients; it says so and offers the recipe list. That
    // is an expected outcome there, never in rehearsal.
    await page.getByRole('button', { name: 'Find my meal' }).click();
    const unavailable = seen(page, /Ingredient matching is unavailable|could not read that answer/);
    const findOutcome = await Promise.race([
      seen(page, 'Your pantry haul')
        .waitFor({ timeout: 60_000 })
        .then(() => 'result'),
      unavailable.waitFor({ timeout: 60_000 }).then(() => 'unavailable'),
    ]).catch(() => 'none');
    ev.note(`find my meal outcome: ${findOutcome}`);
    await ev.shot('pantry-result', { settleMs: 1200 });
    if (mode === 'rehearsal' || findOutcome !== 'unavailable') {
      expect(findOutcome, 'Find my meal produced a result').toBe('result');
    }

    let cook;
    if (findOutcome === 'result') {
      const badge = page.getByRole('button', { name: /^Where this ran:/ }).first();
      await expect(badge, 'result shows a source badge').toBeVisible();
      ev.note(`pantry source badge: ${(await badge.ariaSnapshot()).trim()}`);
      if (mode === 'rehearsal') {
        await expect(badge).toHaveAccessibleName(/simulat/i);
      }
      await bringIntoView(page, badge);
      await ev.shot('pantry-result-badge');
      cook = page.getByRole('button', { name: /^Cook Peanut Butter Sandwich/ });
    } else {
      await bringIntoView(page, unavailable);
      await ev.shot('pantry-unavailable');
      // The "Skip — pick a recipe" list.
      cook = page.getByRole('button', { name: /^Peanut Butter Sandwich/ });
    }

    // ---- 4. Open Peanut Butter Sandwich --------------------------------------
    await bringIntoView(page, cook);
    await ev.shot('open-peanut-butter-sandwich');
    await cook.click();

    // ---- 5. Cooking screen ---------------------------------------------------
    await expect(seen(page, 'Your cooking space')).toBeVisible({
      timeout: 60_000,
    });
    await expect(seen(page, 'Peanut Butter Sandwich')).toBeVisible();
    await ev.shot('cooking-screen', { settleMs: 1500 });

    // ---- 6. Ask a question (Coach Lite) --------------------------------------
    const composer = page.getByRole('textbox', {
      name: /Ask the coach|Ask Coach Lite|Your answer/,
    });
    await expect(composer).toBeVisible();
    await typeInto(page, composer, QUESTION);
    await ev.shot('coach-question-typed');
    // Hybrid surfaces present? (HybridHeaderButtons on the cooking screen.)
    const ledgerButton = page.getByRole('button', { name: 'What was sent' });
    const onDeviceButton = page.getByRole('button', { name: 'On-device AI' });
    const hasHybrid = (await ledgerButton.count()) > 0;
    ev.note(`hybrid surfaces on the cooking screen: ${hasHybrid}`);
    if (!hasHybrid) {
      expect(mode, 'a real build always has the hybrid runtime').toBe('rehearsal');
    }
    const sourceBadge = page.getByRole('button', { name: /^Where this ran:/ }).first();
    expect(await sourceBadge.count(), 'no source badge before asking').toBe(0);
    await page.getByRole('button', { name: 'Send message' }).click();

    // Without a hybrid runtime the coordinator says the Live coach is needed
    // (cooking_coordinator.say). With one, Coach Lite either answers with a
    // source badge, asks to send to the cloud (declined here), or is blocked
    // (the recipe's own step text plus a reason, coach_lite _blockedSentence).
    const liveAlert = seen(page, /Connect the live coach to talk or type a question/);
    const consent = page.getByRole('button', { name: "Don't send" });
    const blocked = seen(
      page,
      /on-device coach (is still downloading|can't|isn't ready|is not available|could not answer)|can't run the on-device coach|Nothing was sent\./,
    );
    const outcome = await Promise.race([
      liveAlert.waitFor({ timeout: 45_000 }).then(() => 'live-alert'),
      consent.waitFor({ timeout: 45_000 }).then(() => 'consent'),
      sourceBadge.waitFor({ timeout: 45_000 }).then(() => 'answered'),
      blocked.waitFor({ timeout: 45_000 }).then(() => 'blocked'),
    ]).catch(() => 'none');
    ev.note(`coach outcome: ${outcome}`);
    const reply = { 'live-alert': liveAlert, answered: sourceBadge, blocked }[outcome];
    if (reply) {
      ev.note(`coach reply: ${(await reply.textContent())?.slice(0, 200)}`);
      ev.note(`coach reply visible without scrolling: ${await inViewport(page, reply)}`);
    }
    await ev.shot('coach-question-sent', { settleMs: 1500 });
    if (outcome === 'consent') {
      await consent.click();
      ev.note('declined the cloud consent prompt; nothing was sent');
    }
    const accepted = hasHybrid ? ['answered', 'consent', 'blocked'] : ['live-alert'];
    expect(accepted, `coach outcome "${outcome}" is expected here`).toContain(outcome);
    if (reply) await bringIntoView(page, reply);
    await ev.shot('coach-reply');

    // ---- 7. Watch my food (fake camera) --------------------------------------
    const watch = page.getByRole('button', { name: /Watch my food/ });
    await bringIntoView(page, watch, { top: 0.4, bottom: 0.75 });
    // The camera card's placeholder text marks the preview region.
    const placeholder = seen(page, 'Your counter is the canvas');
    const before = await placeholder.boundingBox();
    expect(before, 'empty camera card is shown before the watch').not.toBeNull();
    await watch.click();
    // Either the camera card shows frames (real camera, or a rehearsal's
    // simulated frames), or the app says why it cannot watch.
    const refused = seen(
      page,
      /Watch needs a real camera connection|can't look at photos|watch could not start|camera could not start|so I can't watch|isn't ready yet|still downloading|could not start a watch/,
    );
    const watchOutcome = await Promise.race([
      placeholder.waitFor({ state: 'hidden', timeout: 30_000 }).then(() => 'preview'),
      refused.waitFor({ timeout: 30_000 }).then(() => 'refused'),
    ]).catch(() => 'none');
    ev.note(`watch outcome: ${watchOutcome}`);
    await page.waitForTimeout(1000);
    const media = await ev.mediaCalls();
    ev.note(`getUserMedia calls so far: ${JSON.stringify(media)}`);
    if (watchOutcome === 'preview') {
      await page.waitForTimeout(1500);
      const stats = await regionStats(page, before);
      ev.note(`watch preview region stats: ${JSON.stringify(stats)}`);
      await ev.shot('watch-preview');
      expect(
        looksLikePreview(stats),
        `camera preview shows an image, not the empty gradient (${JSON.stringify(stats)})`,
      ).toBe(true);
      previewChecked = true;
      const pause = page.getByRole('button', { name: /Pause watch/ });
      if (await pause.isVisible()) await pause.click();
    } else {
      if (watchOutcome === 'refused') {
        ev.note(`watch refused: ${(await refused.textContent())?.slice(0, 200)}`);
        ev.note(`watch reply visible without scrolling: ${await inViewport(page, refused)}`);
        await ev.shot('watch-refused');
        await bringIntoView(page, refused);
        await ev.shot('watch-refused-message');
      } else {
        await ev.shot('watch-no-response');
      }
      ev.note('PREVIEW CHECK NOT RUN: the camera card never showed frames');
      expect(watchOutcome, 'Watch my food showed frames or said why not').toBe('refused');
    }
    if (mode === 'rehearsal') {
      // The rehearsal banner promises the camera and microphone are not used.
      expect(media, 'rehearsal never opens the camera or microphone').toEqual([]);
    }

    // ---- 8. "What was sent" ledger --------------------------------------------
    if (!hasHybrid) {
      await expect(onDeviceButton).toHaveCount(0);
      ev.note('"What was sent" and "On-device AI" are absent (no hybrid runtime in this rehearsal)');
    } else {
      await bringIntoView(page, ledgerButton.first(), { top: 0, bottom: 0.6 });
      await ledgerButton.first().click({ timeout: 15_000 });
      await expect(seen(page, 'What left this device')).toBeVisible();
      await ev.shot('ledger-sheet', { settleMs: 1000 });
      await page.keyboard.press('Escape');
      await expect(seen(page, 'What left this device')).toBeHidden();

      // ---- 9. On-device AI sheet ----------------------------------------------
      await bringIntoView(page, onDeviceButton.first(), { top: 0, bottom: 0.6 });
      await onDeviceButton.first().click({ timeout: 15_000 });
      await expect(page.getByRole('heading', { name: 'On-device AI' }).first()).toBeVisible();
      await ev.shot('on-device-ai-sheet', { settleMs: 1500 });
      await page.keyboard.press('Escape');
    }

    // ---- Final state ----------------------------------------------------------
    await ev.shot('end');
  } catch (error) {
    await ev.shot('failure-state', { settleMs: 200 }).catch(() => {});
    throw error;
  } finally {
    const report = ev.write({ mode, previewChecked, requirePreview });
    await testInfo.attach('report.json', {
      body: JSON.stringify(report, null, 2),
      contentType: 'application/json',
    });
  }

  // Enforced in every mode, outside the per-step branches.
  if (requirePreview) {
    expect(previewChecked, 'E2E_REQUIRE_PREVIEW=1: the camera preview was checked').toBe(true);
  }
  expect(ev.pageErrors, 'no uncaught page errors').toEqual([]);
  expect(ev.forbidden, 'rehearsal made no Firebase/AI/dinner requests').toEqual([]);
  const consoleErrors = ev.consoleErrors.filter(
    (text) => !/ERR_BLOCKED_BY_CLIENT/.test(text),
  );
  expect(consoleErrors, 'no console errors').toEqual([]);
});
