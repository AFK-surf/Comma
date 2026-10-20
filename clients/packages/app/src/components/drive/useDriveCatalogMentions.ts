import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  useCall,
  useTopic,
  type CallFn,
  type DriveCatalogItem,
} from "@comma/core-client";
import type { ComposerDriveMentionItem } from "../chat/composer/useComposerMentionSources";
import { ensureDriveFileBlob } from "./driveBackend";
import type { DriveStore } from "./driveStore";

/** The menu shows a few; browsing shows a page of 50 more each time. */
const MENU_LIMIT = 5;
const BROWSE_PAGE = 50;

type Page = {
  items: ComposerDriveMentionItem[];
  status: "loading" | "ready";
  error?: string | undefined;
  /** There are more matches than shown. */
  more: boolean;
};

const idle: Page = { items: [], status: "ready", more: false };

/**
 * The composer's Drive mentions: the core's Drive search (`driveSearch`) for what the menu or the browse panel types,
 * mapped to mention items. The core keeps the index current while one is shown; this only asks and shows.
 */
export function useDriveCatalogMentions(store: DriveStore, enabled: boolean) {
  const call = useCall();
  const [menuQuery, onMenuQueryChange] = useState<string | null>(null);
  const [browse, setBrowse] = useState<{ query: string; pages: number } | null>(null);
  const onBrowseQueryChange = useCallback(
    (query: string | null) => setBrowse(query === null ? null : { query, pages: 1 }),
    []
  );
  const loadMore = useCallback(
    () => setBrowse((current) => current && { ...current, pages: current.pages + 1 }),
    []
  );
  const retry = useCallback(
    () => void call("driveSearch.retry", {}).catch(() => undefined),
    [call]
  );

  const menu = useSearchPage(
    enabled && menuQuery !== null ? { query: menuQuery, limit: MENU_LIMIT } : null,
    store,
    call
  );
  const browsed = useSearchPage(
    enabled && browse
      ? { query: browse.query, limit: browse.pages * BROWSE_PAGE }
      : null,
    store,
    call
  );
  // The browse panel keeps what it showed while a larger page loads.
  const loadingMore = !!browse && browse.pages > 1 && browsed.status === "loading";
  return useMemo(
    () => ({
      ...menu,
      onMenuQueryChange,
      retry,
      browse: {
        ...browsed,
        loadingMore,
        onQueryChange: onBrowseQueryChange,
        loadMore,
        retry,
      },
    }),
    [browsed, loadMore, loadingMore, menu, onBrowseQueryChange, retry]
  );
}

/** One Drive search as mention items; `null` asks nothing. */
function useSearchPage(
  asking: { query: string; limit: number } | null,
  store: DriveStore,
  call: CallFn
): Page {
  // A query typed past is let go at once: only what is shown keeps the core reading the node.
  const search = useTopic(
    asking
      ? { topic: "driveSearch", query: asking.query, limit: String(asking.limit) }
      : null,
    { lingerMs: 0 }
  );
  const query = asking?.query ?? null;
  // A larger page of the same query keeps the smaller one on screen until it comes.
  const last = useRef<{ query: string; page: Page } | null>(null);
  const page = useMemo((): Page => {
    if (query === null) return idle;
    const value = search.value;
    if (!value) {
      const kept = last.current?.query === query ? last.current.page : null;
      return kept
        ? { ...kept, status: "loading" }
        : { items: [], status: "loading", more: false, error: search.error?.message };
    }
    const items = value.items.map((item) => mentionItem(item, store, call));
    return {
      items,
      status: value.status === "loading" && items.length === 0 ? "loading" : "ready",
      error:
        value.status === "error"
          ? value.reason
          : value.status === "unavailable"
            ? "Drive is unavailable."
            : search.error?.message,
      more: value.more,
    };
  }, [call, query, search.error, search.value, store]);
  useEffect(() => {
    if (query !== null && search.value) last.current = { query, page };
  });
  return page;
}

function mentionItem(
  { entry, spaceId, spaceName }: DriveCatalogItem,
  store: DriveStore,
  call: CallFn
): ComposerDriveMentionItem {
  const slash = entry.path.lastIndexOf("/");
  const folderPath = slash >= 0 ? entry.path.slice(0, slash) : undefined;
  const file = {
    // The core's id for the node's file (`drive`), which `drive.read` reads.
    id: `synch:${spaceId}:${entry.path}`,
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
    read: () => ensureDriveFileBlob(store, call, file),
  };
}
