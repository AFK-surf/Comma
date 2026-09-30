import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// The Activity timeline scrolls sideways on purpose when the viewport is too
// narrow for the label column plus a readable lane. It must not scroll for
// nothing: a block at the very end of a lane is still at least as wide as its
// own 1px borders, so before `.act-lane` kept 2px clear on the right, one
// sliver there grew a scrollbar across a desktop-width page. Only a real
// browser can see that, hence this test. The CSS is read from the LiveView so
// the geometry under test is the one that ships.
const source = readFileSync(resolve(__dirname, '../../lib/salix_web/dashboard/live/runtime_health_live.ex'), 'utf8');
const css = source.slice(source.indexOf('.act-timeline'), source.indexOf('</style>', source.indexOf('.act-timeline')));

// One lane: a long block, a call ending at the scale's end, and a record too
// short to paint (0.18% of the scale) sitting on the 100% mark.
const lane = `<div class="act-row">
  <div style="min-width:0"><div class="act-label">dev-max · ses …64588032 · 11 rounds</div></div>
  <div class="act-lane" style="height:38px">
    <div class="act-seg" style="left:0%;width:40%;top:6px"><span class="act-txt">2m 25s</span></div>
    <div class="act-seg" style="left:96%;width:4%;top:6px"><span class="act-txt">7.7s</span></div>
    <div class="act-seg" style="left:99.82%;width:0.18%;top:6px"></div>
  </div>
</div>`;

for (const width of [1920, 1280, 960, 720]) {
  test(`Activity timeline does not scroll sideways at ${width}px`, async ({ page }) => {
    await page.setContent(`<style>*{box-sizing:border-box}${css}</style>
      <div class="act-timeline" style="width:${width}px">
        <div id="activity-scroll" class="act-scroll" tabindex="0">
          <div class="act-table">${lane}</div>
        </div>
      </div>`);

    const overflow = await page
      .locator('#activity-scroll')
      .evaluate((el) => el.scrollWidth - el.clientWidth);

    expect(overflow).toBe(0);
  });
}
