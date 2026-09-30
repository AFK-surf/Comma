import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// Isolate production CSS + hook so geometry coverage does not depend on live
// analytics ingestion. The real LiveView owns the same scrollport and segments.
const source = readFileSync(resolve(__dirname, '../../lib/salix_web/dashboard/live/runtime_health_live.ex'), 'utf8');
const css = source.slice(source.indexOf('.act-timeline'), source.indexOf('</style>', source.indexOf('.act-timeline')));
const hook = readFileSync(resolve(__dirname, '../../assets/js/activity_tooltip.mjs'), 'utf8');

for (const width of [398, 324, 180]) {
  test(`Activity tooltips stay inside a ${width}px scrollport`, async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setContent(`<style>*{box-sizing:border-box}${css}</style>
      <div class="act-timeline" style="width:${width}px">
        <div id="activity-scroll" class="act-scroll" tabindex="0">
          <div class="act-table"><div class="act-lane">
            ${[0, 54, 95].map((left) => `<div class="act-seg" tabindex="0" style="left:${left}%;width:4%">
              <span class="act-txt">60ms</span><div class="act-tip"><div>Activation · 60ms</div>
              <div>The session actor waking the session, re-reading it and rebuilding the runtime configuration.</div></div></div>`).join('')}
          </div></div>
        </div>
      </div>`);
    await page.addScriptTag({ type: 'module', content: `${hook}\nwindow.activityHook = { ...ActivityTooltip, el: document.querySelector('#activity-scroll') }; window.activityHook.mounted();` });
    await page.waitForFunction(() => !!(window as any).activityHook);
    const segments = page.locator('.act-seg');
    const assertInside = async (index: number) => {
      await expect.poll(async () => segments.nth(index).locator('.act-tip').evaluate((tip) => {
        const t = tip.getBoundingClientRect();
        const s = tip.closest('.act-scroll')!.getBoundingClientRect();
        return t.width > 0 && t.left >= s.left - 1 && t.right <= s.right + 1;
      })).toBe(true);
    };
    for (let index = 0; index < 3; index++) {
      await segments.nth(index).focus();
      await assertInside(index);
      await segments.nth(index).hover();
      await assertInside(index);
      await page.mouse.move(0, 0);
    }
    // Reposition a focused tooltip when the user scrolls and when the layout
    // resizes, without requiring focus to leave/re-enter the segment.
    await segments.nth(1).focus();
    await page.locator('.act-scroll').evaluate((el) => { el.scrollLeft = 30; });
    await assertInside(1);
    await page.locator('.act-timeline').evaluate((el) => { (el as HTMLElement).style.width = '250px'; });
    await assertInside(1);
    await page.evaluate(() => { (window as any).activityHook.updated(); });
    await assertInside(1);
    await page.locator('.act-scroll').focus();
    await page.mouse.move(0, 0);
    await page.evaluate(() => { (window as any).activityHook.updated(); });
    await page.evaluate(() => { (window as any).activityHook.destroyed(); });
    expect(errors).toEqual([]);
  });
}
