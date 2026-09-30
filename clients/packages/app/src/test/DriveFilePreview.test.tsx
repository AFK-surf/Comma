import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { StrictMode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DriveStore, type DriveFile } from "../components/drive/driveStore";
import type { DriveBackend } from "../components/drive/driveSynchronicityBackend";
import { DrivePreviewPanel } from "../components/drive/DrivePreviewPanel";

const state = vi.hoisted(() => ({
  store: undefined as DriveStore | undefined,
  backend: undefined as DriveBackend | undefined,
}));
vi.mock("../components/drive/driveStore", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../components/drive/driveStore")>()),
  getDriveStore: () => state.store!,
}));
vi.mock("../components/drive/driveBackend", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../components/drive/driveBackend")>()),
  getDriveBackend: () => state.backend,
}));
const file: DriveFile = {
  id: "drive-file",
  contentsHash: "version-a",
  deviceId: "mac",
  modifiedAt: 1,
  name: "report.md",
  sizeBytes: 20,
  spaceId: "space",
};
const seed = (files: DriveFile[]) => ({
  originDeviceId: "mac",
  devices: [{ current: true, id: "mac", label: "This Mac" }],
  spaces: [{ id: "space", name: "Space", writable: true }],
  files,
});
const applicationId = `fap1_${"a".repeat(43)}`;
const saved = {
  status: "saved" as const,
  fileName: file.name,
  downloadRef: `dnl1_${"b".repeat(43)}`,
};
const onOpenBrowser = vi.fn();
const renderPreview = () =>
  render(
    <StrictMode>
      <DrivePreviewPanel
        fileId={file.id}
        panelId="drive-preview"
        onOpenBrowser={onOpenBrowser}
      />
    </StrictMode>
  );
async function chooseApp() {
  fireEvent.click(screen.getByRole("button", { name: "Choose application" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: /Preview/ }));
}

beforeEach(() => {
  state.backend = undefined;
  state.store = new DriveStore(
    seed([{ ...file, blob: new Blob(["# Drive report"], { type: "text/markdown" }) }])
  );
});

describe("Drive uses the shared file reader", () => {
  it("opens the held file from the common toolbar under StrictMode without retrieving it again", async () => {
    const saveDownload = vi.fn(async () => saved);
    const openDownload = vi.fn(async () => ({ status: "opened" as const }));
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      files: {
        saveDownload,
        openDownload,
        listOpenApplications: async () => ({
          status: "available",
          applications: [{ id: applicationId, name: "Preview", isDefault: true }],
        }),
      },
    });
    renderPreview();
    expect(await screen.findByRole("heading", { name: "Drive report" })).toBeVisible();
    expect(
      screen.getByTestId("file-preview-toolbar").querySelector(".chat-panel-file")
    ).toBeNull();
    expect(screen.getByRole("heading", { level: 2 })).toHaveTextContent(file.name);
    await chooseApp();
    await waitFor(() =>
      expect(openDownload).toHaveBeenCalledWith({
        downloadRef: saved.downloadRef,
        applicationId,
      })
    );
    expect(saveDownload).toHaveBeenCalledOnce();
  });
  it("keeps Drive streamed downloads and reports failed preview reads in the common error UI", async () => {
    const saveDownload = vi.fn(async () => saved);
    const rendererSave = vi.fn();
    state.store = new DriveStore(seed([{ ...file, sizeBytes: 20_000_000 }]));
    state.backend = {
      readFile: vi.fn(async () => {
        throw new Error("Unavailable preview");
      }),
      saveDownload,
    } as unknown as DriveBackend;
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      files: { saveDownload: rendererSave },
    });
    renderPreview();
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Could not preview this file."
    );
    expect(screen.queryByRole("button", { name: "Open" })).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Choose application" })
    ).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Download report.md" }));
    await waitFor(() => expect(saveDownload).toHaveBeenCalledOnce());
    expect(rendererSave).not.toHaveBeenCalled();
    expect(state.store.getSnapshot().transfers[0]?.status).toBe("success");
  });

  it("retires old bytes and cancels a pending native open when a Drive version replaces the Blob", async () => {
    let resolveSave!: (value: typeof saved) => void;
    const pendingSave = new Promise<typeof saved>((resolve) => {
      resolveSave = resolve;
    });
    const saveDownload = vi
      .fn()
      .mockReturnValueOnce(pendingSave)
      .mockResolvedValue(saved);
    const openDownload = vi.fn(async () => ({ status: "opened" as const }));
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      files: {
        saveDownload,
        openDownload,
        listOpenApplications: async () => ({
          status: "available",
          applications: [{ id: applicationId, name: "Preview", isDefault: true }],
        }),
      },
    });
    renderPreview();
    expect(await screen.findByRole("heading", { name: "Drive report" })).toBeVisible();
    await chooseApp();
    await waitFor(() => expect(saveDownload).toHaveBeenCalledOnce());
    act(() =>
      state.store!.load(
        seed([
          {
            ...file,
            contentsHash: "version-b",
            blob: new Blob(["# New version"], { type: "text/markdown" }),
          },
        ])
      )
    );
    expect(
      screen.queryByRole("heading", { name: "Drive report" })
    ).not.toBeInTheDocument();
    expect(await screen.findByRole("heading", { name: "New version" })).toBeVisible();
    await act(async () => resolveSave(saved));
    expect(openDownload).not.toHaveBeenCalled();
    await chooseApp();
    await waitFor(() => expect(openDownload).toHaveBeenCalledOnce());
    expect(saveDownload).toHaveBeenCalledTimes(2);
  });

  it("a late read of the replaced Drive version cannot overwrite current content", async () => {
    let resolveRead!: (value: Blob) => void;
    const pendingRead = new Promise<Blob>((resolve) => {
      resolveRead = resolve;
    });
    state.store = new DriveStore(seed([{ ...file, contentsHash: "late-version-a" }]));
    state.backend = { readFile: vi.fn(() => pendingRead) } as unknown as DriveBackend;
    installNativeBridgeMock({ platform: "web" });
    renderPreview();
    await waitFor(() => expect(state.backend!.readFile).toHaveBeenCalledOnce());
    act(() =>
      state.store!.load(
        seed([
          {
            ...file,
            contentsHash: "late-version-b",
            blob: new Blob(["# Current Drive bytes"], { type: "text/markdown" }),
          },
        ])
      )
    );
    expect(
      await screen.findByRole("heading", { name: "Current Drive bytes" })
    ).toBeVisible();
    await act(async () =>
      resolveRead(new Blob(["# Stale Drive bytes"], { type: "text/markdown" }))
    );
    expect(
      screen.queryByRole("heading", { name: "Stale Drive bytes" })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Current Drive bytes" })).toBeVisible();
  });
});
