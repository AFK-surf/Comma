import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import "@comma/test-utils/browser-commands";

import { renderCodeHighlightTokens } from "@comma/ui/components/markdown-stream/shikiHighlightTokens";
import { render } from "@comma/test-utils/render";
import { afterEach, expect, it } from "vitest";
import { commands, page, userEvent } from "vitest/browser";
import { Code } from "../CodingSession";

const PageWorker = window.Worker;
afterEach(() => {
  window.Worker = PageWorker;
});

it("scrolls a step's code sideways under a plain wheel", async () => {
  // Highlighting runs in the page, not in a worker this test's page would load.
  Reflect.deleteProperty(window, "Worker");
  const text = JSON.stringify(
    { done: "A line longer than the panel is wide. ".repeat(4) },
    null,
    2
  );
  // Shiki, its JSON grammar and the light theme load as modules, in real time, which the page's test clock does not
  // wait for: loaded first, the block's own highlight waits on nothing the clock cannot see.
  await renderCodeHighlightTokens(text, "json", "vitesse-light");
  render(
    <div style={{ width: 320 }}>
      <div className="comma-task-coding-detail" data-testid="detail">
        <Code lang="json" text={text} />
      </div>
    </div>
  );
  // Highlighting sets the line's width; the area measures it under the pointer.
  await expect
    .element(page.elementLocator(document.querySelector("pre")!))
    .toHaveAttribute("data-theme");
  await userEvent.hover(page.getByTestId("detail"));
  // The pointer has the area measure its overflow on its next frame, and only then take a plain wheel sideways.
  await expect
    .element(page.elementLocator(document.querySelector(".comma-scroll-area")!))
    .toHaveAttribute("data-has-overflow-x", "true");
  const viewport = document.querySelector(".comma-scroll-area__viewport")!;
  // The wheel reaches the page after the command returns; the area moves in its handler.
  const wheeled = new Promise((resolve) =>
    viewport.addEventListener("wheel", resolve, { once: true })
  );
  await commands.mouseWheel(0, 120);
  await wheeled;
  expect(viewport.scrollLeft).toBe(120);
});
