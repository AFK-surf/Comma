import { type SitePermissionMenuState } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { SitePermissionMenuApp } from "../components/SitePermissionMenuApp";

const opened = (
  generation: number,
  revision: number,
  origin: string | null
): SitePermissionMenuState => ({
  generation,
  revision,
  menu: {
    site: origin ? { origin, choices: { microphone: "ask", camera: "ask" } } : null,
    systemSettings: false,
  },
});

describe("preloaded website permission menu", () => {
  it("commits only the current website before presenting and ignores stale snapshots after dismissal", async () => {
    let publish!: (state: SitePermissionMenuState) => void;
    let finishRead!: (state: SitePermissionMenuState) => void;
    const get = vi.fn(
      () =>
        new Promise<SitePermissionMenuState>((resolve) => {
          finishRead = resolve;
        })
    );
    const command = vi.fn(async () => {});
    installNativeBridgeMock({
      platform: "electron",
      sitePermissionMenu: {
        state: Object.assign(get, {
          get,
          subscribe: (listener: typeof publish) => {
            publish = listener;
            return () => {};
          },
        }),
        act: command,
      },
    });
    render(<SitePermissionMenuApp />);
    await act(async () => {
      publish(opened(2, 4, "https://current.example"));
    });
    expect(command).not.toHaveBeenCalled();
    await act(async () => {
      finishRead(opened(1, 1, "https://old.example"));
    });
    await waitFor(() =>
      expect(command).toHaveBeenCalledWith({
        action: "present",
        generation: 2,
        height: 0,
      })
    );
    expect(screen.getByRole("heading", { name: "This site" })).toHaveAttribute(
      "title",
      "https://current.example"
    );
    expect(screen.getByText("https://current.example")).toBeVisible();
    await act(async () => {
      publish({ generation: 2, revision: 5, menu: null });
      publish(opened(2, 4, "https://current.example"));
    });
    expect(screen.queryByRole("heading")).not.toBeInTheDocument();
    expect(command).toHaveBeenCalledTimes(1);
    await act(async () => {
      publish(opened(3, 6, "https://next.example"));
    });
    expect(screen.getByRole("heading", { name: "This site" })).toHaveAttribute(
      "title",
      "https://next.example"
    );
    expect(command).toHaveBeenLastCalledWith({
      action: "present",
      generation: 3,
      height: 0,
    });
  });

  it("sizes the native window to the whole menu, including what its scroll area hides", async () => {
    const command = vi.fn(async () => {});
    const state = opened(1, 1, "https://current.example");
    const get = vi.fn(async () => state);
    installNativeBridgeMock({
      platform: "electron",
      sitePermissionMenu: {
        state: Object.assign(get, { get, subscribe: () => () => {} }),
        act: command,
      },
    });
    // jsdom has no layout: the window clips the menu's 300px list to 150px.
    let listHeight = 300;
    vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockImplementation(function (
      this: HTMLElement
    ) {
      if (this.tagName === "SECTION") return 200;
      if (this.dataset.slot === "scroll-area") return 150;
      return this.dataset.slot === "scroll-area-content" ? listHeight : 0;
    });
    const resized: ResizeObserverCallback[] = [];
    vi.stubGlobal(
      "ResizeObserver",
      class {
        constructor(callback: ResizeObserverCallback) {
          resized.push(callback);
        }
        observe() {}
        unobserve() {}
        disconnect() {}
      }
    );
    try {
      render(<SitePermissionMenuApp />);
      await waitFor(() =>
        expect(command).toHaveBeenCalledWith({
          action: "present",
          generation: 1,
          height: 350,
        })
      );
      // Every observer fires: the scroll area keeps its own as well.
      const resize = () =>
        act(() => resized.forEach((callback) => callback([], {} as ResizeObserver)));
      resize();
      expect(command).toHaveBeenCalledOnce();
      listHeight = 340;
      resize();
      expect(command).toHaveBeenLastCalledWith({
        action: "present",
        generation: 1,
        height: 390,
      });
    } finally {
      vi.unstubAllGlobals();
      vi.restoreAllMocks();
    }
  });

  it("offers only the page actions on a page without site permissions and picks one", async () => {
    const command = vi.fn(async () => {});
    const state = opened(1, 1, null);
    const get = vi.fn(async () => state);
    installNativeBridgeMock({
      platform: "electron",
      sitePermissionMenu: {
        state: Object.assign(get, { get, subscribe: () => () => {} }),
        act: command,
      },
    });
    render(<SitePermissionMenuApp />);
    const importItem = await screen.findByRole("menuitem", { name: "Import sign-ins" });
    expect(screen.queryByRole("heading")).not.toBeInTheDocument();
    expect(screen.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
      "Import sign-ins",
      "Open in default browser",
    ]);
    await act(async () => {
      importItem.click();
    });
    expect(command).toHaveBeenLastCalledWith({
      action: "pick",
      item: "import-sign-ins",
      generation: 1,
    });
  });
});
