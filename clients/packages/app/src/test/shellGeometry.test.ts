import { describe, expect, it } from "vitest";
import {
  commaChatSidebarMinWidth,
  commaHomeContentMinWidth,
  commaHomeGreetFoldWidth,
  commaHomeGreetPreferredMinWidth,
  commaHomeTasksFoldWidth,
  commaHomeTasksFullWidth,
  commaHomeTasksPreferredWidth,
  commaSidebarRailWidth,
  railFitsFrame,
  resolveHomeRailFolds,
} from "../components/shellGeometry";

// Keep the CSS floor and automatic fold thresholds in agreement.
describe("home rail reflow geometry", () => {
  it("matches the route widths the layout reflows and folds across", () => {
    // Rails start at 300px but can reflow to 240px.
    expect(commaHomeGreetPreferredMinWidth).toBe(300);
    expect(commaHomeTasksPreferredWidth).toBe(300);
    expect(commaHomeTasksFullWidth).toBe(1057);
    expect(commaHomeTasksFoldWidth).toBe(997);
    // Greeting folds only when it cannot fit beside chat.
    expect(commaHomeGreetFoldWidth).toBe(681);
    // Both folded, the chat column keeps the whole route down to its floor.
    expect(commaHomeContentMinWidth).toBe(425);
  });
});

describe("resolveHomeRailFolds", () => {
  const open = { greet: false, tasks: false };

  it("folds a rail exactly where its 240px content floor no longer fits", () => {
    expect(resolveHomeRailFolds({ previous: open, routeWidth: 1300 })).toEqual(open);
    expect(
      resolveHomeRailFolds({ previous: open, routeWidth: commaHomeTasksFoldWidth })
    ).toEqual(open);
    expect(resolveHomeRailFolds({ previous: open, routeWidth: 900 })).toEqual({
      greet: false,
      tasks: true,
    });
    expect(
      resolveHomeRailFolds({ previous: open, routeWidth: commaHomeGreetFoldWidth - 1 })
    ).toEqual({ greet: true, tasks: true });
  });

  it("re-opens a folded rail the moment the route fits it again", () => {
    const folded = { greet: true, tasks: true };
    expect(
      resolveHomeRailFolds({ previous: folded, routeWidth: commaHomeGreetFoldWidth })
    ).toEqual({ greet: false, tasks: true });
    expect(
      resolveHomeRailFolds({ previous: folded, routeWidth: commaHomeTasksFoldWidth })
    ).toEqual(open);
  });

  it("reserves the resized Greeting width and releases it when manually collapsed", () => {
    expect(
      resolveHomeRailFolds({ previous: open, routeWidth: 1150, greetWidth: 500 })
    ).toEqual({ greet: false, tasks: true });
    expect(
      resolveHomeRailFolds({
        previous: open,
        routeWidth: 900,
        greetWidth: 500,
        greetCollapsed: true,
      })
    ).toEqual(open);
  });

  it("keeps the same object when nothing changed", () => {
    const previous = { greet: true, tasks: true };
    expect(resolveHomeRailFolds({ previous, routeWidth: 500 })).toBe(previous);
  });
});

const homeHoldsRail = (frameWidth: number, chatSidebarOpen: boolean) =>
  railFitsFrame({
    chatSidebarOpen,
    frameWidth,
    primaryContentMinWidth: commaHomeContentMinWidth,
  });

describe("railFitsFrame", () => {
  const homeFit = commaSidebarRailWidth + commaHomeContentMinWidth;

  it("keeps the rail until the frame is narrower than rail plus route minimum", () => {
    expect(homeHoldsRail(homeFit, false)).toBe(true);
    expect(homeHoldsRail(homeFit - 1, false)).toBe(false);
  });

  it("counts an open Chat Sidebar at its minimum width", () => {
    expect(homeHoldsRail(homeFit + commaChatSidebarMinWidth, true)).toBe(true);
    expect(homeHoldsRail(homeFit + commaChatSidebarMinWidth - 1, true)).toBe(false);
  });

  it("keeps the rail while the frame is unmeasured", () => {
    expect(homeHoldsRail(0, true)).toBe(true);
  });
});
