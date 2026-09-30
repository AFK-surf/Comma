import { type SitePermissionMenuState } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { SitePermissionMenuApp } from "../components/SitePermissionMenuApp";

const opened = (
  generation: number,
  revision: number,
  origin: string
): SitePermissionMenuState => ({
  generation,
  revision,
  menu: {
    origin,
    choices: { microphone: "ask", camera: "ask" },
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
      expect(command).toHaveBeenCalledWith({ action: "present", generation: 2 })
    );
    expect(screen.getByRole("heading")).toHaveTextContent("https://current.example");
    await act(async () => {
      publish({ generation: 2, revision: 5, menu: null });
      publish(opened(2, 4, "https://current.example"));
    });
    expect(screen.queryByRole("heading")).not.toBeInTheDocument();
    expect(command).toHaveBeenCalledTimes(1);
    await act(async () => {
      publish(opened(3, 6, "https://next.example"));
    });
    expect(screen.getByRole("heading")).toHaveTextContent("https://next.example");
    expect(command).toHaveBeenLastCalledWith({ action: "present", generation: 3 });
  });
});
