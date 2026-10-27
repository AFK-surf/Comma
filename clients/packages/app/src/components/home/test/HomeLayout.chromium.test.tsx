import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { commaHomeRailFoldsOpen } from "../../shellGeometry";
import { render } from "@comma/test-utils/render";
import { useLayoutEffect } from "react";
import { afterEach, expect, it } from "vitest";
import { HomeLayout, HomeRailFoldProvider } from "../HomeRailFolds";

afterEach(() => document.body.replaceChildren());

/** A descendant that measures the layout in the commit that folds Tasks, as a ScrollArea does. */
function MeasuresLayout({ folded }: { folded: boolean }) {
  useLayoutEffect(() => {
    document
      .querySelector('[data-testid="home-responsive-layout"]')
      ?.getBoundingClientRect();
  }, [folded]);
  return null;
}

function Home({ folded }: { folded: boolean }) {
  return (
    <HomeRailFoldProvider
      state={{
        collapsed: commaHomeRailFoldsOpen,
        folds: { ...commaHomeRailFoldsOpen, tasks: folded },
        toggleCollapsed: () => {},
      }}
    >
      <div className="comma-app-shell">
        <HomeLayout>
          <MeasuresLayout folded={folded} />
        </HomeLayout>
      </div>
    </HomeRailFoldProvider>
  );
}

// The route width that forces a fold (the Chat Sidebar opening, a window drag)
// changes in one step, so the fold lands in that same layout: the chat column
// lays out once for both instead of following a fold frame by frame.
it("lands a fold the route forces in the same commit, even when a descendant measures the layout", () => {
  const view = render(<Home folded={false} />);
  view.rerender(<Home folded />);

  const layout = document.querySelector<HTMLElement>(
    '[data-testid="home-responsive-layout"]'
  )!;
  expect(
    getComputedStyle(layout).getPropertyValue("--comma-home-tasks-fold").trim()
  ).toBe("1");
  expect(document.getAnimations()).toEqual([]);
});
