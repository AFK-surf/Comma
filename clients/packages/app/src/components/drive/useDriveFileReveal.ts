import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui/components/toast";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type RefObject,
} from "react";
import type { CallFn } from "@comma/core-client";
import type { DriveSnapshot, DriveStore } from "./driveStore";

export interface DriveRevealSearch {
  space?: string;
  path?: string;
  reveal?: string;
}

/** A single request owns one lookup and one post-mount scroll; no polling. */
export function useDriveFileReveal({
  call,
  folderPath,
  onConsumed,
  rootRef,
  search,
  setFolderPath,
  snapshot,
  store,
}: {
  call: CallFn;
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
        // The core finds the one file without listing the rest of its space.
        const { file } = await call("drive.reveal", { path, space });
        if (cancelled) return;
        consumed.current = request;
        store.selectSpace(space);
        const slash = path.lastIndexOf("/");
        const folder = slash === -1 ? "" : path.slice(0, slash);
        setFolderPath(folder ? folder.split("/") : []);
        setPending({ request, fileId: file, folder, space });
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
  }, [call, path, reveal, setFolderPath, space, store]);

  useLayoutEffect(() => {
    if (
      !pending ||
      pending.request !== JSON.stringify([space, path, reveal]) ||
      snapshot.selectedSpaceId !== pending.space ||
      folderPath.join("/") !== pending.folder ||
      // The core's Drive has the file once its change reached this window.
      !snapshot.files.some((file) => file.id === pending.fileId)
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
    snapshot.files,
    snapshot.selectedSpaceId,
    space,
  ]);
  return pending?.fileId;
}
