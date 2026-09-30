import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { act, useState, type ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import {
  RIGHT_SIDEBAR_DEFAULT_WIDTH,
  RIGHT_SIDEBAR_MAX_WIDTH,
  RIGHT_SIDEBAR_MIN_WIDTH,
  RightSidebar,
  RightSidebarToolbarButton,
} from "../RightSidebar";

const tabs = [
  { id: "chat", label: "Chat", panelId: "chat-panel" },
  { id: "browser", label: "Browser", panelId: "browser-panel" },
];

describe("RightSidebar", () => {
  it("renders tabs, panel content, and header actions", () => {
    const handleExpand = vi.fn();
    render(
      <RightSidebarHarness
        headerActionsClassName="pr-8"
        headerActions={
          <RightSidebarToolbarButton
            aria-label="Open chat in main view"
            onClick={handleExpand}
          >
            Expand
          </RightSidebarToolbarButton>
        }
      />
    );

    expect(
      screen.getByRole("complementary", { name: "Chat sidebar" })
    ).toBeInTheDocument();
    const chatTab = screen.getByRole("tab", { name: "Chat" });
    expect(chatTab).toHaveAttribute("aria-selected", "true");
    expect(chatTab).toHaveClass("comma-right-sidebar-tab-selected");
    expect(screen.getByRole("tabpanel", { name: "Chat panel" })).toBeVisible();

    const browserTab = screen.getByRole("tab", { name: "Browser" });
    expect(browserTab).toHaveClass("bg-transparent", "text-quaternary");
    expect(browserTab).not.toHaveClass("comma-right-sidebar-tab-selected");
    fireEvent.click(browserTab);

    expect(browserTab).toHaveAttribute("aria-selected", "true");
    expect(browserTab).toHaveClass("comma-right-sidebar-tab-selected");
    expect(chatTab).not.toHaveClass("comma-right-sidebar-tab-selected");
    expect(screen.getByRole("tabpanel", { name: "Browser panel" })).toBeVisible();

    fireEvent.keyDown(browserTab, { key: "ArrowLeft" });
    expect(screen.getByRole("tab", { name: "Chat" })).toHaveFocus();
    expect(screen.getByRole("tab", { name: "Chat" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    fireEvent.keyDown(chatTab, { key: "ArrowRight" });
    expect(browserTab).toHaveFocus();
    fireEvent.keyDown(browserTab, { key: "Home" });
    expect(chatTab).toHaveFocus();
    fireEvent.keyDown(chatTab, { key: "End" });
    expect(browserTab).toHaveFocus();

    const expandButton = screen.getByRole("button", {
      name: "Open chat in main view",
    });
    expect(expandButton.parentElement).toHaveClass("pr-8");
    fireEvent.click(expandButton);
    expect(handleExpand).toHaveBeenCalledOnce();
  });

  it("resizes a floating panel from the right without reversing pointer or arrow direction", () => {
    render(<RightSidebarHarness resizeEdge="right" />);
    const sidebar = screen.getByTestId("right-sidebar");
    const handle = screen.getByRole("separator", { name: "Resize chat sidebar" });
    expect(handle).toHaveStyle({ right: "-12px" });
    fireEvent.pointerDown(handle, { button: 0, clientX: 600, pointerId: 1 });
    fireEvent.pointerMove(window, { clientX: 680, pointerId: 1 });
    fireEvent.pointerUp(window, { pointerId: 1 });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "520px" });
    fireEvent.keyDown(handle, { key: "ArrowRight" });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "536px" });
    fireEvent.keyDown(handle, { key: "ArrowLeft" });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "520px" });
  });

  it("previews drag geometry without committing shared width until release", async () => {
    const commit = vi.fn();
    const preview = vi.fn();
    render(
      <RightSidebar
        activeTab="chat"
        ariaLabel="Chat sidebar"
        onTabChange={() => {}}
        onWidthChange={commit}
        onWidthPreview={preview}
        resizeEdge="right"
        resizeWidthMultiplier={2}
        width={440}
        open
        tabs={tabs}
      />
    );
    const handle = screen.getByRole("separator", { name: "Resize chat sidebar" });
    fireEvent.pointerDown(handle, { button: 0, clientX: 600, pointerId: 1 });
    fireEvent.pointerMove(window, { clientX: 650, pointerId: 1 });
    await waitFor(() => expect(preview).toHaveBeenLastCalledWith(540));
    expect(commit).not.toHaveBeenCalled();
    expect(handle).toHaveAttribute("aria-valuenow", "540");
    fireEvent.pointerMove(window, { clientX: 675, pointerId: 1 });
    fireEvent.pointerUp(window, { pointerId: 1 });
    expect(preview).toHaveBeenLastCalledWith(590);
    expect(commit).toHaveBeenCalledExactlyOnceWith(590);
  });

  it("maps centered right-edge dragging to double width and reverses immediately at the bound", () => {
    render(<RightSidebarHarness resizeEdge="right" resizeWidthMultiplier={2} />);
    const sidebar = screen.getByTestId("right-sidebar");
    const handle = screen.getByRole("separator", { name: "Resize chat sidebar" });
    fireEvent.pointerDown(handle, { button: 0, clientX: 600, pointerId: 1 });
    fireEvent.pointerMove(window, { clientX: 650, pointerId: 1 });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "540px" });
    fireEvent.pointerMove(window, { clientX: 900, pointerId: 1 });
    fireEvent.pointerMove(window, { clientX: 890, pointerId: 1 });
    fireEvent.pointerUp(window, { pointerId: 1 });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "700px" });
  });

  it("resizes from its left edge with pointer and keyboard controls", () => {
    render(<RightSidebarHarness />);

    const sidebar = screen.getByTestId("right-sidebar");
    const resizeHandle = screen.getByRole("separator", {
      name: "Resize chat sidebar",
    });
    expect(sidebar).toHaveStyle({
      "--comma-chat-sidebar-width": `${RIGHT_SIDEBAR_DEFAULT_WIDTH}px`,
      "--comma-right-sidebar-rendered-width": `min(${RIGHT_SIDEBAR_DEFAULT_WIDTH}px, calc(100vw - var(--comma-window-inset, 0px) - var(--comma-window-inset, 0px)))`,
    });

    fireEvent.pointerDown(resizeHandle, {
      button: 0,
      clientX: 600,
      pointerId: 1,
    });
    expect(sidebar).toHaveAttribute("data-resizing", "true");
    expect(
      document.querySelector(".comma-chat-sidebar-resize-cursor-overlay")
    ).not.toBeNull();

    fireEvent.pointerMove(window, { clientX: 400, pointerId: 2 });
    expect(sidebar).toHaveStyle({
      "--comma-chat-sidebar-width": `${RIGHT_SIDEBAR_DEFAULT_WIDTH}px`,
    });
    fireEvent.pointerMove(window, { clientX: 520, pointerId: 1 });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "520px" });

    fireEvent.pointerUp(window, { pointerId: 2 });
    expect(sidebar).toHaveAttribute("data-resizing", "true");
    fireEvent.lostPointerCapture(resizeHandle, { pointerId: 1 });
    expect(sidebar).toHaveAttribute("data-resizing", "false");
    expect(
      document.querySelector(".comma-chat-sidebar-resize-cursor-overlay")
    ).toBeNull();

    fireEvent.keyDown(resizeHandle, { key: "ArrowRight" });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "504px" });
    fireEvent.keyDown(resizeHandle, { key: "Home" });
    expect(sidebar).toHaveStyle({
      "--comma-chat-sidebar-width": `${RIGHT_SIDEBAR_MIN_WIDTH}px`,
    });
    fireEvent.keyDown(resizeHandle, { key: "End" });
    expect(sidebar).toHaveStyle({
      "--comma-chat-sidebar-width": `${RIGHT_SIDEBAR_MAX_WIDTH}px`,
    });
    fireEvent.doubleClick(resizeHandle);
    expect(sidebar).toHaveStyle({
      "--comma-chat-sidebar-width": `${RIGHT_SIDEBAR_DEFAULT_WIDTH}px`,
    });
  });

  it("keeps floating resize invisible without disabling resizing", () => {
    vi.useFakeTimers();
    render(
      <RightSidebarHarness resizeEdge="right" resizeHandleAppearance="invisible" />
    );
    const handle = screen.getByRole("separator", { name: "Resize chat sidebar" });
    expect(handle).not.toHaveClass("comma-chat-sidebar-resize-handle");
    fireEvent.pointerEnter(handle, {
      pointerType: "mouse",
      clientX: 640,
      clientY: 180,
    });
    act(() => {
      vi.advanceTimersByTime(500);
    });
    expect(
      screen.queryByTestId("comma-chat-sidebar-resize-tooltip")
    ).not.toBeInTheDocument();
    fireEvent.keyDown(handle, { key: "ArrowRight" });
    expect(handle).toHaveAttribute(
      "aria-valuenow",
      String(RIGHT_SIDEBAR_DEFAULT_WIDTH + 16)
    );
    vi.useRealTimers();
  });

  it("shows a cursor-following Drag to resize tooltip on hover", () => {
    vi.useFakeTimers();
    render(<RightSidebarHarness />);

    const resizeHandle = screen.getByRole("separator", {
      name: "Resize chat sidebar",
    });
    expect(resizeHandle).toHaveStyle({ left: "-12px" });
    expect(resizeHandle).toHaveAccessibleDescription("Drag to resize");
    expect(resizeHandle).not.toHaveAttribute("title");
    expect(resizeHandle).toHaveClass("comma-chat-sidebar-resize-handle", "w-4");

    fireEvent.pointerEnter(resizeHandle, {
      clientX: 640,
      clientY: 180,
      pointerType: "mouse",
    });
    expect(
      screen.queryByTestId("comma-chat-sidebar-resize-tooltip")
    ).not.toBeInTheDocument();

    act(() => {
      vi.advanceTimersByTime(300);
    });

    const tooltip = screen.getByTestId("comma-chat-sidebar-resize-tooltip");
    expect(tooltip).toHaveTextContent("Drag to resize");
    expect(tooltip).toHaveAttribute("aria-hidden", "true");

    fireEvent.pointerDown(resizeHandle, {
      button: 0,
      clientX: 640,
      pointerId: 1,
      pointerType: "mouse",
    });
    expect(
      screen.queryByTestId("comma-chat-sidebar-resize-tooltip")
    ).not.toBeInTheDocument();
    expect(
      document.querySelector(".comma-chat-sidebar-resize-cursor-overlay")
    ).not.toBeNull();
  });

  it("cancels a pending resize tooltip when the sidebar closes", () => {
    vi.useFakeTimers();
    const view = render(renderRightSidebarForTooltipLifecycle(true));
    const resizeHandle = screen.getByRole("separator", {
      name: "Resize chat sidebar",
    });

    fireEvent.pointerEnter(resizeHandle, {
      clientX: 640,
      clientY: 180,
      pointerType: "mouse",
    });
    view.rerender(renderRightSidebarForTooltipLifecycle(false));
    act(() => {
      vi.advanceTimersByTime(300);
    });

    expect(
      screen.queryByTestId("comma-chat-sidebar-resize-tooltip")
    ).not.toBeInTheDocument();
  });

  it("removes a visible resize tooltip when the sidebar closes", () => {
    vi.useFakeTimers();
    const view = render(renderRightSidebarForTooltipLifecycle(true));
    const resizeHandle = screen.getByRole("separator", {
      name: "Resize chat sidebar",
    });

    fireEvent.pointerEnter(resizeHandle, {
      clientX: 640,
      clientY: 180,
      pointerType: "mouse",
    });
    act(() => {
      vi.advanceTimersByTime(300);
    });
    expect(screen.getByTestId("comma-chat-sidebar-resize-tooltip")).toBeVisible();

    view.rerender(renderRightSidebarForTooltipLifecycle(false));

    expect(
      screen.queryByTestId("comma-chat-sidebar-resize-tooltip")
    ).not.toBeInTheDocument();
  });

  it("makes a closed sidebar inert and reports the completed exit transition", () => {
    const handleExitComplete = vi.fn();
    const sidebar = (open: boolean) => (
      <RightSidebar
        activeTab="chat"
        ariaLabel="Chat sidebar"
        data-testid="right-sidebar"
        onExitComplete={handleExitComplete}
        onTabChange={vi.fn()}
        onWidthChange={vi.fn()}
        open={open}
        style={{
          transitionDelay: "0ms",
          transitionDuration: "150ms",
          transitionProperty: "width",
        }}
        tabs={tabs}
        width={RIGHT_SIDEBAR_DEFAULT_WIDTH}
      >
        <div>Retained while closing</div>
      </RightSidebar>
    );
    const view = render(sidebar(true));
    view.rerender(sidebar(false));

    const sidebarElement = screen.getByTestId("right-sidebar");
    expect(sidebarElement).toHaveAttribute("aria-hidden", "true");
    expect(sidebarElement).toHaveAttribute("inert");
    expect(sidebarElement).toHaveAttribute("data-open", "false");
    expect(screen.getByText("Retained while closing")).toBeInTheDocument();

    fireEvent.transitionEnd(sidebarElement, { propertyName: "width" });
    expect(handleExitComplete).toHaveBeenCalledOnce();
  });

  it("clamps controlled widths and completes reduced-motion exits", async () => {
    const originalMatchMedia = window.matchMedia;
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn(() => ({ matches: true })),
    });
    const handleExitComplete = vi.fn();
    const props = {
      activeTab: "chat",
      ariaLabel: "Chat sidebar",
      "data-testid": "right-sidebar",
      onExitComplete: handleExitComplete,
      onTabChange: vi.fn(),
      onWidthChange: vi.fn(),
      tabs,
      width: RIGHT_SIDEBAR_MAX_WIDTH + 200,
    };

    try {
      const view = render(<RightSidebar {...props} open />);
      expect(
        screen.getByRole("separator", { name: "Resize chat sidebar" })
      ).toHaveAttribute("aria-valuenow", String(RIGHT_SIDEBAR_MAX_WIDTH));
      expect(screen.getByTestId("right-sidebar")).toHaveStyle({
        "--comma-chat-sidebar-width": `${RIGHT_SIDEBAR_MAX_WIDTH}px`,
      });

      view.rerender(<RightSidebar {...props} open={false} />);
      await waitFor(() => expect(handleExitComplete).toHaveBeenCalledOnce());
    } finally {
      if (originalMatchMedia) {
        Object.defineProperty(window, "matchMedia", {
          configurable: true,
          value: originalMatchMedia,
        });
      } else {
        Reflect.deleteProperty(window, "matchMedia");
      }
    }
  });

  it("exposes closable tabs as sibling keyboard-operable controls", async () => {
    const user = userEvent.setup();
    const handleAddTab = vi.fn();
    const handleTabClose = vi.fn();
    render(
      <RightSidebar
        activeTab="long"
        ariaLabel="Chat sidebar"
        data-testid="right-sidebar"
        onAddTab={handleAddTab}
        onTabChange={vi.fn()}
        onTabClose={handleTabClose}
        onWidthChange={vi.fn()}
        open
        tabs={[
          {
            closable: true,
            id: "long",
            label: "New tab New tab New tab New tab New tab",
            panelId: "long-panel",
          },
        ]}
        width={RIGHT_SIDEBAR_DEFAULT_WIDTH}
      >
        <section aria-label="Long panel" id="long-panel" role="tabpanel">
          panel
        </section>
      </RightSidebar>
    );

    const tab = screen.getByRole("tab", {
      name: "New tab New tab New tab New tab New tab",
    });
    expect(tab).toHaveClass("max-w-[180px]", "gap-xs");
    expect(tab).not.toHaveClass("min-w-[100px]");
    expect(tab).not.toHaveClass("gap-md");
    const label = tab.querySelector(".truncate");
    expect(label).not.toBeNull();
    expect(label).not.toHaveClass("flex-1");

    const closeControl = screen.getByRole("button", {
      name: "Close New tab New tab New tab New tab New tab",
    });
    expect(closeControl).toHaveClass("absolute", "right-xs");
    expect(closeControl).toHaveAttribute("tabindex", "0");
    expect(tab).not.toContainElement(closeControl);
    expect(tab.parentElement).toBe(closeControl.parentElement);

    closeControl.focus();
    await user.keyboard("{Enter}");
    expect(handleTabClose).toHaveBeenCalledWith("long");

    const addTabButton = screen.getByRole("button", { name: "New tab" });
    expect(addTabButton).toHaveClass("size-7");
    fireEvent.click(addTabButton);
    expect(handleAddTab).toHaveBeenCalledOnce();
  });

  it("reveals overflow tabs within their strip without moving the page", () => {
    const readRect = HTMLElement.prototype.getBoundingClientRect;
    const spy = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: HTMLElement) {
        if (this.getAttribute("role") === "tablist") {
          return DOMRect.fromRect({ x: 0, width: 300 });
        }
        if (this.getAttribute("role") === "tab") {
          const viewport = this.closest<HTMLElement>('[role="tablist"]')!;
          return DOMRect.fromRect({
            x: (this.dataset.tab === "browser" ? 500 : 0) - viewport.scrollLeft,
            width: 100,
          });
        }
        return readRect.call(this);
      });
    const sidebar = (activeTab: string) => (
      <RightSidebar
        activeTab={activeTab}
        ariaLabel="Chat sidebar"
        onTabChange={vi.fn()}
        onWidthChange={vi.fn()}
        open
        tabs={tabs}
        width={RIGHT_SIDEBAR_DEFAULT_WIDTH}
      />
    );
    try {
      const view = render(sidebar("chat"));
      const strip = screen.getByRole("tablist");
      expect(strip.scrollLeft).toBe(0);
      view.rerender(sidebar("browser"));
      expect(strip.scrollLeft).toBe(300);
      view.rerender(sidebar("chat"));
      expect(strip.scrollLeft).toBe(0);
    } finally {
      spy.mockRestore();
    }
  });

  it("keeps the same selected tab visible across label, width, and open changes", () => {
    const readRect = HTMLElement.prototype.getBoundingClientRect;
    const spy = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: HTMLElement) {
        if (this.getAttribute("role") === "tablist") {
          return DOMRect.fromRect({ x: 0, width: 300 });
        }
        if (this.getAttribute("role") === "tab") {
          const viewport = this.closest<HTMLElement>('[role="tablist"]')!;
          return DOMRect.fromRect({ x: 500 - viewport.scrollLeft, width: 100 });
        }
        return readRect.call(this);
      });
    try {
      const view = render(<SelectedTabVisibilityHarness label="Chat" />);
      const strip = screen.getByRole("tablist");
      expect(strip.scrollLeft).toBe(300);
      strip.scrollLeft = 0;
      view.rerender(<SelectedTabVisibilityHarness label="Longer chat tab label" />);
      expect(strip.scrollLeft).toBe(300);
      strip.scrollLeft = 0;
      view.rerender(
        <SelectedTabVisibilityHarness label="Longer chat tab label" width={360} />
      );
      expect(strip.scrollLeft).toBe(300);
      view.rerender(
        <SelectedTabVisibilityHarness
          label="Longer chat tab label"
          open={false}
          width={360}
        />
      );
      strip.scrollLeft = 0;
      view.rerender(
        <SelectedTabVisibilityHarness label="Longer chat tab label" width={360} />
      );
      expect(strip.scrollLeft).toBe(300);
    } finally {
      spy.mockRestore();
    }
  });

  it("focuses the selected successor after keyboard-closing the active tab", async () => {
    const user = userEvent.setup();
    render(<ClosableTabsHarness />);

    const closeActiveTab = screen.getByRole("button", { name: "Close First" });
    closeActiveTab.focus();
    await user.keyboard("{Enter}");

    expect(screen.queryByRole("tab", { name: "First" })).not.toBeInTheDocument();
    const successorTab = screen.getByRole("tab", { name: "Second" });
    expect(successorTab).toHaveAttribute("aria-selected", "true");
    expect(successorTab).toHaveFocus();
  });

  it("falls back to the first available tab when the controlled id is invalid", () => {
    const handleTabChange = vi.fn();
    render(
      <RightSidebar
        activeTab="missing"
        ariaLabel="Chat sidebar"
        onTabChange={handleTabChange}
        onWidthChange={vi.fn()}
        open
        tabs={tabs}
        width={RIGHT_SIDEBAR_DEFAULT_WIDTH}
      />
    );

    expect(screen.getByRole("tab", { name: "Chat" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    expect(screen.getByRole("tab", { name: "Chat" })).toHaveAttribute("tabindex", "0");
    expect(handleTabChange).toHaveBeenCalledWith("chat");
  });

  it("uses the measured transition fallback and completes an exit exactly once", () => {
    vi.useFakeTimers();
    const originalMatchMedia = window.matchMedia;
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn(() => ({ matches: false })),
    });
    const handleExitComplete = vi.fn();
    const sidebar = (open: boolean) => (
      <RightSidebar
        activeTab="chat"
        ariaLabel="Chat sidebar"
        data-testid="right-sidebar"
        onExitComplete={handleExitComplete}
        onTabChange={vi.fn()}
        onWidthChange={vi.fn()}
        open={open}
        style={{
          transitionDelay: "0ms",
          transitionDuration: "150ms",
          transitionProperty: "width",
        }}
        tabs={tabs}
        width={RIGHT_SIDEBAR_DEFAULT_WIDTH}
      />
    );

    try {
      const view = render(sidebar(true));
      view.rerender(sidebar(false));
      act(() => vi.advanceTimersByTime(179));
      expect(handleExitComplete).not.toHaveBeenCalled();
      act(() => vi.advanceTimersByTime(1));
      expect(handleExitComplete).toHaveBeenCalledOnce();

      fireEvent.transitionEnd(screen.getByTestId("right-sidebar"), {
        propertyName: "width",
      });
      expect(handleExitComplete).toHaveBeenCalledOnce();
    } finally {
      if (originalMatchMedia) {
        Object.defineProperty(window, "matchMedia", {
          configurable: true,
          value: originalMatchMedia,
        });
      } else {
        Reflect.deleteProperty(window, "matchMedia");
      }
    }
  });
});

const renderRightSidebarForTooltipLifecycle = (open: boolean) => (
  <RightSidebar
    activeTab="chat"
    ariaLabel="Chat sidebar"
    onTabChange={vi.fn()}
    onWidthChange={vi.fn()}
    open={open}
    tabs={tabs}
    width={RIGHT_SIDEBAR_DEFAULT_WIDTH}
  />
);

const RightSidebarHarness = ({
  resizeWidthMultiplier,
  resizeEdge,
  resizeHandleAppearance,
  headerActions,
  headerActionsClassName,
}: {
  resizeWidthMultiplier?: number;
  resizeEdge?: "left" | "right";
  resizeHandleAppearance?: "divider" | "invisible";
  headerActions?: ReactNode;
  headerActionsClassName?: string;
}) => {
  const [activeTab, setActiveTab] = useState("chat");
  const [width, setWidth] = useState(RIGHT_SIDEBAR_DEFAULT_WIDTH);

  return (
    <RightSidebar
      resizeWidthMultiplier={resizeWidthMultiplier ?? 1}
      resizeEdge={resizeEdge ?? "left"}
      resizeHandleAppearance={resizeHandleAppearance ?? "divider"}
      activeTab={activeTab}
      ariaLabel="Chat sidebar"
      data-testid="right-sidebar"
      headerActions={headerActions}
      headerActionsClassName={headerActionsClassName}
      onTabChange={setActiveTab}
      onWidthChange={setWidth}
      open
      tabs={tabs}
      width={width}
    >
      <section
        aria-label={activeTab === "chat" ? "Chat panel" : "Browser panel"}
        id={`${activeTab}-panel`}
        role="tabpanel"
      >
        {activeTab}
      </section>
    </RightSidebar>
  );
};

const ClosableTabsHarness = () => {
  const [activeTab, setActiveTab] = useState("first");
  const [currentTabs, setCurrentTabs] = useState([
    { closable: true, id: "first", label: "First" },
    { closable: true, id: "second", label: "Second" },
  ]);

  return (
    <RightSidebar
      activeTab={activeTab}
      ariaLabel="Chat sidebar"
      onTabChange={setActiveTab}
      onTabClose={(tabId) => {
        setCurrentTabs((current) => current.filter((tab) => tab.id !== tabId));
        if (tabId === activeTab) setActiveTab("second");
      }}
      onWidthChange={vi.fn()}
      open
      tabs={currentTabs}
      width={RIGHT_SIDEBAR_DEFAULT_WIDTH}
    />
  );
};

const SelectedTabVisibilityHarness = ({
  label,
  open = true,
  width = RIGHT_SIDEBAR_DEFAULT_WIDTH,
}: {
  label: string;
  open?: boolean;
  width?: number;
}) => (
  <RightSidebar
    activeTab="chat"
    ariaLabel="Chat sidebar"
    onTabChange={vi.fn()}
    onWidthChange={vi.fn()}
    open={open}
    tabs={[
      { id: "chat", label },
      { id: "browser", label: "Browser" },
    ]}
    width={width}
  />
);
