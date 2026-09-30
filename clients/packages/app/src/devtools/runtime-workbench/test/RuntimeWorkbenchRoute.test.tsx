import userEvent from "@testing-library/user-event";
import type {
  NativeStateBridge,
  NativeTransportStatus,
  SurfaceList,
} from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, within } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { RuntimeWorkbenchRoute } from "../RuntimeWorkbenchRoute";

vi.mock("tweakpane", () => ({
  Pane: class PaneMock {
    addBinding = vi.fn();
    addBlade = vi.fn();
    addButton = vi.fn(() => ({ on: vi.fn() }));
    addFolder = vi.fn(() => this);
    dispose = vi.fn();
  },
}));

describe("RuntimeWorkbenchRoute", () => {
  it("returns to Side Chat when the native menu navigates an existing workbench", async () => {
    window.history.replaceState(null, "", "#/dev/workbench?tab=side-chat");
    render(<RuntimeWorkbenchRoute />);
    expect(screen.getByRole("tab", { name: /Side Chat/ })).toHaveAttribute(
      "aria-selected",
      "true"
    );

    await userEvent.click(screen.getByRole("tab", { name: /^Runtime/ }));
    expect(window.location.hash).toContain("tab=runtime");
    act(() => {
      window.history.replaceState(null, "", "#/dev/workbench?tab=side-chat");
      window.dispatchEvent(new HashChangeEvent("hashchange"));
    });
    expect(screen.getByRole("tab", { name: /Side Chat/ })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    window.history.replaceState(null, "", "#/dev/workbench");
  });
  it("renders compact tabs, acceptance strip, and ready runtime evidence", async () => {
    const surfaceList = {
      notch: { available: true, running: false },
      panels: [],
      platform: {
        appVersion: "0.0.1",
        os: "macos" as const,
        platform: "electron" as const,
      },
      views: [],
      windows: [
        {
          bounds: { height: 1024, width: 1440, x: 0, y: 0 },
          focused: true,
          id: "win_main",
          lifecycle: "ready" as const,
          owner: { id: "app", kind: "app" as const },
          role: "main-window",
          route: "/",
          state: "normal" as const,
          surfaceId: "win_main",
          visible: true,
        },
        {
          bounds: { height: 760, width: 1180, x: 20, y: 20 },
          focused: false,
          id: "dev_workbench",
          lifecycle: "ready" as const,
          owner: { id: "app", kind: "app" as const },
          role: "dev-workbench",
          route: "/dev/workbench",
          state: "normal" as const,
          surfaceId: "dev_workbench",
          visible: true,
        },
      ],
    } satisfies SurfaceList;

    installNativeBridgeMock({
      native: {
        info: vi.fn(async () => ({
          appVersion: "0.0.1",
          os: "macos" as const,
          platform: "electron" as const,
        })),
      },
      surfaces: {
        list: vi.fn(async () => surfaceList),
        onChanged: vi.fn(() => () => undefined),
        state: createTestStateBridge(() => surfaceList),
      },
    });

    render(<RuntimeWorkbenchRoute />);

    expect(
      await screen.findByRole("heading", { name: "Runtime Workbench" })
    ).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /Runtime/ })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    expect(screen.getByText("What this proves")).toBeInTheDocument();
    expect(await screen.findByText("dev_workbench")).toBeInTheDocument();

    await userEvent.click(screen.getByRole("tab", { name: /Windows & Views/ }));

    await screen.findByText("Comm Matrix");
    expect(
      screen
        .getAllByText("surfaces.state")
        .find((element) => element.hasAttribute("data-control-status"))
    ).toHaveAttribute("data-control-status", "ready");
    expect(screen.getByText("Comm Matrix")).toBeInTheDocument();
  });

  it("keeps Local Data and Transport visible as real partial surfaces", async () => {
    render(<RuntimeWorkbenchRoute />);

    const functionalTabs = screen.getAllByRole("tablist")[0];
    if (!functionalTabs) {
      throw new Error("Runtime Workbench functional tablist was not rendered.");
    }

    expect(
      await within(functionalTabs).findByRole("tab", { name: /Local Data/ })
    ).toHaveTextContent("PARTIAL");
    expect(
      within(functionalTabs).getByRole("tab", { name: /Transport/ })
    ).toHaveTextContent("PARTIAL");

    expect(within(functionalTabs).queryByRole("tab", { name: /PLANNED/ })).toBeNull();
    expect(screen.queryByText("PLANNED")).toBeNull();

    await userEvent.click(
      within(functionalTabs).getByRole("tab", { name: /Local Data/ })
    );
    expect(await screen.findByText("localData.status")).toHaveAttribute(
      "data-control-status",
      "ready"
    );

    await userEvent.click(
      within(functionalTabs).getByRole("tab", { name: /Transport/ })
    );
    expect(await screen.findByText("transport.status")).toHaveAttribute(
      "data-control-status",
      "ready"
    );
    expect(screen.queryByText("MessagePort")).toBeNull();
  });

  it("derives the comm matrix rows from the real registered event channels", async () => {
    const transportStatus = {
      available: true,
      capabilities: {
        payloadClasses: [],
        byTransport: {
          "file-handle": 0,
          "ipc-rpc": 3,
          "message-port": 0,
          "native-stream": 0,
        },
        total: 3,
      },
      events: {
        channels: ["comma:surfaces:changed", "comma:notch:event"],
        total: 2,
      },
      messagePort: {
        active: false as const,
        reason: "Transport diagnostics are unavailable in this test runtime.",
        runtime: "unavailable" as const,
      },
      observability: {
        jsonlEnabled: false,
        location: "unavailable",
        redacted: true as const,
        status: "disabled" as const,
      },
    } satisfies NativeTransportStatus;

    installNativeBridgeMock({
      transport: { status: vi.fn(async () => transportStatus) },
    });

    render(<RuntimeWorkbenchRoute />);

    const functionalTabs = screen.getAllByRole("tablist")[0];
    if (!functionalTabs) {
      throw new Error("Runtime Workbench functional tablist was not rendered.");
    }
    await userEvent.click(
      within(functionalTabs).getByRole("tab", { name: /Transport/ })
    );

    const matrix = await screen.findByRole("region", {
      name: "Communication matrix",
    });
    // Rows come straight from transport.events.channels — both registered
    // channels appear and neither is fabricated as active/planned.
    expect(within(matrix).getByText("comma:notch:event")).toBeInTheDocument();
    expect(within(matrix).getByText("comma:surfaces:changed")).toBeInTheDocument();
    expect(within(matrix).getAllByText("registered")).toHaveLength(2);
    expect(within(matrix).queryByText("planned")).toBeNull();
    expect(within(matrix).queryByText("active")).toBeNull();
  });
});

function createTestStateBridge<Snapshot>(
  getSnapshot: () => Promise<Snapshot> | Snapshot
): NativeStateBridge<Snapshot> {
  const get = vi.fn(async () => getSnapshot());

  return Object.assign(get, {
    get,
    subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => {
      void get().then(listener);
      return () => undefined;
    }),
  });
}
