import type { DriveValue } from "@comma/core/contract";
import { useCall } from "@comma/core-client";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { toast } from "@comma/ui/components/toast";
import { useRef, useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { DriveStore, useDriveSnapshot, type DriveFile } from "../driveStore";
import { useDriveFileReveal, type DriveRevealSearch } from "../useDriveFileReveal";

const space = { id: "comma-drive", name: "Drive" };
const file: DriveFile = {
  contentsHash: "recording",
  deviceId: "this-mac",
  folderPath: "recording",
  id: "synch:comma-drive:recording/take.wav",
  modifiedAt: 0,
  name: "take.wav",
  sizeBytes: 30_000_000,
  spaceId: space.id,
};

const drive = (files: DriveFile[]): DriveValue => ({
  node: { status: "ready" },
  devices: [{ current: true, id: "this-mac", label: "This Mac" }],
  spaces: [{ id: "other", name: "Other" }, space],
  files,
  originDeviceId: "this-mac",
  versionPolicy: "newest",
  localSyncEnabled: false,
  localSyncRoot: "/Drive",
  syncHistory: [],
  transfers: [],
});

function Harness({ search, store }: { search: DriveRevealSearch; store: DriveStore }) {
  const call = useCall();
  const snapshot = useDriveSnapshot(store);
  const [folderPath, setFolderPath] = useState<readonly string[]>([]);
  const rootRef = useRef<HTMLDivElement>(null);
  useDriveFileReveal({
    call,
    folderPath,
    rootRef,
    search,
    setFolderPath,
    snapshot,
    store,
    onConsumed: () => {},
  });
  return (
    <div ref={rootRef}>
      <span data-testid="folder">{folderPath.join("/")}</span>
      {snapshot.files
        .filter(
          (entry) =>
            entry.spaceId === snapshot.selectedSpaceId &&
            (entry.folderPath ?? "") === folderPath.join("/")
        )
        .map((entry) => (
          <button data-testid={`drive-file-${entry.id}`} key={entry.id} type="button">
            {entry.name}
          </button>
        ))}
    </div>
  );
}

describe("Drive recording reveal", () => {
  it("waits for the core to list the file, opens its folder, and replays only on another request", async () => {
    let listed: DriveFile[] = [];
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "drive" ? drive(listed) : undefined),
      // The core finds the file and lists it, a while after it answered.
      calls: (name) => {
        if (name !== "drive.reveal") return null;
        queueMicrotask(() => {
          listed = [file];
          core.changed("drive");
        });
        return { file: file.id };
      },
    });
    const store = new DriveStore();
    const scroll = vi.spyOn(Element.prototype, "scrollIntoView");
    const search = { path: "recording/take.wav", space: space.id, reveal: "1" };
    const view = render(core.wrap(<Harness search={search} store={store} />));
    const row = await screen.findByTestId(`drive-file-${file.id}`);
    await waitFor(() => expect(row).toHaveAttribute("data-reveal-highlight", "true"));
    expect(row).toHaveFocus();
    expect(screen.getByTestId("folder")).toHaveTextContent("recording");
    expect(store.getSnapshot().selectedSpaceId).toBe(space.id);
    expect(scroll).toHaveBeenCalledWith({
      block: "center",
      inline: "nearest",
      behavior: "instant",
    });
    expect(scroll).toHaveBeenCalledTimes(1);
    core.changed("drive");
    expect(core.sentTo("drive.reveal")).toEqual([
      { path: "recording/take.wav", space: space.id },
    ]);
    view.rerender(
      core.wrap(<Harness search={{ ...search, reveal: "2" }} store={store} />)
    );
    await waitFor(() => expect(scroll).toHaveBeenCalledTimes(2));
    scroll.mockRestore();
  });

  it("announces a missing file instead of highlighting a stale row", async () => {
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "drive" ? drive([file]) : undefined),
      calls: () => {
        throw Object.assign(new Error("Deleted"), { code: "not_found" });
      },
    });
    const error = vi.spyOn(toast, "error");
    render(
      core.wrap(
        <Harness
          search={{ space: space.id, path: "recording/take.wav", reveal: "missing" }}
          store={new DriveStore()}
        />
      )
    );
    await waitFor(() =>
      expect(error).toHaveBeenCalledWith(
        "Recording could not be found in Drive.",
        expect.anything()
      )
    );
    expect(document.querySelector('[data-reveal-highlight="true"]')).toBeNull();
    error.mockRestore();
  });
});
