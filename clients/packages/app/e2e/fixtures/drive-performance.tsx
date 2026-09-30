import { useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { initializeCommaI18n } from "@comma/i18n";
import { DriveFileList } from "../../src/components/drive/DriveFileList";
import {
  DriveStore,
  useDriveSnapshot,
  type DriveFile,
} from "../../src/components/drive/driveStore";
import {
  useDriveFileReveal,
  type DriveRevealSearch,
} from "../../src/components/drive/useDriveFileReveal";
import "../../src/styles.css";

initializeCommaI18n(["en"]);

declare global {
  interface Window {
    driveStress: {
      load(count: number, folders?: boolean): void;
      reveal(index: number): void;
      thumbnails: string[];
    };
  }
}

const thumbnails: string[] = [];
const noAction = () => {};
const requestThumbnail = (file: DriveFile) => thumbnails.push(file.id);
const seed = {
  devices: [{ id: "device", label: "This device", current: true }],
  spaces: [{ id: "space", name: "Performance files" }],
  files: [],
  originDeviceId: "device",
};

function Fixture() {
  const [store] = useState(() => new DriveStore(seed));
  const snapshot = useDriveSnapshot(store);
  const files = snapshot.files;
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set());
  const [folder, setFolder] = useState<readonly string[]>([]);
  const [opened, setOpened] = useState("");
  const [search, setSearch] = useState<DriveRevealSearch>({});
  const rootRef = useRef<HTMLDivElement>(null);
  const revealFileId = useDriveFileReveal({
    backend: undefined,
    folderPath: folder,
    onConsumed: () => setSearch({}),
    rootRef,
    search,
    setFolderPath: setFolder,
    snapshot,
    store,
  });
  window.driveStress = {
    thumbnails,
    reveal(index) {
      const file = files[index]!;
      setSearch({
        space: "space",
        path: [file.folderPath, file.name].filter(Boolean).join("/"),
        reveal: String(Date.now()),
      });
    },
    load(count, folders = false) {
      thumbnails.length = 0;
      setSelected(new Set());
      setFolder([]);
      store.load({
        ...seed,
        files: Array.from({ length: count }, (_, index) => ({
          id: `file-${index}`,
          name: `Image ${String(index).padStart(5, "0")}.png`,
          contentsHash: `content-${index}`,
          deviceId: "device",
          spaceId: "space",
          modifiedAt: 1_750_000_000_000 + index,
          sizeBytes: 1024 + index,
          ...(folders ? { folderPath: `Folder ${Math.floor(index / 10)}/Nested` } : {}),
        })),
      });
    },
  };
  const toggleFiles = (entries: readonly DriveFile[], checked: boolean) =>
    setSelected((previous) => {
      const next = new Set(previous);
      for (const file of entries) {
        if (checked) next.add(file.id);
        else next.delete(file.id);
      }
      return next;
    });
  return (
    <div
      ref={rootRef}
      style={{ height: "100vh", display: "flex", flexDirection: "column" }}
    >
      <output data-testid="selection-count">{selected.size}</output>
      <output data-testid="opened-file">{opened}</output>
      <DriveFileList
        files={files}
        revealFileId={revealFileId}
        folderPath={folder}
        node={{ status: "ready" }}
        onDownload={noAction}
        onMenuAction={noAction}
        onNavigate={setFolder}
        onNeedThumbnail={requestThumbnail}
        onOpen={(file) => setOpened(file.id)}
        onRetryNode={noAction}
        onSelectionMenuAction={noAction}
        onToggleFiles={toggleFiles}
        onToggleSelected={(file, checked) => toggleFiles([file], checked)}
        onUploadFiles={noAction}
        selectedFileIds={selected}
        selecting={selected.size > 0}
        selectionKeptOffline={false}
        spaceName="Performance files"
        writable
      />
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<Fixture />);
