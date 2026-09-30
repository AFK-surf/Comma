import "@comma/ui/styles.css";
import "../../../../../packages/app/src/components/commaAppearance.css";

import {
  ScrollArea,
  type ScrollAreaEdgeEffect,
} from "../../../../../packages/ui/src/components/scroll-area/ScrollArea";
import { StrictMode, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

declare global {
  interface Window {
    scrollAreaFixture?: {
      getSnapshot: () => {
        blurLayerCount: number;
        edgeBlur: string | undefined;
        edgeEndVisible: string | undefined;
        edgeEffect: string | undefined;
        edgeMask: string | undefined;
        edgeMaskEnd: string;
        edgeMaskStart: string;
        edgeStartVisible: string | undefined;
        endBlurFilter: string;
        endBlurSize: number;
        firstItemWidth: number;
        hasOverflowY: string | undefined;
        scrollbarOpacity: string;
        viewportClientWidth: number;
      };
      scrollTo: (top: number) => void;
      setEdgeEffect: (effect: ScrollAreaEdgeEffect) => void;
    };
  }
}

function getFixtureElement<T extends HTMLElement>(selector: string) {
  const element = document.querySelector<T>(selector);

  if (!element) {
    throw new Error(`Missing fixture element: ${selector}`);
  }

  return element;
}

function ScrollAreaFixture() {
  const [edgeEffect, setEdgeEffect] = useState<ScrollAreaEdgeEffect>("blur");

  useEffect(() => {
    window.scrollAreaFixture = {
      getSnapshot: () => {
        const root = getFixtureElement<HTMLElement>("[data-testid='scroll-area']");
        const viewport = getFixtureElement<HTMLElement>(
          "[data-slot='scroll-area-viewport']"
        );
        const firstItem = getFixtureElement<HTMLElement>(
          "[data-testid='scroll-area-item']"
        );
        const scrollbar = getFixtureElement<HTMLElement>(
          "[data-slot='scroll-area-scrollbar'][data-axis='vertical']"
        );
        const endBlurLayer = getFixtureElement<HTMLElement>(
          "[data-slot='scroll-area-edge-blur-end'] .comma-scroll-area__edge-blur-layer:last-child"
        );
        const endBlur = getFixtureElement<HTMLElement>(
          "[data-slot='scroll-area-edge-blur-end']"
        );

        return {
          blurLayerCount: document.querySelectorAll(
            ".comma-scroll-area__edge-blur-layer"
          ).length,
          edgeBlur: root.dataset.edgeBlur,
          edgeEndVisible: root.dataset.edgeEndVisible,
          edgeEffect: root.dataset.edgeEffect,
          edgeMask: root.dataset.edgeMask,
          edgeMaskEnd: viewport.style.getPropertyValue("--scroll-area-edge-mask-end"),
          edgeMaskStart: viewport.style.getPropertyValue(
            "--scroll-area-edge-mask-start"
          ),
          edgeStartVisible: root.dataset.edgeStartVisible,
          endBlurFilter: getComputedStyle(endBlurLayer).backdropFilter,
          endBlurSize: endBlur.getBoundingClientRect().height,
          firstItemWidth: firstItem.getBoundingClientRect().width,
          hasOverflowY: root.dataset.hasOverflowY,
          scrollbarOpacity: getComputedStyle(scrollbar).opacity,
          viewportClientWidth: viewport.clientWidth,
        };
      },
      scrollTo: (top) => {
        const viewport = getFixtureElement<HTMLElement>(
          "[data-slot='scroll-area-viewport']"
        );

        viewport.scrollTop = top;
        viewport.dispatchEvent(new Event("scroll", { bubbles: true }));
      },
      setEdgeEffect,
    };

    return () => {
      delete window.scrollAreaFixture;
    };
  }, [setEdgeEffect]);

  return (
    <main
      style={{
        background: "#f7f7f8",
        color: "#18181b",
        minHeight: "100vh",
        padding: 32,
      }}
    >
      <ScrollArea
        className="rounded-xl border border-primary bg-primary shadow-sm"
        contentClassName="p-4"
        data-testid="scroll-area"
        edgeBlur={{ layers: 4, maxBlur: 14, size: 56 }}
        edgeEffect={edgeEffect}
        edgeMask={{ size: 32 }}
        edgeTransitionDuration={500}
        style={{ height: 260, width: 360 }}
      >
        <div className="flex flex-col gap-3">
          {Array.from({ length: 18 }, (_, index) => (
            <article
              className="rounded-lg border border-secondary bg-secondary px-4 py-3"
              data-testid={index === 0 ? "scroll-area-item" : undefined}
              key={index}
              style={{ height: 72 }}
            >
              <p className="text-sm font-medium text-primary">
                Scroll area item {index + 1}
              </p>
              <p className="mt-1 text-xs text-tertiary">
                Browser fixture content for overlay scroll behavior.
              </p>
            </article>
          ))}
        </div>
      </ScrollArea>
    </main>
  );
}

/**
 * Areas inside areas, the way a transcript holds code blocks and a board holds
 * columns. The browser scrolls all of it; only an overflowing horizontal area
 * maps an ordinary mouse wheel to a sideways scroll.
 */
function WheelRoutingFixture() {
  return (
    <section
      aria-label="Wheel routing fixture"
      style={{ display: "flex", gap: 24, padding: 32 }}
    >
      <ScrollArea data-testid="routing-transcript" style={{ height: 240, width: 360 }}>
        <div className="flex flex-col gap-3 p-4">
          <p style={{ height: 60 }}>Transcript text before the blocks.</p>
          <ScrollArea data-testid="routing-block-fits" orientation="horizontal">
            <pre style={{ height: 60, margin: 0 }}>short();</pre>
          </ScrollArea>
          <ScrollArea data-testid="routing-block-overflows" orientation="horizontal">
            <pre style={{ height: 60, margin: 0, width: 900 }}>a very wide block</pre>
          </ScrollArea>
          <p style={{ height: 600 }}>Transcript text after the blocks.</p>
        </div>
      </ScrollArea>
      <ScrollArea
        data-testid="routing-board"
        orientation="horizontal"
        style={{ height: 240, width: 360 }}
      >
        <div style={{ display: "flex", gap: 16, width: 1200 }}>
          <ScrollArea data-testid="routing-column" style={{ height: 240, width: 240 }}>
            <div style={{ height: 900 }}>A column taller than the board.</div>
          </ScrollArea>
          <div style={{ height: 240, width: 240 }}>Another column.</div>
        </div>
      </ScrollArea>
    </section>
  );
}

/** A transcript's worth of code blocks: one area around sixty areas. */
function NestedAreasFixture() {
  return (
    <ScrollArea data-testid="nested-outer" style={{ height: 240, width: 360 }}>
      <div className="flex flex-col gap-3 p-4">
        {Array.from({ length: 60 }, (_, index) => (
          <ScrollArea key={index} orientation="horizontal">
            <pre style={{ height: 40, margin: 0 }}>block {index + 1}</pre>
          </ScrollArea>
        ))}
      </div>
    </ScrollArea>
  );
}

function StyleInvalidationFixture() {
  useEffect(() => {
    document.documentElement.dataset.commaPointerCursors = "true";
  }, []);
  return (
    <section>
      <div className="group" data-testid="hover-surface" style={{ padding: 20 }}>
        <button
          className="opacity-0 group-focus-within:opacity-50 group-hover:opacity-100"
          data-testid="hover-action"
        >
          Action
        </button>
        <article data-testid="transcript">
          {Array.from({ length: 600 }, (_, index) => (
            <span key={index}>word </span>
          ))}
        </article>
      </div>
      <label data-testid="enabled-label">
        <input type="checkbox" />
        <span>Enabled</span>
      </label>
      <label data-testid="disabled-label">
        <input type="checkbox" disabled />
        <span>Disabled</span>
      </label>
      <button data-testid="cursor-button">
        <span style={{ cursor: "default" }}>Button</span>
      </button>
      <button aria-disabled="true" data-testid="disabled-parent">
        <span style={{ cursor: "text" }}>Disabled parent</span>
      </button>
      <button>
        <span data-comma-functional-cursor style={{ cursor: "col-resize" }}>
          Resize
        </span>
      </button>
    </section>
  );
}

/**
 * Two areas whose first edge state is not "at the start with nothing to show":
 * a transcript that its owner opens at the tail, and a list that overflows on
 * mount. The owner positions again one frame later, as a transcript does when
 * its content settles.
 */
function FirstEdgeStateFixture() {
  const transcriptRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const viewport = transcriptRef.current;
    if (!viewport) return;
    const openAtTail = () => {
      viewport.scrollTop = viewport.scrollHeight;
    };
    openAtTail();
    const frame = requestAnimationFrame(openAtTail);
    return () => cancelAnimationFrame(frame);
  }, []);
  const rows = Array.from({ length: 30 }, (_, index) => (
    <p className="text-sm text-primary" key={index} style={{ height: 32 }}>
      Row {index + 1}
    </p>
  ));
  return (
    <main style={{ display: "flex", gap: 32, padding: 32 }}>
      <ScrollArea
        data-testid="first-edge-transcript"
        edgeEffect="mask"
        edgeMask={{ size: 32 }}
        ref={transcriptRef}
        style={{ height: 240, width: 240 }}
      >
        {rows}
      </ScrollArea>
      <ScrollArea
        data-testid="first-edge-list"
        edgeEffect="blur"
        style={{ height: 240, width: 240 }}
      >
        {rows}
      </ScrollArea>
    </main>
  );
}

// `?routing` and `?nested` show nested areas on their own, so the single-area
// page keeps exactly one ScrollArea for the specs that read it.
const fixturePage = new URLSearchParams(window.location.search);
createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    {fixturePage.has("first-edge") ? (
      <FirstEdgeStateFixture />
    ) : fixturePage.has("invalidation") ? (
      <StyleInvalidationFixture />
    ) : fixturePage.has("routing") ? (
      <WheelRoutingFixture />
    ) : fixturePage.has("nested") ? (
      <NestedAreasFixture />
    ) : (
      <ScrollAreaFixture />
    )}
  </StrictMode>
);
