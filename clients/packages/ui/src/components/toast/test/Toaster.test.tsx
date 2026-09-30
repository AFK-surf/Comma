import { afterEach, describe, expect, it, vi } from "vitest";
import { act, render, screen } from "@comma/test-utils/render";
import { toastLayout } from "../../../tokens";
import { Toaster } from "../Toaster";
import {
  claimToastObstructionRight,
  releaseToastObstructionRight,
  toastObstructionRightProperty,
} from "../toastObstruction";
import { setToastsEnabled, toast } from "../toastApi";

// The width is written on the toast host, never on the document root, so a
// per-frame republish invalidates the stack alone.
const obstruction = () =>
  (
    document.querySelector('[data-slot="toast-host"]') as HTMLElement
  ).style.getPropertyValue(toastObstructionRightProperty);

// Deliberately renders the real sonner Toaster. `toast.test.tsx` mocks the
// `sonner` module, so these assertions cannot live there — that mock's factory
// exports only `toast`, and importing this component under it yields undefined.
//
// Sonner's store is a module-level singleton that outlives each render, so every
// case dismisses what it published. It also renders no list at all until the
// first toast, which is why each case publishes before querying.
describe("Toaster", () => {
  afterEach(() => {
    setToastsEnabled(true);
    act(() => {
      toast.dismissAll();
    });
  });

  it("anchors the stack to the window's own bottom-right corner", async () => {
    const { container } = render(<Toaster />);
    act(() => {
      toast.info("Copied message", { description: "Message copied to clipboard" });
    });
    expect(await screen.findByText("Copied message")).toBeInTheDocument();
    expect(screen.getByText("Message copied to clipboard")).toBeInTheDocument();

    // The clipping this replaced came from sizing a native window to the card's
    // border box. In-app the stack is a viewport-fixed sibling of the shell, so
    // the card and its shadow are bounded by the window, not by a box drawn
    // tightly around the card.
    const stack = container.querySelector("[data-sonner-toaster]") as HTMLElement;
    expect(stack).toHaveAttribute("data-y-position", "bottom");
    expect(stack).toHaveAttribute("data-x-position", "right");
    expect(stack).toHaveClass("[-webkit-app-region:no-drag]");
    // The right inset carries the obstruction term, which resolves to 0px while
    // nothing claims the corner — see the native-surface case below.
    expect(stack.style.getPropertyValue("--offset-right")).toBe(
      `calc(${toastLayout.viewportInset}px + var(${toastObstructionRightProperty}, 0px))`
    );
    expect(stack.style.getPropertyValue("--offset-bottom")).toBe(
      `${toastLayout.viewportInset}px`
    );
    expect(stack.style.getPropertyValue("--mobile-offset-right")).toBe(
      `calc(${toastLayout.viewportInset}px + var(${toastObstructionRightProperty}, 0px))`
    );
    expect(stack.style.getPropertyValue("--mobile-offset-bottom")).toBe(
      `${toastLayout.viewportInset}px`
    );
  });

  it("steps clear of a native surface that claims the window's right edge", async () => {
    // Electron composites a `WebContentsView` (the sidebar browser) above the
    // renderer's DOM, so a toast cannot stack over one at any z-index. The
    // claim moves the stack instead, and the card narrows by the same amount so
    // it cannot spill off the opposite edge of a small window.
    const { container } = render(<Toaster />);
    act(() => {
      toast.info("Copied message");
    });
    expect(await screen.findByText("Copied message")).toBeInTheDocument();

    const stack = container.querySelector("[data-sonner-toaster]") as HTMLElement;

    claimToastObstructionRight("browser-sidebar", 452);
    expect(obstruction()).toBe("452px");
    expect(stack.style.getPropertyValue("--width")).toContain(
      `var(${toastObstructionRightProperty}, 0px)`
    );

    // Widest claim wins while both are live, and releasing one falls back to
    // the other rather than to the window corner.
    claimToastObstructionRight("wider-surface", 600);
    expect(obstruction()).toBe("600px");
    releaseToastObstructionRight("wider-surface");
    expect(obstruction()).toBe("452px");

    releaseToastObstructionRight("browser-sidebar");
    expect(obstruction()).toBe("0px");
  });

  it("sources its geometry from tokens and carries the Comma class hooks", async () => {
    const { container } = render(<Toaster />);
    act(() => {
      toast.info("Saved");
    });
    expect(await screen.findByText("Saved")).toBeInTheDocument();

    const stack = container.querySelector("[data-sonner-toaster]") as HTMLElement;
    // Sonner injects its own unlayered rules at import time, so every Comma motion
    // override is scoped by a `comma-` class rather than relying on source order.
    expect(stack).toHaveClass("comma-sonner-toaster");
    expect(container.querySelector("[data-sonner-toast]")).toHaveClass(
      "comma-sonner-toast"
    );
    expect(stack.style.getPropertyValue("--gap")).toBe(`${toastLayout.stackGap}px`);
    expect(stack.style.getPropertyValue("--width")).toContain(
      "var(--toast-width-single)"
    );
  });

  it("hosts the stack on a top-layer surface a modal leaves usable", async () => {
    render(<Toaster />);
    act(() => {
      toast.info("Copied message");
    });
    await screen.findByText("Copied message");

    // React Aria reads this marker: an open modal neither inerts the stack nor
    // treats a press on a toast as a press outside itself.
    const stack = document.querySelector("[data-sonner-toaster]");
    expect(stack?.closest('[data-react-aria-top-layer="true"]')).not.toBeNull();
  });

  it("drops every toast while the surface is disabled", async () => {
    // Side Chat and its child windows mount no Toaster. Sonner's store is a
    // module-level singleton whose auto-dismiss timers live in this component,
    // so a toast raised there would otherwise be retained for the window's
    // whole lifetime.
    setToastsEnabled(false);
    const { container } = render(<Toaster />);
    act(() => {
      toast.info("Copied message");
    });

    await act(async () => {});
    expect(screen.queryByText("Copied message")).toBeNull();
    expect(container.querySelector("[data-sonner-toast]")).toBeNull();
  });
  it("replaces indefinite progress in place and retires the result after its normal five seconds", async () => {
    vi.useFakeTimers();
    try {
      render(<Toaster />);
      act(() => {
        toast("Downloading…", {
          id: "download-transition",
          duration: Infinity,
          testId: "download-progress",
        });
      });
      await act(() => vi.advanceTimersByTimeAsync(0));
      expect(screen.getByTestId("download-progress")).toBeInTheDocument();
      act(() => {
        toast.success("Download complete", {
          id: "download-transition",
          testId: "download-completed",
        });
      });
      await act(() => vi.advanceTimersByTimeAsync(0));
      expect(screen.queryByTestId("download-progress")).not.toBeInTheDocument();
      expect(screen.getByTestId("download-completed")).toBeInTheDocument();
      await act(() => vi.advanceTimersByTimeAsync(4999));
      expect(screen.getByTestId("download-completed")).toBeInTheDocument();
      // Sonner animates exit after the five-second display duration.
      await act(() => vi.advanceTimersByTimeAsync(1001));
      expect(screen.queryByTestId("download-completed")).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });
});
