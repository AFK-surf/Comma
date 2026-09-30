import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type RefObject,
} from "react";
import type { DriveSynchronicityBackend } from "./driveSynchronicityBackend";
import type { DriveSnapshot, DriveStore } from "./driveStore";

export interface DriveRevealSearch {
  space?: string;
  path?: string;
  reveal?: string;
}

/** A single request owns one lookup and one post-mount scroll; no polling. */
export function useDriveFileReveal({
  backend,
  folderPath,
  onConsumed,
  rootRef,
  search,
  setFolderPath,
  snapshot,
  store,
}: {
  backend: DriveSynchronicityBackend | undefined;
  folderPath: readonly string[];
  onConsumed: () => void;
  rootRef: RefObject<HTMLElement | null>;
  search: DriveRevealSearch;
  setFolderPath: (path: readonly string[]) => void;
  snapshot: DriveSnapshot;
  store: DriveStore;
}) {
  const messages = useCommaMessages();
  const { space, path, reveal } = search;
  const [pending, setPending] = useState<{
    request: string;
    fileId: string;
    folder: string;
    space: string;
  }>();
  const consumed = useRef<string | undefined>(undefined);
  const fail = useCallback(
    () =>
      toast.error(messages.recording_reveal_failed(), {
        id: "recording-reveal-failed",
        testId: "recording-reveal-failed",
      }),
    [messages]
  );

  useEffect(() => {
    if (!space || !path || !reveal) return;
    const request = JSON.stringify([space, path, reveal]);
    if (consumed.current === request) return;
    let cancelled = false;
    setPending(undefined);
    void (async () => {
      try {
        if (
          path.startsWith("/") ||
          path.split("/").some((part) => !part || part === "." || part === "..")
        ) {
          throw new Error("Invalid Drive location.");
        }
        if (backend) {
          const resolved = await backend.lookupFile({ path, space });
          if (cancelled) return;
          store.revealFile(resolved);
        }
        if (cancelled) return;
        const current = store.getSnapshot();
        const file = current.files.find(
          (entry) =>
            entry.spaceId === space &&
            [entry.folderPath, entry.name].filter(Boolean).join("/") === path
        );
        const device = current.devices.find((entry) => entry.current);
        if (!file || !device) throw new Error("Drive file is unavailable.");
        consumed.current = request;
        store.selectSpace(space);
        store.setOriginDevice(device.id);
        const folder = file.folderPath ?? "";
        setFolderPath(folder ? folder.split("/") : []);
        setPending({ request, fileId: file.id, folder, space });
      } catch {
        if (!cancelled) {
          consumed.current = request;
          fail();
          onConsumed();
        }
      }
    })();
    return () => {
      cancelled = true;
    };
    // A request is consumed once. Store renders must not repeat its lookup.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [backend, path, reveal, setFolderPath, space, store]);

  useLayoutEffect(() => {
    if (
      !pending ||
      pending.request !== JSON.stringify([space, path, reveal]) ||
      snapshot.selectedSpaceId !== pending.space ||
      folderPath.join("/") !== pending.folder
    )
      return;
    const row = rootRef.current?.querySelector<HTMLElement>(
      `[data-testid="${CSS.escape(`drive-file-${pending.fileId}`)}"]`
    );
    setPending(undefined);
    if (!row) {
      fail();
      onConsumed();
      return;
    }
    row.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
    row.focus({ preventScroll: true });
    // Same visual hint as Reveal in Chat, including a repeat click's replay.
    row.removeAttribute("data-reveal-highlight");
    void row.offsetWidth;
    row.setAttribute("data-reveal-highlight", "true");
    onConsumed();
  }, [
    fail,
    folderPath,
    onConsumed,
    path,
    pending,
    reveal,
    rootRef,
    snapshot.selectedSpaceId,
    space,
  ]);
  return pending?.fileId;
}
