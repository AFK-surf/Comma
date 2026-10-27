import { afterEach, describe, expect, it } from "vitest";
import pageScript from "../modules/browser-sidebar/agent/page.js?raw";

// The page helpers read rendered text, so they run in a real browser engine.
interface PageHelpers {
  snapshot(options: { scope: string }): { text: string };
}

// The global the page script keeps its helpers and ref table in.
const HELPERS = "__commaAgent";
const pageGlobal = globalThis as unknown as Record<string, unknown>;

function helpers() {
  // oxlint-disable-next-line no-new-func -- The helpers are a page script, evaluated as the driver does.
  new Function(pageScript)();
  return pageGlobal[HELPERS] as PageHelpers;
}

afterEach(() => {
  document.body.replaceChildren();
  delete pageGlobal[HELPERS];
});

describe("in-app browser page helpers", () => {
  it("keeps a flex row's separate texts apart in a link's name", () => {
    // A search result card: plays, comments and duration in one row.
    document.body.innerHTML = `<a href="/video/1"><div style="display: flex">
      <span>2062</span><span>0</span><span>04:39</span></div><h3>Portugal D7</h3></a>`;

    expect(helpers().snapshot({ scope: "full" }).text).toContain(
      'link "2062 0 04:39 Portugal D7"'
    );
  });

  it("keeps a number drawn as one inline-block box per digit whole", () => {
    document.body.innerHTML = `<p>Price <span><span style="display: inline-block">2</span><span style="display: inline-block">0</span><span style="display: inline-block">6</span></span> yuan</p>`;

    expect(helpers().snapshot({ scope: "full" }).text).toContain(
      'paragraph "Price 206 yuan"'
    );
  });

  it("joins inline runs of one word", () => {
    document.body.innerHTML = `<button>Sa<b>ve</b></button>`;

    expect(helpers().snapshot({ scope: "full" }).text).toContain('button "Save"');
  });
});
