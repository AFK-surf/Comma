import { dataTransferHasFiles } from "@comma/ui";
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type DragEvent as ReactDragEvent,
} from "react";

/** A dropped file and the directory inside the drop it came from, "" at the top. */
export interface DriveDroppedFile {
  file: File;
  relativeDir: string;
}

/**
 * Everything a drop carries, folders walked. The browser hands a dropped
 * folder over as an entry rather than as its files, and the path the folder
 * picker relies on (`webkitRelativePath`) is empty on a drop, so the
 * directory travels beside each file instead. Entries have to be taken from
 * the transfer synchronously — the items list is gone once the event ends.
 */
export function collectDroppedFiles(
  transfer: DataTransfer
): Promise<DriveDroppedFile[]> {
  const entries = Array.from(transfer.items ?? []).map((item) =>
    typeof item.webkitGetAsEntry === "function" ? item.webkitGetAsEntry() : null
  );
  if (!entries.some((entry) => entry !== null)) {
    return Promise.resolve(
      Array.from(transfer.files).map((file) => ({ file, relativeDir: "" }))
    );
  }
  return (async () => {
    const collected: DriveDroppedFile[] = [];
    for (const entry of entries) {
      if (entry) await walkEntry(entry, "", collected);
    }
    return collected;
  })();
}

async function walkEntry(entry: FileSystemEntry, dir: string, out: DriveDroppedFile[]) {
  if (entry.isFile) {
    const file = await new Promise<File>((resolve, reject) => {
      (entry as FileSystemFileEntry).file(resolve, reject);
    });
    out.push({ file, relativeDir: dir });
    return;
  }
  if (!entry.isDirectory) return;
  const reader = (entry as FileSystemDirectoryEntry).createReader();
  const nextDir = dir ? `${dir}/${entry.name}` : entry.name;
  // A reader answers a batch at a time and an empty batch at the end.
  for (;;) {
    const batch = await new Promise<FileSystemEntry[]>((resolve, reject) => {
      reader.readEntries(resolve, reject);
    });
    if (batch.length === 0) break;
    for (const child of batch) await walkEntry(child, nextDir, out);
  }
}

/**
 * The composer's drop zone, on a pane: the overlay shows while files are
 * dragged over the element these handlers are spread on, and the transfer
 * is handed over on drop. Enter/leave are counted because every child the
 * pointer crosses fires its own pair. While mounted, a drop that misses the
 * pane must not navigate the window to the file, and a drag that ends
 * elsewhere must still clear the overlay.
 */
export function useDriveDropZone(
  onDrop: (transfer: DataTransfer) => void,
  enabled = true
) {
  const [active, setActive] = useState(false);
  const depthRef = useRef(0);
  const reset = useCallback(() => {
    depthRef.current = 0;
    setActive(false);
  }, []);

  useEffect(() => {
    if (!enabled) reset();
  }, [enabled, reset]);

  useEffect(() => {
    const guard = (event: DragEvent) => {
      if (dataTransferHasFiles(event.dataTransfer)) event.preventDefault();
    };
    window.addEventListener("dragover", guard);
    window.addEventListener("drop", guard);
    window.addEventListener("drop", reset);
    window.addEventListener("dragend", reset);
    return () => {
      window.removeEventListener("dragover", guard);
      window.removeEventListener("drop", guard);
      window.removeEventListener("drop", reset);
      window.removeEventListener("dragend", reset);
    };
  }, [reset]);

  const onDragEnter = useCallback(
    (event: ReactDragEvent<HTMLElement>) => {
      if (!enabled) return;
      if (!dataTransferHasFiles(event.dataTransfer)) return;
      event.preventDefault();
      depthRef.current += 1;
      setActive(true);
    },
    [enabled]
  );

  const onDragOver = useCallback(
    (event: ReactDragEvent<HTMLElement>) => {
      if (!enabled) return;
      if (!dataTransferHasFiles(event.dataTransfer)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
    },
    [enabled]
  );

  const onDragLeave = useCallback(() => {
    if (!enabled) return;
    if (depthRef.current === 0) return;
    depthRef.current = Math.max(0, depthRef.current - 1);
    if (depthRef.current === 0) setActive(false);
  }, [enabled]);

  const onDropHandler = useCallback(
    (event: ReactDragEvent<HTMLElement>) => {
      if (!enabled) return;
      if (!dataTransferHasFiles(event.dataTransfer)) return;
      event.preventDefault();
      event.stopPropagation();
      const transfer = event.dataTransfer;
      reset();
      onDrop(transfer);
    },
    [enabled, onDrop, reset]
  );

  return {
    active,
    handlers: { onDragEnter, onDragLeave, onDragOver, onDrop: onDropHandler },
  };
}
