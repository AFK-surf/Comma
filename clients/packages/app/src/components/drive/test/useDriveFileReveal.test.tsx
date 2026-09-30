import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { toast } from "@comma/ui";
import { useRef, useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { DriveStore, useDriveSnapshot, type DriveFile } from "../driveStore";
import type { DriveSynchronicityBackend } from "../driveSynchronicityBackend";
import { useDriveFileReveal, type DriveRevealSearch } from "../useDriveFileReveal";

const device = { current: true, id: "this-mac", label: "This Mac" };
const space = { id: "comma-drive", name: "Drive" };
const file: DriveFile = {
  contentsHash: "recording",
  deviceId: device.id,
  folderPath: "recording",
  id: "synch:comma-drive:recording/take.wav",
  modifiedAt: 0,
  name: "take.wav",
  sizeBytes: 30_000_000,
  spaceId: space.id,
};

function Harness({
  backend,
  search,
  store,
}: {
  backend?: DriveSynchronicityBackend;
  search: DriveRevealSearch;
  store: DriveStore;
}) {
  const snapshot = useDriveSnapshot(store);
  const [folderPath, setFolderPath] = useState<readonly string[]>([]);
  const rootRef = useRef<HTMLDivElement>(null);
  useDriveFileReveal({
    backend,
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

const seed = () =>
  new DriveStore({
    devices: [device, { current: false, id: "remote", label: "Remote" }],
    spaces: [{ id: "other", name: "Other" }, space],
    files: [],
  });

describe("Drive recording reveal", () => {
  it("waits for the exact row, switches folder/device, and replays only on another request", async () => {
    const store = seed();
    store.setOriginDevice("remote");
    const lookupFile = vi.fn(async () => ({ device, file, space }));
    const backend = { lookupFile } as unknown as DriveSynchronicityBackend;
    const scroll = vi.spyOn(Element.prototype, "scrollIntoView");
    const search = { path: "recording/take.wav", space: space.id, reveal: "1" };
    const view = render(<Harness backend={backend} search={search} store={store} />);
    const row = await screen.findByTestId(`drive-file-${file.id}`);
    await waitFor(() => expect(row).toHaveAttribute("data-reveal-highlight", "true"));
    expect(row).toHaveFocus();
    expect(screen.getByTestId("folder")).toHaveTextContent("recording");
    expect(store.getSnapshot().originDeviceId).toBe(device.id);
    expect(scroll).toHaveBeenCalledWith({
      block: "center",
      inline: "nearest",
      behavior: "instant",
    });
    expect(scroll).toHaveBeenCalledTimes(1);
    act(() => store.setNodeStatus({ status: "ready" }));
    expect(lookupFile).toHaveBeenCalledTimes(1);
    view.rerender(
      <Harness backend={backend} search={{ ...search, reveal: "2" }} store={store} />
    );
    await waitFor(() => expect(scroll).toHaveBeenCalledTimes(2));
    expect(row).not.toHaveAttribute("aria-selected");
    scroll.mockRestore();
  });

  it("announces a missing file instead of highlighting a stale row", async () => {
    const store = seed();
    store.revealFile({ device, file, space });
    const error = vi.spyOn(toast, "error");
    const backend = {
      lookupFile: vi.fn(async () => {
        throw new Error("Deleted");
      }),
    } as unknown as DriveSynchronicityBackend;
    render(
      <Harness
        backend={backend}
        search={{ space: space.id, path: "recording/take.wav", reveal: "missing" }}
        store={store}
      />
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
