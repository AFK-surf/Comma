import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { initializeCommaI18n } from "@comma/i18n";
import { render } from "@comma/test-utils/render";
import {
  startTransition,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { afterEach, beforeEach, expect, it } from "vitest";
import { TaskPanelBody, useTaskPanelFold } from "../TaskPanelFold";
import type { TaskDetailsPopoverProps } from "../TaskDetailsPopover";

beforeEach(() => {
  initializeCommaI18n(["en"]);
  // Long enough that a transition the body starts is still running when the
  // test reads it, however slowly the runner's frames come.
  document.documentElement.style.setProperty("--motion-duration-panel-enter", "10s");
  document.documentElement.style.setProperty("--motion-duration-panel-exit", "10s");
});

afterEach(() => {
  document.documentElement.style.removeProperty("--motion-duration-panel-enter");
  document.documentElement.style.removeProperty("--motion-duration-panel-exit");
  document.body.replaceChildren();
});

const noop = () => {};

const panel = {
  conversation: {
    group_id: "grp_fold",
    id: "cnv_task",
    kind: "agent_task",
    labels: [],
    status: "running",
    title: "Folded task",
  },
  groupId: "grp_fold",
} as unknown as TaskDetailsPopoverProps;

/** A Task host as wide as `width`: below 1024px the column folds. */
function TaskHost({ width }: { width: number }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const fold = useTaskPanelFold(hostRef, true);
  return (
    <div ref={hostRef} style={{ display: "flex", height: 400, width }}>
      <TaskPanelBody floatingTrigger fold={fold} panel={panel}>
        <div data-testid="thread" />
      </TaskPanelBody>
    </div>
  );
}

/**
 * Resolves when the details column's content starts its reveal or fade, the
 * motion a fold keeps. The event comes in the frame's animation step, outside
 * the resize delivery the fold lands in, so the test may resize or unmount
 * the host from there.
 */
const nextReveal = (body: HTMLElement) =>
  new Promise<void>((resolve) => {
    const inner = body.querySelector<HTMLElement>(".comma-task-panel-inner")!;
    const onRun = (event: TransitionEvent) => {
      if (event.target !== inner || event.propertyName !== "opacity") return;
      inner.removeEventListener("transitionrun", onRun);
      resolve();
    };
    inner.addEventListener("transitionrun", onRun);
  });

const trackTransitions = (body: HTMLElement) =>
  body
    .getAnimations()
    .filter(
      (animation): animation is CSSTransition =>
        animation instanceof CSSTransition &&
        animation.transitionProperty === "grid-template-columns"
    );

it("mounts a narrow Task folded, with the thread at full width from the first frame", () => {
  // A Chat Sidebar tab switch remounts the conversation in a rail narrower
  // than the breakpoint.
  const view = render(<TaskHost width={600} />);
  const body = view.getByTestId("task-conversation-body");
  const thread = view.container.querySelector<HTMLElement>(".comma-chat-main")!;

  expect(body.dataset.panelOpen).toBe("false");
  // Measuring laid the body out with the open default; folding from it must
  // not play the close transition that squeezes the thread meanwhile.
  expect(trackTransitions(body)).toHaveLength(0);
  expect(thread.getBoundingClientRect().width).toBe(600);
});

it("lands a later fold in one layout, with no track transition", async () => {
  const view = render(<TaskHost width={600} />);
  const body = view.getByTestId("task-conversation-body");
  const thread = view.container.querySelector<HTMLElement>(".comma-chat-main")!;
  expect(body.dataset.panelOpen).toBe("false");

  // A sidebar drag or window resize widens the host past the breakpoint. The
  // fold follows the width in the same layout, so the thread takes its new
  // width once instead of at every frame of a track transition; only the
  // column's content reveals.
  const opened = nextReveal(body);
  view.rerender(<TaskHost width={1400} />);
  await opened;
  expect(body.dataset.panelOpen).toBe("true");
  expect(trackTransitions(body)).toHaveLength(0);
  expect(thread.getBoundingClientRect().width).toBeLessThan(1400);

  // And narrowing it again folds the same way.
  const folded = nextReveal(body);
  view.rerender(<TaskHost width={600} />);
  await folded;
  expect(body.dataset.panelOpen).toBe("false");
  expect(trackTransitions(body)).toHaveLength(0);
  expect(thread.getBoundingClientRect().width).toBe(600);
});

it("lands the measured fold in the commit of a transition mount, before its passive effects run", async () => {
  // A transition mount runs its passive effects in a later task, which the
  // browser may paint before. The body must already be folded when the
  // commit that mounts it ends.
  const actEnvironment = globalThis as {
    IS_REACT_ACT_ENVIRONMENT?: boolean | undefined;
  };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = false;
  let committed: (value: string | undefined) => void = noop;
  const atCommitEnd = new Promise<string | undefined>((resolve) => {
    committed = resolve;
  });
  function Probe({ children }: { children: ReactNode }) {
    const ref = useRef<HTMLDivElement>(null);
    // Runs after the host's layout effect has measured; the microtask runs
    // once the commit (and the sync work it scheduled) is done.
    useLayoutEffect(() => {
      queueMicrotask(() =>
        committed(
          ref.current?.querySelector<HTMLElement>(
            "[data-testid='task-conversation-body']"
          )?.dataset.panelOpen
        )
      );
    }, []);
    return <div ref={ref}>{children}</div>;
  }
  let show: () => void = noop;
  function Later() {
    const [shown, setShown] = useState(false);
    show = () => startTransition(() => setShown(true));
    return shown ? (
      <Probe>
        <TaskHost width={600} />
      </Probe>
    ) : null;
  }

  try {
    render(<Later />);
    show();
    expect(await atCommitEnd).toBe("false");
  } finally {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
});
