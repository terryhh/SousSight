// The SousSight hero journey, driven through Flutter's semantics tree in the
// installed Chrome with a fake camera and microphone:
//
//   home -> Type it -> "bread, peanut butter, banana" -> Find my meal ->
//   result + source badge -> Cook Peanut Butter Sandwich -> cooking screen ->
//   ask a question (Coach Lite) -> Watch my food -> "What was sent" ledger ->
//   On-device AI sheet
//
// Two build modes. A rehearsal build (--dart-define=FAKE_BACKEND=true) has no
// hybrid runtime, so Coach Lite, the local watch, the ledger and the
// On-device AI sheet are not in it; the journey asserts the rehearsal's own
// answers there instead and says so in report.json. A real build has them.
// Automation Chrome has no Gemini Nano, so a real build shows its
// unavailable/cloud states, and AI requests are aborted unless E2E_ALLOW_AI=1.
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

const PANTRY = 'bread, peanut butter, banana';
const QUESTION = 'How thick should I spread the peanut butter?';
const requestedMode = process.env.E2E_MODE ?? 'auto';
const allowAi = process.env.E2E_ALLOW_AI === '1';

test('hero journey', async ({ page }, testInfo) => {
  const project = testInfo.project.name;
  await page.goto('/');
  await enableSemantics(page);

  // ---- 1. Home -------------------------------------------------------------
  const rehearsalBanner = seen(page, /^Rehearsal mode ·/);
  await expect(page.getByRole('button', { name: 'Find my meal' })).toBeVisible({
    timeout: 60_000,
  });
  const detected = (await rehearsalBanner.isVisible()) ? 'rehearsal' : 'real';
  const mode = requestedMode === 'auto' ? detected : requestedMode;
  expect(detected, `build looks like ${detected}, E2E_MODE=${mode}`).toBe(mode);
  const ev = new Evidence(page, {
    outDir: process.env.E2E_OUT,
    project,
    mode,
  });
  await ev.guardNetwork({ allowAi });
  await ev.instrumentMedia();
  // Listeners attach after the first load; reload so they see everything.
  await page.reload();
  await enableSemantics(page);
  await expect(page.getByRole('button', { name: 'Find my meal' })).toBeVisible({
    timeout: 60_000,
  });

  try {
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
    await page.getByRole('button', { name: 'Send message' }).click();
    if (mode === 'rehearsal') {
      // No hybrid runtime in rehearsal, so no Coach Lite: the coordinator
      // answers that the Live coach is needed (cooking_coordinator.say).
      await expect(
        seen(page, /Connect the live coach to talk or type a question/),
      ).toBeVisible();
      ev.note('rehearsal: Coach Lite absent (no hybrid runtime); got the Live-coach alert');
      const reply = seen(page, /Connect the live coach to talk or type a question/);
      ev.note(`coach reply visible without scrolling: ${await inViewport(page, reply)}`);
      await ev.shot('coach-question-sent');
      await bringIntoView(page, reply);
    } else {
      // Real build: Coach Lite runs. Without Gemini Nano it either asks to
      // send to the cloud (declined here), is blocked (the recipe's own step
      // text plus a reason, coach_lite.dart _blockedSentence), or answers
      // with a source badge. Any of these is an expected state.
      const consent = page.getByRole('button', { name: "Don't send" });
      const blocked = seen(
        page,
        /on-device coach (is still downloading|can't|isn't ready|is not available|could not answer)|can't run the on-device coach|Nothing was sent\./,
      );
      const outcome = await Promise.race([
        consent.waitFor({ timeout: 45_000 }).then(() => 'consent'),
        page
          .getByRole('button', { name: /^Where this ran:/ })
          .first()
          .waitFor({ timeout: 45_000 })
          .then(() => 'answered'),
        blocked.waitFor({ timeout: 45_000 }).then(() => 'blocked'),
      ]).catch(() => 'none');
      if (outcome === 'blocked') {
        ev.note(`coach lite blocked: ${(await blocked.textContent())?.slice(0, 200)}`);
        ev.note(`coach reply visible without scrolling: ${await inViewport(page, blocked)}`);
      }
      ev.note(`coach lite outcome: ${outcome}`);
      await ev.shot('coach-lite-after-send', { settleMs: 1500 });
      if (outcome === 'consent') {
        await consent.click();
        ev.note('declined the cloud consent prompt; nothing was sent');
      }
      expect(
        outcome,
        'Coach Lite answered, asked for consent, or said why it could not',
      ).not.toBe('none');
      if (outcome === 'blocked') await bringIntoView(page, blocked);
    }
    await ev.shot('coach-reply');

    // ---- 7. Watch my food (fake camera) --------------------------------------
    const watch = page.getByRole('button', { name: /Watch my food/ });
    await bringIntoView(page, watch, { top: 0.4, bottom: 0.75 });
    // The camera card's placeholder text marks the preview region.
    const placeholder = seen(page, 'Your counter is the canvas');
    const before = await placeholder.boundingBox();
    expect(before, 'empty camera card is shown before the watch').not.toBeNull();
    await watch.click();
    if (mode === 'rehearsal') {
      await expect(
        seen(page, /Watch needs a real camera connection/),
      ).toBeVisible();
      ev.note('rehearsal: watch does not open the camera (by design); preview check skipped');
      await ev.shot('watch-rehearsal');
    } else {
      // A real build opens the fake camera for the on-device watch, or says
      // why it can't (automation Chrome has no Gemini Nano, so it can't).
      const refused = seen(
        page,
        /can't look at photos|watch could not start|camera could not start|so I can't watch|isn't ready yet|still downloading|could not start a watch/,
      );
      const watchOutcome = await Promise.race([
        placeholder
          .waitFor({ state: 'hidden', timeout: 30_000 })
          .then(() => 'preview'),
        refused.waitFor({ timeout: 30_000 }).then(() => 'refused'),
      ]).catch(() => 'none');
      ev.note(`watch outcome: ${watchOutcome}`);
      await page.waitForTimeout(1000);
      ev.note(`getUserMedia calls so far: ${JSON.stringify(await ev.mediaCalls())}`);
      if (watchOutcome === 'preview') {
        await page.waitForTimeout(1500);
        const stats = await regionStats(page, before);
        ev.note(`watch preview region stats: ${JSON.stringify(stats)}`);
        await ev.shot('watch-preview');
        expect(
          stats.gradientShare,
          'camera preview shows an image, not the empty gradient',
        ).toBeLessThan(0.5);
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
        ev.note('PREVIEW CHECK NOT RUN: the watch did not open the camera');
        expect(watchOutcome, 'Watch my food opened the camera or said why not').toBe(
          'refused',
        );
        // On a device that can run the on-device watch, require the preview.
        expect(
          process.env.E2E_REQUIRE_PREVIEW !== '1',
          'E2E_REQUIRE_PREVIEW=1 but the camera preview never appeared',
        ).toBe(true);
      }
    }

    // ---- 8. "What was sent" ledger --------------------------------------------
    const ledgerButton = page.getByRole('button', { name: 'What was sent' });
    const onDeviceButton = page.getByRole('button', { name: 'On-device AI' });
    if (mode === 'rehearsal') {
      await expect(ledgerButton).toHaveCount(0);
      await expect(onDeviceButton).toHaveCount(0);
      ev.note(
        'rehearsal: "What was sent" and "On-device AI" are absent (HybridHeaderButtons needs a hybrid runtime)',
      );
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
      await expect(
        page.getByRole('heading', { name: 'On-device AI' }).first(),
      ).toBeVisible();
      await ev.shot('on-device-ai-sheet', { settleMs: 1500 });
      await page.keyboard.press('Escape');
    }

    // ---- Final state ----------------------------------------------------------
    await ev.shot('end');
  } catch (error) {
    await ev.shot('failure-state', { settleMs: 200 }).catch(() => {});
    throw error;
  } finally {
    const report = ev.write();
    await testInfo.attach('report.json', {
      body: JSON.stringify(report, null, 2),
      contentType: 'application/json',
    });
  }

  expect(ev.pageErrors, 'no uncaught page errors').toEqual([]);
  expect(ev.forbidden, 'rehearsal made no Firebase/AI requests').toEqual([]);
  const consoleErrors = ev.consoleErrors.filter(
    (text) => !/ERR_BLOCKED_BY_CLIENT/.test(text),
  );
  expect(consoleErrors, 'no console errors').toEqual([]);
});
