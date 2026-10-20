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
      {/* The shell sets the fold's transition length. */}
      <div className="comma-app-shell">
        <HomeLayout>
          <MeasuresLayout folded={folded} />
        </HomeLayout>
      </div>
    </HomeRailFoldProvider>
  );
}

it("moves a fold the route forces even when a descendant measures the layout in the same commit", () => {
  const view = render(<Home folded={false} />);
  view.rerender(<Home folded />);

  const fold = document
    .getAnimations()
    .find(
      (animation): animation is CSSTransition =>
        animation instanceof CSSTransition &&
        animation.transitionProperty === "--comma-home-tasks-fold"
    );
  expect(fold).toBeDefined();
});
