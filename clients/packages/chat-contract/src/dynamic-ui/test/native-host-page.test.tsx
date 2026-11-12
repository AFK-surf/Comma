/* eslint-disable unicorn/require-post-message-target-origin -- Messages target a MessagePort, not a Window. */
import { stubProperty } from "@comma/test-utils/stub-property";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cardIconNames } from "../cardTypes";
import { installDynamicUiHost } from "../native-host";

afterEach(() => {
  document.body.replaceChildren();
});

describe("the phone host page", () => {
  it("gives the runtime the glyphs and brand answers the app does not have", async () => {
    // The apps start a widget with no icons and keep no logo catalog. Without
    // glyphs a card lost its arrows and marks, and a widget that used
    // <comma-icon> did not start.
    // jsdom frames have no sandbox token list; the page only sets its value.
    stubProperty(HTMLIFrameElement.prototype, "sandbox", {
      get(this: HTMLIFrameElement) {
        return Object.defineProperty({}, "value", {
          set: (tokens: string) => this.setAttribute("sandbox", tokens),
        });
      },
    });
    const host = installDynamicUiHost(() => {});
    const frame = document.querySelector("iframe")!;
    const posted = vi.spyOn(frame.contentWindow!, "postMessage");
    window.dispatchEvent(
      new MessageEvent("message", {
        source: frame.contentWindow,
        data: { type: "comma-ui:ready" },
      })
    );
    await host.start({ payload: {}, icons: { clock: "<svg>app clock</svg>" } });

    const [init, , transfer] = posted.mock.calls.at(-1) as unknown as [
      { type: string; icons: Record<string, string> },
      string,
      MessagePort[],
    ];
    expect(init.type).toBe("comma-ui:init");
    for (const name of [...cardIconNames, "info"])
      expect(init.icons[name]).toContain("<svg");
    // A glyph the app does pass wins.
    expect(init.icons.clock).toBe("<svg>app clock</svg>");

    // A brand the card asks for settles with no logo, so its tile shows an initial.
    const runtime = transfer[0]!;
    const answered = new Promise<unknown>((resolve) => {
      runtime.addEventListener("message", (event) => resolve(event.data));
    });
    runtime.start();
    runtime.postMessage({ type: "brand-icons", names: ["github", 7] });
    expect(await answered).toEqual({ type: "brand-icons", icons: { github: "" } });
    host.stop();
  });
});
