import { useDriveCatalogMentions } from "../../drive/useDriveCatalogMentions";
import {
  readTaskSummary,
  requestTaskSummary,
  subscribeTaskSummaries,
} from "../../tasks/taskArchiveState";
import { useProductInboxSnapshot } from "../../../product-inbox";
import { getDriveBackend } from "../../drive/driveBackend";
import {
  getDriveStore,
  type DriveFile,
  type DriveSnapshot,
} from "../../drive/driveStore";
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { taskStatusBucket, type TaskStatusBucket } from "@comma/ui";
import type {
  RecommendationDocumentPart,
  RecommendationEnvelope,
  RecommendationSource,
} from "@comma/recommendation-contract";
import type { CommaApiClient, CommaConversation, CommaPlugin } from "../../../api";

/**
 * Tasks, routines, and plugins use a short per-scope cache. Drive queries
 * Main's shared metadata index only while the menu is open. Loading sources
 * keep their searching row visible.
 */
export interface ComposerTaskMentionItem {
  conversationId: string;
  statusBucket: TaskStatusBucket;
  title: string;
  updatedAt: number;
}

export type ComposerRoutineMentionItem = {
  id: string;
  label: string;
  source?: RecommendationSource | undefined;
} & ({ kind: "link"; href: string } | { kind: "task"; conversationId: string });

export interface ComposerPluginMentionItem {
  brand?: string | null | undefined;
  id: string;
  name: string;
  summary?: string | undefined;
}

/**
 * A Drive file the composer can attach: the file, where it lives as one
 * label ("Folder A", "Folder A / drafts / q3"), and its bytes on demand —
 * from the node, or from the file itself when they are already here.
 */
export interface ComposerDriveMentionItem {
  file: DriveFile;
  location: string;
  read: () => Promise<Blob>;
}

/** One folder's files, for the browse panel: the location label over its rows. */
export interface ComposerDriveMentionSection {
  id: string;
  items: ComposerDriveMentionItem[];
  label: string;
}

export interface MentionSourceState<Item> {
  items: Item[];
  status: "loading" | "ready";
}

export interface ComposerMentionSources {
  drive: MentionSourceState<ComposerDriveMentionItem> & {
    error?: string | undefined;
    onMenuQueryChange?: ((query: string | null) => void) | undefined;
    retry?: (() => void) | undefined;
    browse?: ReturnType<typeof useDriveCatalogMentions>["browse"] | undefined;
  };
  plugins: MentionSourceState<ComposerPluginMentionItem>;
  routines: MentionSourceState<ComposerRoutineMentionItem>;
  tasks: MentionSourceState<ComposerTaskMentionItem>;
}

const CACHE_TTL_MS = 60 * 1000;

type CacheEntry<Value> =
  | { state: "loading"; promise: Promise<Value> }
  | { state: "ready"; fetchedAt: number; value: Value };

let cachesByApi = new WeakMap<CommaApiClient, Map<string, CacheEntry<unknown>>>();

export function resetComposerMentionSourcesCacheForTest() {
  cachesByApi = new WeakMap();
}

function loadCached<Value>(
  api: CommaApiClient,
  key: string,
  fetch: () => Promise<Value>,
  empty: Value
): Promise<Value> {
  let cache = cachesByApi.get(api);
  if (!cache) {
    cache = new Map();
    cachesByApi.set(api, cache);
  }

  const cached = cache.get(key) as CacheEntry<Value> | undefined;
  if (cached?.state === "ready" && Date.now() - cached.fetchedAt < CACHE_TTL_MS) {
    return Promise.resolve(cached.value);
  }
  if (cached?.state === "loading") {
    return cached.promise;
  }

  const promise = fetch().then(
    (value) => {
      cache.set(key, { fetchedAt: Date.now(), state: "ready", value });
      return value;
    },
    () => {
      // A failed source degrades to an empty section; the next menu open
      // retries because the failure is never cached.
      cache.delete(key);
      return empty;
    }
  );
  cache.set(key, { promise, state: "loading" });
  while (cache.size > 128) cache.delete(cache.keys().next().value!);
  return promise;
}

function readyCached<Value>(api: CommaApiClient, key: string): Value | undefined {
  const cached = cachesByApi.get(api)?.get(key) as CacheEntry<Value> | undefined;
  return cached?.state === "ready" && Date.now() - cached.fetchedAt < CACHE_TTL_MS
    ? cached.value
    : undefined;
}

const EMPTY_ITEMS: never[] = [];

interface ScopedMentionSourceState<Item> {
  api: CommaApiClient | undefined;
  key: string | undefined;
  value: MentionSourceState<Item>;
}

function mentionSourceStateForScope<Item>(
  api: CommaApiClient | undefined,
  key: string | undefined
): ScopedMentionSourceState<Item> {
  const cached = api && key ? readyCached<Item[]>(api, key) : undefined;
  return {
    api,
    key,
    value: cached
      ? { items: cached, status: "ready" }
      : { items: EMPTY_ITEMS, status: api && key ? "loading" : "ready" },
  };
}

function useMentionSource<Item>(
  api: CommaApiClient | undefined,
  key: string | undefined,
  fetch: () => Promise<Item[]>
): MentionSourceState<Item> {
  const [state, setState] = useState<ScopedMentionSourceState<Item>>(() =>
    mentionSourceStateForScope<Item>(api, key)
  );
  const visibleState =
    state.api === api && state.key === key
      ? state
      : mentionSourceStateForScope<Item>(api, key);

  useEffect(() => {
    if (!api || !key) {
      setState({
        api,
        key,
        value: { items: EMPTY_ITEMS, status: "ready" },
      });
      return undefined;
    }

    const cached = readyCached<Item[]>(api, key);
    if (cached) {
      setState((current) =>
        current.api === api &&
        current.key === key &&
        current.value.items === cached &&
        current.value.status === "ready"
          ? current
          : { api, key, value: { items: cached, status: "ready" } }
      );
      return undefined;
    }

    let cancelled = false;
    setState({
      api,
      key,
      value: { items: EMPTY_ITEMS, status: "loading" },
    });
    void loadCached(api, key, fetch, EMPTY_ITEMS as Item[]).then((items) => {
      if (!cancelled) {
        setState({ api, key, value: { items, status: "ready" } });
      }
    });
    return () => {
      cancelled = true;
    };
    // The key encodes every fetch input; fetch identity is deliberately loose.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api, key]);

  return visibleState.value;
}

function taskItems(
  conversations: CommaConversation[],
  excludeConversationId: string | undefined
): ComposerTaskMentionItem[] {
  return conversations
    .filter(
      (conversation) =>
        conversation.kind === "agent_task" &&
        conversation.status !== "archived" &&
        conversation.id !== excludeConversationId &&
        conversation.title.trim().length > 0
    )
    .map((conversation) => ({
      conversationId: conversation.id,
      statusBucket: taskStatusBucket(conversation.status),
      title: conversation.title,
      updatedAt: conversation.updated_at ?? 0,
    }))
    .toSorted((a, b) => b.updatedAt - a.updatedAt);
}

function collectRoutineParts(
  parts: readonly RecommendationDocumentPart[],
  sourcesByConnection: ReadonlyMap<string, RecommendationSource>,
  seen: Set<string>,
  items: ComposerRoutineMentionItem[]
) {
  for (const part of parts) {
    if (part.kind === "inline-link") {
      const id = `link:${part.link.href}`;
      if (seen.has(id)) continue;
      seen.add(id);
      items.push({
        href: part.link.href,
        id,
        kind: "link",
        label: part.link.label,
        source: part.link.sourceId
          ? sourcesByConnection.get(part.link.sourceId)
          : undefined,
      });
    } else if (part.kind === "inline-task") {
      const id = `task:${part.task.conversationId}`;
      if (seen.has(id)) continue;
      seen.add(id);
      items.push({
        conversationId: part.task.conversationId,
        id,
        kind: "task",
        label: part.task.label,
        source: part.task.sourceId
          ? sourcesByConnection.get(part.task.sourceId)
          : undefined,
      });
    }
  }
}

/**
 * The "Routines" section lists the inline entities the routine summaries
 * mention — the links and Tasks the agent surfaced — so a mention refers to
 * something durable (a URL or a Task) rather than a snapshot-scoped card id.
 */
function routineItems(envelope: RecommendationEnvelope): ComposerRoutineMentionItem[] {
  const snapshot = envelope.snapshot;
  if (!snapshot) return [];

  const sourcesByConnection = new Map(
    envelope.settings.sources.map((source) => [source.connectionId, source])
  );
  const items: ComposerRoutineMentionItem[] = [];
  const seen = new Set<string>();

  collectRoutineParts(snapshot.summary, sourcesByConnection, seen, items);
  for (const card of snapshot.cards) {
    if (!Array.isArray(card.items)) continue;
    for (const item of card.items) {
      if (
        item &&
        typeof item === "object" &&
        "parts" in item &&
        Array.isArray((item as { parts?: unknown }).parts)
      ) {
        collectRoutineParts(
          (item as { parts: RecommendationDocumentPart[] }).parts,
          sourcesByConnection,
          seen,
          items
        );
      }
    }
  }

  return items;
}

/** Files newest first; a tie keeps the listing's order. */
const compareDriveRecency = (a: DriveFile, b: DriveFile) => b.modifiedAt - a.modifiedAt;

const driveLocationLabel = (spaceName: string, folderPath: string | undefined) =>
  folderPath ? `${spaceName} / ${folderPath.replaceAll("/", " / ")}` : spaceName;

/**
 * The Drive files the composer can hand to an upload, newest first — the
 * menu's short list is the head of this. With a node every file reads
 * through it; without one only a file whose bytes are already here can be
 * attached, so the demo store's unsynced rows stay out of the list.
 */
export function driveMentionItems(
  snapshot: Pick<DriveSnapshot, "files" | "spaces">,
  readFile: ((file: DriveFile) => Promise<Blob>) | undefined
): ComposerDriveMentionItem[] {
  const spaceNames = new Map(snapshot.spaces.map((space) => [space.id, space.name]));
  return snapshot.files.toSorted(compareDriveRecency).flatMap((file) => {
    const spaceName = spaceNames.get(file.spaceId);
    if (spaceName === undefined) return [];
    const location = driveLocationLabel(spaceName, file.folderPath);
    if (readFile) return [{ file, location, read: () => readFile(file) }];
    const { blob } = file;
    return blob ? [{ file, location, read: () => Promise.resolve(blob) }] : [];
  });
}

/**
 * The same files arranged for browsing: one section per folder, the folder
 * with the newest file first, files newest first inside it — so the top of
 * the panel is where the menu's short list came from.
 */
export function driveMentionSections(
  items: readonly ComposerDriveMentionItem[]
): ComposerDriveMentionSection[] {
  const sections = new Map<string, ComposerDriveMentionSection>();
  for (const item of items) {
    const id = `${item.file.spaceId}/${item.file.folderPath ?? ""}`;
    const section = sections.get(id);
    if (section) section.items.push(item);
    else sections.set(id, { id, items: [item], label: item.location });
  }
  return [...sections.values()];
}

function useDriveMentionSource(enabled: boolean): ComposerMentionSources["drive"] {
  const store = getDriveStore();
  const backend = enabled ? getDriveBackend() : undefined;
  const catalog = useDriveCatalogMentions(store, backend);
  const snapshot = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
    store.getSnapshot
  );
  return useMemo(
    () =>
      backend
        ? catalog
        : {
            items: enabled ? driveMentionItems(snapshot, undefined) : EMPTY_ITEMS,
            status: "ready" as const,
          },
    [backend, catalog, enabled, snapshot]
  );
}

export function useComposerMentionSources({
  api,
  enabled = true,
  excludeConversationId,
  groupId,
  workspaceId,
}: {
  api: CommaApiClient | undefined;
  enabled?: boolean;
  excludeConversationId?: string | undefined;
  groupId: string | undefined;
  workspaceId: string | undefined;
}): ComposerMentionSources {
  const projection = useProductInboxSnapshot();
  const subscribeSummaries = useCallback(
    (listener: () => void) => (api ? subscribeTaskSummaries(api, listener) : () => {}),
    [api]
  );
  // Each source needs its client method to exist: reduced clients (embedded
  // surfaces, partial test stubs) simply lose that section instead of
  // throwing, and the panel degrades to whatever sources remain.
  const tasksKey =
    enabled && groupId && typeof api?.listConversations === "function"
      ? `tasks ${groupId} ${projection?.snapshot.lastSyncedAt ?? 0}`
      : undefined;
  const routinesKey =
    enabled && workspaceId && typeof api?.getRecommendations === "function"
      ? `routines ${workspaceId}`
      : undefined;
  const pluginsKey =
    enabled && workspaceId && typeof api?.listWorkspacePlugins === "function"
      ? `plugins ${workspaceId}`
      : undefined;

  const rawTasks = useMentionSource<CommaConversation>(api, tasksKey, () =>
    api!.listConversations(groupId!)
  );
  const routines = useMentionSource<ComposerRoutineMentionItem>(api, routinesKey, () =>
    api!.getRecommendations(workspaceId!).then(routineItems)
  );
  const rawPlugins = useMentionSource<CommaPlugin>(api, pluginsKey, () =>
    api!.listWorkspacePlugins(workspaceId!)
  );
  const drive = useDriveMentionSource(enabled);

  const tasks = useMemo<MentionSourceState<ComposerTaskMentionItem>>(
    () => ({
      items: taskItems(
        rawTasks.items.filter(
          (task) =>
            !projection?.snapshot.items.some(
              (item) =>
                item.conversationId === task.id &&
                item.groupId === groupId &&
                item.status === "archived"
            )
        ),
        excludeConversationId
      ),
      status: rawTasks.status,
    }),
    [excludeConversationId, rawTasks, projection, groupId]
  );
  const plugins = useMemo<MentionSourceState<ComposerPluginMentionItem>>(
    () => ({
      items: rawPlugins.items
        .filter((plugin) => plugin.installed)
        .map((plugin) => ({
          brand: plugin.brand,
          id: plugin.id,
          name: plugin.name,
          summary: plugin.summary,
        })),
      status: rawPlugins.status,
    }),
    [rawPlugins]
  );

  useEffect(() => {
    if (!api || !groupId) return undefined;
    const request = () => {
      for (const item of routines.items)
        if (item.kind === "task") requestTaskSummary(api, groupId, item.conversationId);
    };
    request();
    // An owner read marks cached facts stale without rendering the composer;
    // ask again once it has.
    return subscribeTaskSummaries(api, request);
  }, [api, groupId, routines.items]);
  // Read as one key, so the conversation renders again only when a routine's
  // Task changes whether it is shown, not on every change to the cache.
  const readHiddenRoutines = () =>
    routines.items
      .filter((item) => {
        if (item.kind !== "task") return false;
        const canonical =
          api && groupId
            ? readTaskSummary(api, groupId, item.conversationId)
            : undefined;
        const live = projection?.snapshot.items.find(
          (task) =>
            task.groupId === groupId && task.conversationId === item.conversationId
        );
        const status =
          live && (live.archiveVersion ?? 0) >= (canonical?.updated_at ?? 0)
            ? live.status
            : canonical?.status;
        return status === undefined || status === "archived";
      })
      .map((item) => item.id)
      .join("\u0000");
  const hiddenRoutines = useSyncExternalStore(
    subscribeSummaries,
    readHiddenRoutines,
    readHiddenRoutines
  );
  const visibleRoutines = useMemo(() => {
    const hidden = new Set(hiddenRoutines.split("\u0000"));
    return {
      ...routines,
      items: routines.items.filter((item) => !hidden.has(item.id)),
    };
  }, [routines, hiddenRoutines]);
  return useMemo(
    () => ({ drive, plugins, routines: visibleRoutines, tasks }),
    [drive, plugins, visibleRoutines, tasks]
  );
}
