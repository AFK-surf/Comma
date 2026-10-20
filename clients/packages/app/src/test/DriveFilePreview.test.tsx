import type { DriveFile, DriveValue } from "@comma/core/contract";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { StrictMode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { resetDriveStoreForTest } from "../components/drive/driveStore";
import { DrivePreviewPanel } from "../components/drive/DrivePreviewPanel";

const file: DriveFile = {
  id: "drive-file",
  contentsHash: "version-a",
  deviceId: "mac",
  modifiedAt: 1,
  name: "report.md",
  sizeBytes: 20,
  spaceId: "space",
};
const drive = (files: DriveFile[]): DriveValue => ({
  node: { status: "ready" },
  originDeviceId: "mac",
  devices: [{ current: true, id: "mac", label: "This Mac" }],
  spaces: [{ id: "space", name: "Space", writable: true }],
  files,
  versionPolicy: "newest",
  localSyncEnabled: false,
  localSyncRoot: "/Drive",
  syncHistory: [],
  transfers: [],
});
const markdown = (text: string) => ({
  bytes: new TextEncoder().encode(text),
  mediaType: "text/markdown",
});

/** The core's Drive lists `listed`; `read` answers its `drive.read`. */
let listed: DriveFile[];
let read: (params: { file: string }) => unknown;
let core: ReturnType<typeof createScriptedCore>;
const relist = (files: DriveFile[]) => {
  listed = files;
  core.changed("drive");
};
const applicationId = `fap1_${"a".repeat(43)}`;
const saved = {
  status: "saved" as const,
  fileName: file.name,
  downloadRef: `dnl1_${"b".repeat(43)}`,
};
const onOpenBrowser = vi.fn();
const renderPreview = () =>
  render(
    core.wrap(
      <StrictMode>
        <DrivePreviewPanel
          fileId={file.id}
          panelId="drive-preview"
          onOpenBrowser={onOpenBrowser}
        />
      </StrictMode>
    )
  );
async function chooseApp() {
  fireEvent.click(screen.getByRole("button", { name: "Choose application" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: /Preview/ }));
}

beforeEach(() => {
  resetDriveStoreForTest();
  listed = [file];
  read = () => markdown("# Drive report");
  core = createScriptedCore({
    values: (topic) => (topic.topic === "drive" ? drive(listed) : undefined),
    calls: (name, params) =>
      name === "drive.read"
        ? read(params as { file: string })
        : name === "drive.download"
          ? {
              transfer: "t1",
              saved: { downloadRef: saved.downloadRef, fileName: file.name },
            }
          : null,
  });
});

describe("Drive uses the shared file reader", () => {
  it("opens the read file from the common toolbar under StrictMode without reading it again", async () => {
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
    expect(core.sentTo("drive.read")).toEqual([{ file: file.id }]);
  });
  it("downloads through the core and reports failed preview reads in the common error UI", async () => {
    const rendererSave = vi.fn();
    listed = [{ ...file, sizeBytes: 20_000_000 }];
    read = () => {
      throw new Error("Unavailable preview");
    };
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
    await waitFor(() =>
      expect(core.sentTo("drive.download")).toEqual([{ file: file.id }])
    );
    expect(rendererSave).not.toHaveBeenCalled();
  });

  it("plays a large recording from a ranged stream without reading the whole file", async () => {
    const recording = { ...file, name: "recording.m4a", sizeBytes: 24_000_000 };
    const streamUrl = "comma-drive://stream/0f8fad5b-d9cb-469f-a165-70867728950e";
    listed = [recording];
    const openStream = vi.fn(async () => ({
      status: "opened" as const,
      url: streamUrl,
    }));
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      synchronicity: { openStream },
    });
    renderPreview();
    await waitFor(() =>
      expect(
        screen.getByTestId("file-preview-content").querySelector("audio")
      ).toHaveAttribute("src", streamUrl)
    );
    expect(openStream).toHaveBeenCalledWith(
      expect.objectContaining({ path: "recording.m4a", space: "space" })
    );
    expect(core.sentTo("drive.read")).toEqual([]);
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
    read = () => markdown("# New version");
    relist([{ ...file, contentsHash: "version-b" }]);
    expect(await screen.findByRole("heading", { name: "New version" })).toBeVisible();
    expect(
      screen.queryByRole("heading", { name: "Drive report" })
    ).not.toBeInTheDocument();
    await act(async () => resolveSave(saved));
    expect(openDownload).not.toHaveBeenCalled();
    await chooseApp();
    await waitFor(() => expect(openDownload).toHaveBeenCalledOnce());
    expect(saveDownload).toHaveBeenCalledTimes(2);
  });

  it("a late read of the replaced Drive version cannot overwrite current content", async () => {
    let resolveRead!: (value: unknown) => void;
    listed = [{ ...file, contentsHash: "late-version-a" }];
    read = () => new Promise((resolve) => (resolveRead = resolve));
    installNativeBridgeMock({ platform: "web" });
    renderPreview();
    await waitFor(() => expect(core.sentTo("drive.read")).toHaveLength(1));
    const late = resolveRead;
    read = () => markdown("# Current Drive bytes");
    relist([{ ...file, contentsHash: "late-version-b" }]);
    expect(
      await screen.findByRole("heading", { name: "Current Drive bytes" })
    ).toBeVisible();
    await act(async () => late(markdown("# Stale Drive bytes")));
    expect(
      screen.queryByRole("heading", { name: "Stale Drive bytes" })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Current Drive bytes" })).toBeVisible();
  });
});
