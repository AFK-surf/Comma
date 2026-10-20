import type { AppUpdateValue } from "@comma/core-client";
import type { CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import type { ApplicationMenuCommand } from "@comma/native-bridge";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { Toaster, toast } from "@comma/ui/components/toast";
import { StrictMode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AutomaticUpdates } from "../components/AutomaticUpdates";
import { CommaSessionHostProvider } from "../session/react";
import {
  createTestSessionHostController,
  publishTestSessionSnapshot,
  signedInSessionSnapshot,
  signedOutSessionSnapshot,
} from "./sessionHostHarness";

const nothing: AppUpdateValue = { downloading: false, ready: null };
const ready: AppUpdateValue = {
  downloading: false,
  ready: { productName: "Comma Staging", version: "0.0.2-staging.abc123" },
};

/** The core as this window sees it: the `appUpdate` topic, and what each call answers. */
function scriptedUpdates(
  value: AppUpdateValue,
  calls: (name: string) => unknown = () => null
) {
  return createScriptedCore({
    values: (topic) => (topic.topic === "appUpdate" ? value : undefined),
    calls,
  });
}

function installDesktop(windowId = "win_main") {
  let invoke: ((id: ApplicationMenuCommand) => void) | undefined;
  installNativeBridgeMock({
    platform: "electron",
    self: { role: "main-window", windowId },
    applicationMenu: {
      update: vi.fn(async () => {}),
      onCommand: (listener) => {
        invoke = listener;
        return () => {};
      },
    },
  });
  return { checkForUpdates: () => act(async () => invoke?.("check-updates")) };
}

function renderAutomaticUpdates(
  core: ReturnType<typeof createScriptedCore>,
  {
    locale = "en",
    controller = createTestSessionHostController({ initial: signedInSessionSnapshot }),
  }: {
    locale?: CommaLocale;
    controller?: ReturnType<typeof createTestSessionHostController>;
  } = {}
) {
  render(
    core.wrap(
      <StrictMode>
        <CommaSessionHostProvider controller={controller}>
          <CommaI18nProvider locale={locale}>
            <AutomaticUpdates />
            <Toaster />
          </CommaI18nProvider>
        </CommaSessionHostProvider>
      </StrictMode>
    )
  );
  return controller;
}

describe("AutomaticUpdates", () => {
  afterEach(() => {
    toast.dismissAll();
    vi.restoreAllMocks();
  });

  it.each([
    ["current", "You’re up to date"],
    ["unconfigured", "Updates are not configured for this build"],
    ["failed", "Could not check for updates"],
  ] as const)(
    "shows Check for Updates' progress and the %s outcome",
    async (outcome, shown) => {
      vi.spyOn(console, "error").mockImplementation(() => undefined);
      let answer!: () => void;
      const core = scriptedUpdates(nothing, (name) =>
        name === "appUpdate.check"
          ? new Promise((resolve, reject) => {
              answer = () =>
                outcome === "failed"
                  ? reject(Object.assign(new Error("offline"), { code: "host" }))
                  : resolve({ outcome });
            })
          : null
      );
      const desktop = installDesktop();
      renderAutomaticUpdates(core);
      await desktop.checkForUpdates();
      expect(await screen.findByText("Checking for updates…")).toBeInTheDocument();
      expect(core.sentTo("appUpdate.check")).toHaveLength(1);
      await act(async () => answer());
      expect(await screen.findByText(shown)).toBeInTheDocument();
      await waitFor(() =>
        expect(screen.queryByText("Checking for updates…")).not.toBeInTheDocument()
      );
    }
  );

  it("quietly follows an automatic download and applies only when Restart is pressed", async () => {
    let finishApply!: () => void;
    const core = scriptedUpdates(nothing, (name) =>
      name === "appUpdate.apply"
        ? new Promise((resolve) => (finishApply = () => resolve({ applied: true })))
        : null
    );
    installDesktop();
    renderAutomaticUpdates(core);
    await flush();
    expect(screen.queryByText("You’re up to date")).not.toBeInTheDocument();

    await act(async () => core.emit("appUpdate", { downloading: true, ready: null }));
    expect(screen.queryByText("Downloading update…")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Restart now" })
    ).not.toBeInTheDocument();
    await act(async () => core.emit("appUpdate", ready));
    await flush();
    expect(screen.getByText("Update ready")).toBeInTheDocument();
    expect(core.sentTo("appUpdate.check")).toEqual([]);
    expect(core.sentTo("appUpdate.apply")).toEqual([]);

    const restart = screen.getByRole("button", { name: "Restart now" });
    fireEvent.click(restart);
    fireEvent.click(restart);
    await flush();
    expect(core.sentTo("appUpdate.apply")).toEqual([{}]);
    await act(async () => finishApply());
  });

  it("reports when the downloaded update could not be installed", async () => {
    const core = scriptedUpdates(ready, (name) =>
      name === "appUpdate.apply" ? { applied: false } : null
    );
    installDesktop();
    renderAutomaticUpdates(core);

    expect(await screen.findByText("Update ready")).toBeInTheDocument();
    expect(
      screen.getByText(
        "Comma Staging 0.0.2-staging.abc123 has been downloaded. Restart to finish installing."
      )
    ).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Restart now" }));
    await waitFor(() => expect(core.sentTo("appUpdate.apply")).toHaveLength(1));
    // The platform could not start it: the window says so.
    expect(
      await screen.findByText("Update could not be installed")
    ).toBeInTheDocument();
  });

  it("shows update controls in Simplified Chinese", async () => {
    installDesktop();
    renderAutomaticUpdates(scriptedUpdates(ready), { locale: "zh-CN" });

    expect(await screen.findByText("更新已就绪")).toBeInTheDocument();
    expect(
      screen.getByText(
        "Comma Staging 0.0.2-staging.abc123 已下载。重启后即可完成安装。"
      )
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "立即重启" })).toBeInTheDocument();
  });

  it("holds the restart offer until sign-in, and takes it down when the session ends", async () => {
    installDesktop();
    const dismiss = vi.spyOn(toast, "dismiss");
    const controller = renderAutomaticUpdates(scriptedUpdates(ready), {
      controller: createTestSessionHostController({
        initial: signedOutSessionSnapshot,
      }),
    });
    await act(async () => {});
    expect(screen.queryByText("Update ready")).not.toBeInTheDocument();
    // Never retire an offer this window has not raised: sonner delivers a
    // dismissal a frame late, and it would land on the toast shown in between.
    expect(dismiss).not.toHaveBeenCalled();

    act(() => publishTestSessionSnapshot(controller, signedInSessionSnapshot));
    expect(await screen.findByText("Update ready")).toBeInTheDocument();

    act(() => publishTestSessionSnapshot(controller, signedOutSessionSnapshot));
    await waitFor(() =>
      expect(screen.queryByText("Update ready")).not.toBeInTheDocument()
    );
  });

  it("says when Check for Updates waits on a download, and offers it again each time", async () => {
    let answer!: () => void;
    const core = scriptedUpdates({ downloading: true, ready: null }, (name) =>
      name === "appUpdate.check"
        ? new Promise((resolve) => (answer = () => resolve({ outcome: "ready" })))
        : null
    );
    const desktop = installDesktop();
    renderAutomaticUpdates(core);
    await desktop.checkForUpdates();
    expect(await screen.findByText("Downloading update…")).toBeInTheDocument();

    core.emit("appUpdate", ready);
    await act(async () => answer());
    expect(await screen.findByText("Update ready")).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.queryByText("Downloading update…")).not.toBeInTheDocument()
    );
    fireEvent.click(screen.getByRole("button", { name: "Dismiss notification" }));
    await waitFor(() =>
      expect(screen.queryByText("Update ready")).not.toBeInTheDocument()
    );

    // The core answers at once now; the window shows the offer again.
    await desktop.checkForUpdates();
    await act(async () => answer());
    expect(await screen.findByText("Update ready")).toBeInTheDocument();
  });

  it("lets the core catch up when the main window comes back", async () => {
    const core = scriptedUpdates(nothing);
    installDesktop();
    renderAutomaticUpdates(core);
    for (const event of ["focus", "online"])
      await act(async () => {
        window.dispatchEvent(new Event(event));
      });
    expect(core.sentTo("appUpdate.wake")).toHaveLength(2);
  });

  it("offers only what its own check found in a secondary window, and nothing on the web", async () => {
    const core = scriptedUpdates(ready, (name) =>
      name === "appUpdate.check" ? { outcome: "ready" } : null
    );
    const desktop = installDesktop("win_dynamic_1");
    renderAutomaticUpdates(core);
    await flush();
    window.dispatchEvent(new Event("focus"));
    expect(screen.queryByText("Update ready")).not.toBeInTheDocument();
    expect(core.sentTo("appUpdate.wake")).toHaveLength(0);

    await desktop.checkForUpdates();
    expect(await screen.findByText("Update ready")).toBeInTheDocument();
  });

  it("asks the core nothing on the web", async () => {
    const subscribed: unknown[] = [];
    const core = createScriptedCore({ onSubscribe: (topic) => subscribed.push(topic) });
    installNativeBridgeMock({ platform: "web" });
    renderAutomaticUpdates(core);
    await act(async () => {});
    expect(subscribed).toEqual([]);
    expect(core.sent).toEqual([]);
  });
});
