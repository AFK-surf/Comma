import type { Page } from "@playwright/test";

/**
 * Work counters for interaction budgets. They count the elements an
 * interaction makes React render and the browser restyle or lay out, so the
 * same code gives the same result on a fast or a loaded machine. Wall-clock
 * time does not.
 */

export type ReactRenderWork = {
  /** React commits. */
  commits: number;
  /** Host elements React rendered: mounted, or reconciled with new props. */
  elements: number;
  /** The elements of each commit, in order. */
  commitElements: number[];
  /**
   * For each key attribute, the distinct values of the closest ancestors
   * (list rows, for example) whose elements React rendered.
   */
  keys: Record<string, string[]>;
};

declare global {
  interface Window {
    /** Installed by `installReactRenderCounter`. */
    commaRenderWork?: {
      start(): void;
      /** The work so far, while recording continues. */
      peek(): ReactRenderWork;
      stop(): ReactRenderWork;
    };
  }
}

/**
 * Installs, before the page loads, a React DevTools hook that counts the host
 * elements each commit renders. Production React reports every commit to this
 * hook. An element counts when its props object is new: a bailed-out or
 * memoized subtree keeps its props. Each rendered element is attributed to
 * its closest ancestor with each of `keyAttributes`.
 */
export async function installReactRenderCounter(
  page: Page,
  ...keyAttributes: string[]
) {
  await page.addInitScript((attributes) => {
    type Fiber = {
      child: Fiber | null;
      memoizedProps: unknown;
      sibling: Fiber | null;
      stateNode: unknown;
      tag: number;
    };
    const hostComponent = 5;
    const roots = new Set<{ current: Fiber }>();
    let seen = new WeakSet<object>();
    let recording: ReactRenderWork | undefined;
    let keys = new Map<string, Set<string>>();
    const walk = (root: Fiber, visit: (fiber: Fiber) => void) => {
      const stack: Fiber[] = [root];
      while (stack.length > 0) {
        const fiber = stack.pop()!;
        visit(fiber);
        if (fiber.sibling) stack.push(fiber.sibling);
        if (fiber.child) stack.push(fiber.child);
      }
    };
    const count = (fiber: Fiber) => {
      const props = fiber.memoizedProps;
      if (fiber.tag !== hostComponent || typeof props !== "object" || props === null)
        return;
      if (seen.has(props)) return;
      seen.add(props);
      recording!.elements += 1;
      if (!(fiber.stateNode instanceof Element)) return;
      for (const attribute of attributes) {
        const key = fiber.stateNode.closest(`[${attribute}]`)?.getAttribute(attribute);
        if (key != null) keys.get(attribute)!.add(key);
      }
    };
    Object.assign(window, {
      __REACT_DEVTOOLS_GLOBAL_HOOK__: {
        checkDCE: () => undefined,
        inject: () => 1,
        isDisabled: false,
        onCommitFiberRoot: (_: number, root: { current: Fiber }) => {
          roots.add(root);
          if (!recording) return;
          recording.commits += 1;
          const before = recording.elements;
          walk(root.current, count);
          recording.commitElements.push(recording.elements - before);
        },
        onCommitFiberUnmount: () => undefined,
        onPostCommitFiberRoot: () => undefined,
        renderers: new Map(),
        supportsFiber: true,
      },
      commaRenderWork: {
        start() {
          seen = new WeakSet();
          keys = new Map(attributes.map((attribute) => [attribute, new Set()]));
          for (const root of roots)
            walk(root.current, (fiber) => {
              if (typeof fiber.memoizedProps === "object" && fiber.memoizedProps)
                seen.add(fiber.memoizedProps);
            });
          recording = { commits: 0, elements: 0, commitElements: [], keys: {} };
        },
        peek() {
          return {
            ...recording!,
            commitElements: [...recording!.commitElements],
            keys: Object.fromEntries(
              [...keys].map(([attribute, values]) => [
                attribute,
                [...values].toSorted(),
              ])
            ),
          };
        },
        stop() {
          const result = this.peek();
          recording = undefined;
          return result;
        },
      },
    });
  }, keyAttributes);
}

/** Counts the React work of `action`. Requires `installReactRenderCounter`. */
export async function reactRenderWork(
  page: Page,
  action: () => Promise<unknown>
): Promise<ReactRenderWork> {
  await page.evaluate(() => window.commaRenderWork!.start());
  await action();
  return page.evaluate(() => window.commaRenderWork!.stop());
}

export type BrowserRenderWork = {
  /** The elements of each style recalculation. */
  restyled: number[];
  /**
   * The nodes, by `traceNodeIds` id, that got a new layout object: inserted
   * ones, and existing ones whose layout subtree was rebuilt.
   */
  attached: number[];
};

type TraceEvent = {
  name: string;
  args?: { elementCount?: number; data?: { nodeId?: number; reason?: string } };
};

/**
 * Counts the style and layout work Chromium does while `action` runs, from a
 * trace. Like `reactRenderWork`, it counts what was recomputed, not how long
 * that took.
 */
export async function browserRenderWork(
  page: Page,
  action: () => Promise<unknown>
): Promise<BrowserRenderWork> {
  const cdp = await page.context().newCDPSession(page);
  const work: BrowserRenderWork = { restyled: [], attached: [] };
  cdp.on("Tracing.dataCollected", ({ value }) => {
    for (const { name, args } of value as unknown as TraceEvent[]) {
      if (name === "UpdateLayoutTree" && typeof args?.elementCount === "number")
        work.restyled.push(args.elementCount);
      if (
        name === "LayoutInvalidationTracking" &&
        args?.data?.reason === "Added to layout"
      )
        work.attached.push(args.data.nodeId!);
    }
  });
  try {
    await cdp.send("Tracing.start", {
      categories:
        "devtools.timeline,disabled-by-default-devtools.timeline.invalidationTracking",
      transferMode: "ReportEvents",
    });
    let failed = false;
    let failure: unknown;
    try {
      await action();
    } catch (error) {
      failed = true;
      failure = error;
    }
    // A failed action still ends the trace, so the page is not left tracing,
    // and its error is the one the test reports.
    try {
      const complete = new Promise<void>((resolve) =>
        cdp.once("Tracing.tracingComplete", () => resolve())
      );
      await cdp.send("Tracing.end");
      await complete;
    } catch (error) {
      if (!failed) throw error;
    }
    if (failed) throw failure;
  } finally {
    await cdp.detach();
  }
  return work;
}

/**
 * The ids a trace gives the first element that matches `selector` and every
 * node in it, so a test can tell whether `browserRenderWork` touched them.
 */
export async function traceNodeIds(page: Page, selector: string) {
  const cdp = await page.context().newCDPSession(page);
  try {
    const { result } = await cdp.send("Runtime.evaluate", {
      expression: `document.querySelector(${JSON.stringify(selector)})`,
    });
    if (!result.objectId) throw new Error(`No element matches ${selector}`);
    const { node } = await cdp.send("DOM.describeNode", {
      depth: -1,
      objectId: result.objectId,
    });
    const ids = new Set<number>();
    const visit = ({ backendNodeId, children }: typeof node) => {
      ids.add(backendNodeId);
      children?.forEach(visit);
    };
    visit(node);
    return ids;
  } finally {
    await cdp.detach();
  }
}
