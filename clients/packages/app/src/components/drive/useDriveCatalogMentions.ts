import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  getNativeBridge,
  type DriveCatalogQueryInput,
  type DriveCatalogQueryResult,
} from "@comma/native-bridge";
import type { ComposerDriveMentionItem } from "../chat/composer/useComposerMentionSources";
import { ensureDriveFileBlob } from "./driveBackend";
import {
  driveFileIdFor,
  type DriveSynchronicityBackend,
} from "./driveSynchronicityBackend";
import type { DriveStore } from "./driveStore";

type Page = {
  items: ComposerDriveMentionItem[];
  status: "loading" | "ready";
  error?: string | undefined;
  cursor?: DriveCatalogQueryResult["nextCursor"];
};
const emptyPage = (): Page => ({ items: [], status: "ready" });
// Share simultaneous requests across composers/windows in this renderer. Main
// owns the installation-wide metadata pipeline and never scans in query().
const pending = new Map<string, Promise<DriveCatalogQueryResult>>();
function queryCatalog(input: DriveCatalogQueryInput) {
  const key = JSON.stringify(input);
  let request = pending.get(key);
  if (!request) {
    request = getNativeBridge()
      .driveCatalog.query(input)
      .finally(() => pending.delete(key));
    pending.set(key, request);
  }
  return request;
}

export function useDriveCatalogMentions(
  store: DriveStore,
  backend: DriveSynchronicityBackend | undefined
) {
  const [menuQuery, onMenuQueryChange] = useState<string | null>(null);
  const [browseQuery, onBrowseQueryChange] = useState<string | null>(null);
  const [menu, setMenu] = useState<Page>(emptyPage);
  const [browse, setBrowse] = useState<Page>(emptyPage);
  const [loadingMore, setLoadingMore] = useState(false);
  const epoch = useRef(0);
  const currentLoad = useRef<((append?: boolean, retry?: boolean) => void) | undefined>(
    undefined
  );
  const cursorRef = useRef<DriveCatalogQueryResult["nextCursor"]>(undefined);
  const loadMore = useCallback(() => currentLoad.current?.(true), []);
  const retry = useCallback(() => currentLoad.current?.(false, true), []);
  const inBrowse = browseQuery !== null;
  const activeQuery = browseQuery ?? menuQuery;

  useEffect(() => {
    if (!backend || activeQuery === null) return;
    const generation = ++epoch.current;
    const update = inBrowse ? setBrowse : setMenu;
    let disposed = false;
    let busy = false;
    let queued = false;
    let queuedRefresh = false;
    let queuedRetry = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let automaticFailures = 0;
    let lastRevision = -1;
    let loadedItems: ComposerDriveMentionItem[] = [];
    cursorRef.current = undefined;
    update({ items: [], status: "loading" });
    const isCurrent = () => !disposed && epoch.current === generation;
    const load = async (append = false, forceRetry = false, refresh = false) => {
      if (busy) {
        if (!append) queued = true;
        queuedRefresh ||= refresh;
        queuedRetry ||= forceRetry;
        return;
      }
      if (append && !cursorRef.current) return;
      busy = true;
      if (append) setLoadingMore(true);
      try {
        const result = await queryCatalog({
          query: activeQuery,
          limit: inBrowse ? 50 : 5,
          ...(append && cursorRef.current ? { cursor: cursorRef.current } : {}),
          ...(forceRetry ? { retry: true } : {}),
          ...(refresh ? { refresh: true } : {}),
        });
        if (!isCurrent()) return;
        const items: ComposerDriveMentionItem[] = result.items.map(
          ({ entry, spaceId, spaceName }) => {
            const slash = entry.path.lastIndexOf("/");
            const folderPath = slash >= 0 ? entry.path.slice(0, slash) : undefined;
            const file = {
              id: driveFileIdFor(spaceId, entry.path),
              spaceId,
              name: entry.path.slice(slash + 1),
              ...(folderPath ? { folderPath } : {}),
              deviceId: entry.origin,
              modifiedAt: entry.mtimeMs,
              contentsHash: entry.contentRoot.slice(0, 19),
              sizeBytes: entry.size,
            };
            return {
              file,
              location: folderPath
                ? `${spaceName} / ${folderPath.replaceAll("/", " / ")}`
                : spaceName,
              read: () => ensureDriveFileBlob(store, backend, file),
            };
          }
        );
        const keepPages =
          !append &&
          result.state.revision === lastRevision &&
          loadedItems.length > items.length;
        if (!keepPages) cursorRef.current = result.nextCursor;
        loadedItems = keepPages
          ? loadedItems
          : append && !result.reset
            ? [...loadedItems, ...items]
            : items;
        loadedItems = [
          ...new Map(loadedItems.map((item) => [item.file.id, item])).values(),
        ];
        lastRevision = result.state.revision;
        automaticFailures = result.state.status === "error" ? 1 : 0;
        update({
          items: loadedItems,
          status:
            result.state.status === "loading" && !loadedItems.length
              ? "loading"
              : "ready",
          error: result.state.status === "error" ? result.state.reason : undefined,
          cursor: cursorRef.current,
        });
      } catch (error) {
        if (isCurrent()) {
          automaticFailures = 1;
          update((previous) => ({
            ...previous,
            status: "ready",
            error: error instanceof Error ? error.message : "Drive is unavailable.",
          }));
        }
      } finally {
        busy = false;
        if (isCurrent()) {
          setLoadingMore(false);
          if (queued) {
            queued = false;
            const retryNext = queuedRetry,
              refreshNext = queuedRefresh;
            queuedRetry = false;
            queuedRefresh = false;
            void load(false, retryNext, refreshNext);
          }
        }
      }
    };
    currentLoad.current = (append, forceRetry) => {
      void load(append, forceRetry);
    };
    const refresh = () => {
      if (!automaticFailures) void load(false, false, true);
    };
    const unsubscribe = getNativeBridge().driveCatalog.state.subscribe((state) => {
      if (state.status === "ready" || state.status === "error") void load();
    });
    // At most one small query per visible composer per 20 seconds (normally
    // one, at most main and side chat). Main merges all catalog refresh work.
    const interval = setInterval(() => {
      if (document.visibilityState === "visible") refresh();
    }, 20_000);
    window.addEventListener("focus", refresh);
    timer = setTimeout(() => void load(false, false, true), activeQuery ? 200 : 0);
    return () => {
      disposed = true;
      currentLoad.current = undefined;
      clearTimeout(timer);
      clearInterval(interval);
      unsubscribe();
      window.removeEventListener("focus", refresh);
    };
  }, [activeQuery, backend, inBrowse, store]);

  return useMemo(
    () => ({
      ...menu,
      onMenuQueryChange,
      retry,
      browse: {
        ...browse,
        loadingMore,
        onQueryChange: onBrowseQueryChange,
        loadMore,
        retry,
      },
    }),
    [browse, loadMore, loadingMore, menu, retry]
  );
}
