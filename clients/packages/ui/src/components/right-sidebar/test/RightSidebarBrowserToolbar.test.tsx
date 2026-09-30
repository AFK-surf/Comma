import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { motionDuration } from "../../../tokens/motion";
import { RightSidebarBrowserToolbar } from "../RightSidebarBrowserToolbar";

const reloadGlyph = () =>
  screen
    .getByRole("button", { name: /Reload|Stop loading/ })
    .querySelector(".comma-icon-press-refresh")?.parentElement;

const reloadIcon = () =>
  screen
    .getByRole("button", { name: /Reload|Stop loading/ })
    .querySelector(".comma-icon-press-refresh");

describe("RightSidebarBrowserToolbar", () => {
  it("renders the search placeholder and submits the address on Enter", () => {
    const handleAddressChange = vi.fn();
    const handleAddressSubmit = vi.fn();

    render(
      <RightSidebarBrowserToolbar
        address=""
        canGoBack={false}
        canGoForward={false}
        onAddressChange={handleAddressChange}
        onAddressSubmit={handleAddressSubmit}
        onBack={vi.fn()}
        onForward={vi.fn()}
        onReload={vi.fn()}
      />
    );

    const addressInput = screen.getByRole("textbox", { name: "Address" });
    const toolbar = screen.getByRole("form", { name: "Browser navigation" });
    expect(addressInput).toHaveAttribute("placeholder", "Search or enter URL");
    // The address field carries no focus ring; focus reads from the caret.
    expect(addressInput.parentElement).not.toHaveClass(
      "focus-within:shadow-focus-gray"
    );
    expect(toolbar).toHaveClass("h-10", "py-sm");
    expect(toolbar).not.toHaveClass("h-8", "py-xxs");
    expect(screen.queryByRole("button", { name: "Go" })).not.toBeInTheDocument();
    const navigationButtons = [
      screen.getByRole("button", { name: "Back" }),
      screen.getByRole("button", { name: "Forward" }),
      screen.getByRole("button", { name: "Reload" }),
    ];
    navigationButtons.forEach((button) => {
      expect(button).toHaveClass("size-7", "rounded-sm", "p-xs");
      expect(button).not.toHaveClass("rounded-md", "p-xxs");
    });
    expect(navigationButtons[0]?.parentElement).toHaveClass("gap-xs");
    expect(navigationButtons[0]?.parentElement).not.toHaveClass("gap-md");
    expect(navigationButtons[1]).toBeDisabled();

    fireEvent.change(addressInput, { target: { value: "example.org" } });
    expect(handleAddressChange).toHaveBeenCalledWith("example.org");

    fireEvent.submit(toolbar);
    expect(handleAddressSubmit).toHaveBeenCalledOnce();
  });

  it("disables Forward when canGoForward is false", () => {
    render(
      <RightSidebarBrowserToolbar
        address="https://example.com"
        canGoBack
        canGoForward={false}
        onAddressChange={vi.fn()}
        onAddressSubmit={vi.fn()}
        onBack={vi.fn()}
        onForward={vi.fn()}
        onReload={vi.fn()}
      />
    );

    expect(screen.getByRole("button", { name: "Back" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Forward" })).toBeDisabled();
  });

  it("exposes Stop while loading and keeps it clickable", () => {
    const handleReload = vi.fn();
    const handleStop = vi.fn();

    const { rerender } = render(
      <RightSidebarBrowserToolbar
        address="https://example.com"
        canGoBack={false}
        canGoForward={false}
        loading={false}
        onAddressChange={vi.fn()}
        onAddressSubmit={vi.fn()}
        onBack={vi.fn()}
        onForward={vi.fn()}
        onReload={handleReload}
        onStop={handleStop}
      />
    );

    fireEvent.click(screen.getByRole("button", { name: "Reload" }));
    expect(handleReload).toHaveBeenCalledOnce();
    expect(handleStop).not.toHaveBeenCalled();

    rerender(
      <RightSidebarBrowserToolbar
        address="https://example.com"
        canGoBack={false}
        canGoForward={false}
        loading
        onAddressChange={vi.fn()}
        onAddressSubmit={vi.fn()}
        onBack={vi.fn()}
        onForward={vi.fn()}
        onReload={handleReload}
        onStop={handleStop}
      />
    );

    expect(
      screen.getByRole("progressbar", { name: "Loading page" })
    ).toBeInTheDocument();
    const stopButton = screen.getByRole("button", { name: "Stop loading" });
    expect(stopButton).toBeEnabled();
    fireEvent.click(stopButton);
    expect(handleStop).toHaveBeenCalledOnce();
  });

  it("lets the reload glyph finish its turn before the stop X takes over", () => {
    vi.useFakeTimers();
    const props = {
      address: "https://example.com",
      canGoBack: false,
      canGoForward: false,
      onAddressChange: vi.fn(),
      onAddressSubmit: vi.fn(),
      onBack: vi.fn(),
      onForward: vi.fn(),
      onReload: vi.fn(),
      onStop: vi.fn(),
    };
    const { rerender } = render(<RightSidebarBrowserToolbar {...props} />);

    const button = screen.getByRole("button", { name: "Reload" });
    fireEvent.pointerDown(button, { button: 0, isPrimary: true });
    // The press outlives a pointerup this fast, so the sweep still lands.
    expect(button).toHaveAttribute("data-press-held");
    fireEvent.pointerUp(button, { button: 0, isPrimary: true });
    fireEvent.click(button);
    expect(props.onReload).toHaveBeenCalledOnce();

    rerender(<RightSidebarBrowserToolbar {...props} loading />);
    // Loading has begun — progress shows at once, but the glyph keeps turning.
    expect(
      screen.getByRole("progressbar", { name: "Loading page" })
    ).toBeInTheDocument();
    expect(reloadGlyph()).toHaveAttribute("data-visible", "true");

    // A wall-clock duration is not proof that the compositor has landed. The
    // sweep stays held until its own rotate transition reports completion.
    act(() => {
      vi.advanceTimersToNextFrame();
      vi.advanceTimersByTime(motionDuration.pressTravel);
    });
    expect(button).toHaveAttribute("data-press-held");

    fireEvent.transitionEnd(reloadIcon()!, {
      propertyName: "rotate",
    });
    expect(button).not.toHaveAttribute("data-press-held");
    // Coming back now, and the X is still waiting on it.
    expect(reloadGlyph()).toHaveAttribute("data-visible", "true");

    act(() => {
      vi.advanceTimersToNextFrame();
      vi.advanceTimersByTime(motionDuration.pressRecoil);
    });
    expect(reloadGlyph()).toHaveAttribute("data-visible", "true");

    fireEvent.transitionEnd(reloadIcon()!, {
      propertyName: "rotate",
    });
    expect(reloadGlyph()).toHaveAttribute("data-visible", "false");

    vi.useRealTimers();
  });

  it("finishes the reload handoff when transitionend is lost", () => {
    vi.useFakeTimers();
    const props = {
      address: "https://example.com",
      canGoBack: false,
      canGoForward: false,
      onAddressChange: vi.fn(),
      onAddressSubmit: vi.fn(),
      onBack: vi.fn(),
      onForward: vi.fn(),
      onReload: vi.fn(),
    };
    const { rerender } = render(<RightSidebarBrowserToolbar {...props} />);

    const button = screen.getByRole("button", { name: "Reload" });
    fireEvent.pointerDown(button, { button: 0, isPrimary: true });
    fireEvent.pointerUp(button, { button: 0, isPrimary: true });
    fireEvent.click(button);
    rerender(<RightSidebarBrowserToolbar {...props} loading />);

    expect(reloadGlyph()).toHaveAttribute("data-visible", "true");
    act(() => vi.runAllTimers());
    expect(reloadGlyph()).toHaveAttribute("data-visible", "false");

    vi.useRealTimers();
  });

  it("keeps a long pointer press held until pointerup", () => {
    vi.useFakeTimers();
    render(
      <RightSidebarBrowserToolbar
        address="https://example.com"
        canGoBack={false}
        canGoForward={false}
        onAddressChange={vi.fn()}
        onAddressSubmit={vi.fn()}
        onBack={vi.fn()}
        onForward={vi.fn()}
        onReload={vi.fn()}
      />
    );

    const button = screen.getByRole("button", { name: "Reload" });
    fireEvent.pointerDown(button, { button: 0, isPrimary: true });
    act(() => {
      vi.advanceTimersToNextFrame();
      vi.advanceTimersByTime(motionDuration.pressTravel);
    });
    fireEvent.transitionEnd(reloadIcon()!, {
      propertyName: "rotate",
    });

    expect(button).toHaveAttribute("data-press-held");
    fireEvent.pointerUp(button, { button: 0, isPrimary: true });
    expect(button).not.toHaveAttribute("data-press-held");

    vi.useRealTimers();
  });

  it.each(["finished", "cancelled"])(
    "ignores a %s animation from an older watchdog after a new press",
    async (outcome) => {
      vi.useFakeTimers();
      try {
        render(
          <RightSidebarBrowserToolbar
            address="https://example.com"
            canGoBack={false}
            canGoForward={false}
            onAddressChange={vi.fn()}
            onAddressSubmit={vi.fn()}
            onBack={vi.fn()}
            onForward={vi.fn()}
            onReload={vi.fn()}
          />
        );
        let finish!: () => void;
        let cancel!: () => void;
        const finished = new Promise<void>((resolve, reject) => {
          finish = resolve;
          cancel = () => reject(new DOMException("Cancelled", "AbortError"));
        });
        Object.defineProperty(reloadIcon(), "getAnimations", {
          value: () => [{ transitionProperty: "rotate", finished }],
        });
        const button = screen.getByRole("button", { name: "Reload" });
        fireEvent.pointerDown(button, { button: 0, isPrimary: true });
        fireEvent.pointerUp(button, { button: 0, isPrimary: true });
        fireEvent.click(button);
        act(() => {
          vi.advanceTimersToNextFrame();
          vi.advanceTimersByTime(350);
        });
        expect(button).toHaveAttribute("data-press-held");

        fireEvent.pointerDown(button, { button: 0, isPrimary: true });
        await act(async () => {
          if (outcome === "finished") finish();
          else cancel();
        });
        fireEvent.pointerUp(button, { button: 0, isPrimary: true });
        // The old completion cannot turn the new travel into held/recoil.
        expect(button).toHaveAttribute("data-press-held");
        fireEvent.transitionEnd(reloadIcon()!, { propertyName: "rotate" });
        expect(button).not.toHaveAttribute("data-press-held");
      } finally {
        vi.useRealTimers();
      }
    }
  );

  it("swaps to the stop X at once when no pointer press turned the glyph", () => {
    const props = {
      address: "https://example.com",
      canGoBack: false,
      canGoForward: false,
      onAddressChange: vi.fn(),
      onAddressSubmit: vi.fn(),
      onBack: vi.fn(),
      onForward: vi.fn(),
      onReload: vi.fn(),
      onStop: vi.fn(),
    };
    const { rerender } = render(<RightSidebarBrowserToolbar {...props} />);

    // Keyboard activation: nothing turned, so there is nothing to wait for.
    fireEvent.click(screen.getByRole("button", { name: "Reload" }));
    rerender(<RightSidebarBrowserToolbar {...props} loading />);
    expect(reloadGlyph()).toHaveAttribute("data-visible", "false");
  });

  it("uses the theme color while element selection is active", () => {
    render(
      <RightSidebarBrowserToolbar
        address="https://example.com"
        canGoBack={false}
        canGoForward={false}
        inspecting
        onAddressChange={vi.fn()}
        onAddressSubmit={vi.fn()}
        onBack={vi.fn()}
        onForward={vi.fn()}
        onInspect={vi.fn()}
        onReload={vi.fn()}
      />
    );

    const inspectButton = screen.getByRole("button", {
      name: "Cancel element selection",
    });
    expect(inspectButton).toHaveAttribute("aria-pressed", "true");
    expect(inspectButton).toHaveClass("text-fg-brand-primary");
  });
});
