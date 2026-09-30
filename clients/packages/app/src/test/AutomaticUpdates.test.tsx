import type { CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import type {
  ApplicationMenuCommand,
  UpdateAsset,
  UpdateInfo,
} from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { Toaster, toast } from "@comma/ui";
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

const targetRelease: UpdateAsset = {
  PackageId: "comma-staging",
  Version: "0.0.2-staging.abc123",
  Type: "Full",
  FileName: "comma-staging-0.0.2-full.nupkg",
  SHA1: "sha1",
  SHA256: "sha256",
  Size: 1024,
  NotesMarkdown: "",
  NotesHtml: "",
};

const availableUpdate: UpdateInfo = {
  TargetFullRelease: targetRelease,
  DeltasToTarget: [],
  IsDowngrade: false,
};

function renderAutomaticUpdates(
  locale: CommaLocale = "en",
  controller = createTestSessionHostController({ initial: signedInSessionSnapshot })
) {
  return {
    controller,
    ...render(
      <StrictMode>
        <CommaSessionHostProvider controller={controller}>
          <CommaI18nProvider locale={locale}>
            <AutomaticUpdates />
            <Toaster />
          </CommaI18nProvider>
        </CommaSessionHostProvider>
      </StrictMode>
    ),
  };
}

describe("AutomaticUpdates", () => {
  afterEach(() => {
    toast.dismissAll();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it.each(["current", "failed"] as const)(
    "shows immediate manual-check feedback and the %s outcome",
    async (outcome) => {
      let invoke: ((id: ApplicationMenuCommand) => void) | undefined;
      let resolveCheck!: (value: null) => void;
      let rejectCheck!: (error: Error) => void;
      const pending = new Promise<null>((resolve, reject) => {
        resolveCheck = resolve;
        rejectCheck = reject;
      });
      const check = vi.fn().mockResolvedValueOnce(null).mockReturnValueOnce(pending);
      installNativeBridgeMock({
        platform: "electron",
        self: { role: "main-window", windowId: "win_main" },
        applicationMenu: {
          update: vi.fn(async () => {}),
          onCommand: (listener) => {
            invoke = listener;
            return () => {};
          },
        },
        updates: {
          status: vi.fn(async () => ({ configured: true, currentVersion: "0.0.1" })),
          check,
        },
      });
      renderAutomaticUpdates();
      await waitFor(() => expect(check).toHaveBeenCalledTimes(1));
      await act(async () => invoke?.("check-updates"));
      expect(await screen.findByText("Checking for updates…")).toBeInTheDocument();
      await act(async () => {
        if (outcome === "current") resolveCheck(null);
        else rejectCheck(new Error("network offline"));
      });
      expect(
        await screen.findByText(
          outcome === "current" ? "You’re up to date" : "Could not check for updates"
        )
      ).toBeInTheDocument();
      await waitFor(() =>
        expect(screen.queryByText("Checking for updates…")).not.toBeInTheDocument()
      );
    }
  );

  it("checks once, downloads an update, and offers to restart", async () => {
    const status = vi.fn(async () => ({
      configured: true,
      currentVersion: "0.0.1-staging.abc123",
      productName: "Comma Staging",
    }));
    const check = vi.fn(async () => availableUpdate);
    const download = vi.fn(async () => true);
    const apply = vi.fn(async () => true);

    installNativeBridgeMock({
      platform: "electron",
      self: { role: "main-window", windowId: "win_main" },
      updates: { status, check, download, apply },
    });

    renderAutomaticUpdates();

    expect(await screen.findByText("Update ready")).toBeInTheDocument();
    expect(
      screen.getByText(
        "Comma Staging 0.0.2-staging.abc123 has been downloaded. Restart to finish installing."
      )
    ).toBeInTheDocument();
    expect(status).toHaveBeenCalledTimes(1);
    expect(check).toHaveBeenCalledTimes(1);
    expect(download).toHaveBeenCalledTimes(1);
    expect(download).toHaveBeenCalledWith(availableUpdate);

    fireEvent.click(screen.getByRole("button", { name: "Restart now" }));

    await waitFor(() => expect(apply).toHaveBeenCalledWith(availableUpdate));
  });

  it("offers to apply an update that is already pending restart", async () => {
    const check = vi.fn(async () => null);
    const download = vi.fn(async () => true);
    const apply = vi.fn(async () => true);

    installNativeBridgeMock({
      platform: "electron",
      self: { role: "main-window", windowId: "win_main" },
      updates: {
        status: vi.fn(async () => ({
          configured: true,
          currentVersion: "0.0.1",
          pendingRestart: targetRelease,
          productName: "Comma",
        })),
        check,
        download,
        apply,
      },
    });

    renderAutomaticUpdates();

    expect(await screen.findByText("Update ready")).toBeInTheDocument();
    expect(check).not.toHaveBeenCalled();
    expect(download).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Restart now" }));

    await waitFor(() => expect(apply).toHaveBeenCalledWith(targetRelease));
  });

  it("shows update controls in Simplified Chinese", async () => {
    installNativeBridgeMock({
      platform: "electron",
      self: { role: "main-window", windowId: "win_main" },
      updates: {
        status: vi.fn(async () => ({
          configured: true,
          currentVersion: "0.0.1",
          pendingRestart: targetRelease,
          productName: "Comma",
        })),
        check: vi.fn(async () => null),
        download: vi.fn(async () => true),
        apply: vi.fn(async () => true),
      },
    });

    renderAutomaticUpdates("zh-CN");

    expect(await screen.findByText("更新已就绪")).toBeInTheDocument();
    expect(
      screen.getByText("Comma 0.0.2-staging.abc123 已下载。重启后即可完成安装。")
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "立即重启" })).toBeInTheDocument();
    expect(screen.queryByText("Update ready")).not.toBeInTheDocument();
  });

  it("downloads from the login screen but holds the restart offer until sign-in", async () => {
    const status = vi.fn(async () => ({
      configured: true,
      currentVersion: "0.0.1-staging.abc123",
      productName: "Comma Staging",
    }));
    const check = vi.fn(async () => availableUpdate);
    const download = vi.fn(async () => true);

    installNativeBridgeMock({
      platform: "electron",
      self: { role: "main-window", windowId: "win_main" },
      updates: { status, check, download, apply: vi.fn(async () => true) },
    });

    const dismiss = vi.spyOn(toast, "dismiss");
    const controller = createTestSessionHostController({
      initial: signedOutSessionSnapshot,
    });
    renderAutomaticUpdates("en", controller);

    // The release lands on disk while the user is still typing their password.
    await waitFor(() => expect(download).toHaveBeenCalledWith(availableUpdate));
    expect(status).toHaveBeenCalledTimes(1);
    expect(check).toHaveBeenCalledTimes(1);
    expect(screen.queryByText("Update ready")).not.toBeInTheDocument();
    // Never retire an offer this window has not raised: sonner delivers a
    // dismissal a frame late, and it would land on the toast shown in between.
    expect(dismiss).not.toHaveBeenCalled();

    act(() => publishTestSessionSnapshot(controller, signedInSessionSnapshot));

    expect(await screen.findByText("Update ready")).toBeInTheDocument();
    expect(
      screen.getByText(
        "Comma Staging 0.0.2-staging.abc123 has been downloaded. Restart to finish installing."
      )
    ).toBeInTheDocument();
    // Signing in reveals the offer; it does not re-run the check.
    expect(status).toHaveBeenCalledTimes(1);
    expect(check).toHaveBeenCalledTimes(1);
    expect(download).toHaveBeenCalledTimes(1);
  });

  it("takes the restart offer down when the session ends", async () => {
    installNativeBridgeMock({
      platform: "electron",
      self: { role: "main-window", windowId: "win_main" },
      updates: {
        status: vi.fn(async () => ({
          configured: true,
          currentVersion: "0.0.1",
          pendingRestart: targetRelease,
          productName: "Comma",
        })),
        check: vi.fn(async () => null),
        download: vi.fn(async () => true),
        apply: vi.fn(async () => true),
      },
    });

    const controller = createTestSessionHostController({
      initial: signedInSessionSnapshot,
    });
    renderAutomaticUpdates("en", controller);

    expect(await screen.findByText("Update ready")).toBeInTheDocument();

    act(() => publishTestSessionSnapshot(controller, signedOutSessionSnapshot));

    await waitFor(() =>
      expect(screen.queryByText("Update ready")).not.toBeInTheDocument()
    );
  });

  it("does not check from web or secondary renderer windows", async () => {
    const webStatus = vi.fn(async () => ({
      configured: true,
      currentVersion: "0.0.1",
    }));
    installNativeBridgeMock({
      platform: "web",
      updates: { status: webStatus },
    });

    const webRender = renderAutomaticUpdates();
    await Promise.resolve();
    expect(webStatus).not.toHaveBeenCalled();
    webRender.unmount();

    const secondaryStatus = vi.fn(async () => ({
      configured: true,
      currentVersion: "0.0.1",
    }));
    installNativeBridgeMock({
      platform: "electron",
      self: { role: "main-window", windowId: "win_dynamic_1" },
      updates: { status: secondaryStatus },
    });

    renderAutomaticUpdates();
    await Promise.resolve();
    expect(secondaryStatus).not.toHaveBeenCalled();
  });

  it("retries transient failures twice without polling indefinitely", async () => {
    vi.useFakeTimers();
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const status = vi.fn(async () => {
      throw new Error("temporary network failure");
    });

    installNativeBridgeMock({
      platform: "electron",
      self: { role: "main-window", windowId: "win_main" },
      updates: { status },
    });

    renderAutomaticUpdates();
    await vi.advanceTimersByTimeAsync(0);
    expect(status).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(5_000);
    expect(status).toHaveBeenCalledTimes(2);

    await vi.advanceTimersByTimeAsync(30_000);
    expect(status).toHaveBeenCalledTimes(3);

    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(status).toHaveBeenCalledTimes(3);
  });
});
