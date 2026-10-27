import { useDriveCatalogMentions } from "../../drive/useDriveCatalogMentions";
import { useTaskSummaries } from "../../tasks/useTaskArchive";
import { driveNodeAvailable, ensureDriveFileBlob } from "../../drive/driveBackend";
import {
  getDriveStore,
  useDriveSnapshot,
  type DriveFile,
  type DriveSnapshot,
} from "../../drive/driveStore";
import { useCallback, useMemo, useState } from "react";
import {
  taskStatusBucket,
  type TaskStatusBucket,
} from "@comma/ui/components/task-workspace";
import type {
  RecommendationDocumentPart,
  RecommendationEnvelope,
  RecommendationSource,
} from "@comma/recommendation-contract";
import { useCall, useTopic, useTopicSelect } from "@comma/core-client";
import type { MentionTask } from "@comma/core/contract";
import { useOnboardingAhead } from "../../onboarding/useOnboardingAhead";

/**
 * Tasks, routines, and plugins come from the client core, which keeps them
 * fresh. Drive queries Main's shared metadata index only while the menu is
 * open. Loading sources keep their searching row visible.
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

/** A model the workspace can run, named in the Router chat to start a Task with it. */
export interface ComposerModelMentionItem {
  id: string;
  name: string;
  vendor: string;
  /** The thinking efforts it takes; none: it has only its default. */
  efforts: readonly string[];
}

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
    /** The items already match the menu's query (the core searched for it). */
    prefiltered?: boolean | undefined;
    /** What the "@" menu asks for while it is open; null once it closed. */
    onMenuQueryChange?: ((query: string | null) => void) | undefined;
    retry?: (() => void) | undefined;
    browse?: ReturnType<typeof useDriveCatalogMentions>["browse"] | undefined;
  };
  /** Models a Task can run with: in the Router chat only (`models`), read once the menu first opens. */
  models: MentionSourceState<ComposerModelMentionItem>;
  plugins: MentionSourceState<ComposerPluginMentionItem>;
  routines: MentionSourceState<ComposerRoutineMentionItem>;
  tasks: MentionSourceState<ComposerTaskMentionItem>;
}

const EMPTY_ITEMS: never[] = [];

function taskItems(
  tasks: readonly MentionTask[],
  excludeConversationId: string | undefined
): ComposerTaskMentionItem[] {
  return tasks
    .filter((task) => task.id !== excludeConversationId)
    .map((task) => ({
      conversationId: task.id,
      statusBucket: taskStatusBucket(task.status),
      title: task.title,
      updatedAt: task.updatedAt,
    }));
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
 * menu's short list is the head of this. Each reads its bytes through the core.
 */
export function driveMentionItems(
  snapshot: Pick<DriveSnapshot, "files" | "spaces">,
  readFile: (file: DriveFile) => Promise<Blob>
): ComposerDriveMentionItem[] {
  const spaceNames = new Map(snapshot.spaces.map((space) => [space.id, space.name]));
  return snapshot.files.toSorted(compareDriveRecency).flatMap((file) => {
    const spaceName = spaceNames.get(file.spaceId);
    if (spaceName === undefined) return [];
    const location = driveLocationLabel(spaceName, file.folderPath);
    return [{ file, location, read: () => readFile(file) }];
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
  const call = useCall();
  // With this device's node, the core searches its index; without one (the web), the Drive the core reads for it.
  const node = driveNodeAvailable();
  const catalog = useDriveCatalogMentions(store, enabled && node);
  // The web reads Drive once the "@" menu first opens, not for every composer shown.
  const [asked, setAsked] = useState(false);
  const onMenuQueryChange = useCallback((query: string | null) => {
    if (query !== null) setAsked(true);
  }, []);
  const snapshot = useDriveSnapshot(store, enabled && !node && asked);
  return useMemo(
    () =>
      node
        ? { ...catalog, prefiltered: true }
        : {
            items:
              enabled && asked
                ? driveMentionItems(snapshot, (file) =>
                    ensureDriveFileBlob(store, call, file)
                  )
                : EMPTY_ITEMS,
            status: "ready" as const,
            onMenuQueryChange,
          },
    [asked, call, catalog, enabled, node, onMenuQueryChange, snapshot, store]
  );
}

export function useComposerMentionSources({
  enabled = true,
  excludeConversationId,
  groupId,
  models: modelsShown = false,
  workspaceId,
}: {
  enabled?: boolean;
  excludeConversationId?: string | undefined;
  groupId: string | undefined;
  /** The Router chat: a model named there starts a Task with it. */
  models?: boolean;
  workspaceId: string | undefined;
}): ComposerMentionSources {
  // Which of the Group's Tasks the focused list holds archived, as one key: the
  // list's other changes (statuses, unread marks) render nothing here.
  const archivedKey = useTopicSelect({ topic: "tasks", workspace: "" }, (value) =>
    enabled && groupId
      ? (value?.items ?? [])
          .filter((item) => item.groupId === groupId && item.status === "archived")
          .map((item) => item.conversationId)
          .join("\u0000")
      : ""
  );
  // The Group's Tasks as the core keeps them (null while it reads them). Let go at
  // once, so a later showing finds out whether they are a minute old.
  const { value: groupTasks } = useTopic(
    enabled && groupId ? { topic: "mentionTasks", group: groupId } : null,
    { lingerMs: 0 }
  );
  // Reading the Routines creates them: while the first-launch onboarding is
  // ahead they wait for its apps step, which starts them with every app it
  // connected.
  const onboardingAhead = useOnboardingAhead();
  const routinesShown = enabled && !onboardingAhead && !!workspaceId;

  // The briefing as the core reads it, once per showing of the list.
  const { value: briefing } = useTopic(
    routinesShown
      ? { topic: "recommendations", workspace: workspaceId, reads: "once" }
      : null
  );
  const routines = useMemo<MentionSourceState<ComposerRoutineMentionItem>>(
    () =>
      !routinesShown
        ? { items: EMPTY_ITEMS, status: "ready" }
        : briefing?.envelope
          ? { items: routineItems(briefing.envelope), status: "ready" }
          : briefing?.failure
            ? { items: EMPTY_ITEMS, status: "ready" }
            : { items: EMPTY_ITEMS, status: "loading" },
    [briefing, routinesShown]
  );
  // The workspace's plugins as the client core keeps them.
  const { value: catalog } = useTopic(
    enabled && workspaceId ? { topic: "plugins", workspace: workspaceId } : null
  );
  const driveSource = useDriveMentionSource(enabled);
  // The workspace's models are read once the "@" menu first opens here (the
  // Settings page's read: three requests).
  const [modelsAsked, setModelsAsked] = useState(false);
  const askModels = modelsShown && !modelsAsked;
  const driveQuery = driveSource.onMenuQueryChange;
  const onMenuQueryChange = useCallback(
    (query: string | null) => {
      driveQuery?.(query);
      if (query !== null && askModels) setModelsAsked(true);
    },
    [askModels, driveQuery]
  );
  const drive = useMemo(
    () => ({ ...driveSource, onMenuQueryChange }),
    [driveSource, onMenuQueryChange]
  );
  const { value: shownModels } = useTopic(
    enabled && modelsShown && modelsAsked && workspaceId
      ? { topic: "models", prefer: workspaceId }
      : null
  );
  const models = useMemo<MentionSourceState<ComposerModelMentionItem>>(
    () =>
      !modelsShown || !modelsAsked
        ? { items: EMPTY_ITEMS, status: "ready" }
        : shownModels?.catalog
          ? {
              items: shownModels.models
                .filter((model) => model.serving.length > 0)
                .map((model) => ({
                  id: model.id,
                  name: model.name,
                  vendor: model.vendor,
                  efforts: model.efforts,
                })),
              status: "ready",
            }
          : { items: EMPTY_ITEMS, status: shownModels?.error ? "ready" : "loading" },
    [modelsAsked, modelsShown, shownModels]
  );

  const tasks = useMemo<MentionSourceState<ComposerTaskMentionItem>>(() => {
    if (!enabled || !groupId) return { items: EMPTY_ITEMS, status: "ready" };
    if (!groupTasks) return { items: EMPTY_ITEMS, status: "loading" };
    const archived = new Set(archivedKey.split("\u0000"));
    return {
      items: taskItems(
        groupTasks.filter((task) => !archived.has(task.id)),
        excludeConversationId
      ),
      status: "ready",
    };
  }, [archivedKey, enabled, excludeConversationId, groupTasks, groupId]);
  const plugins = useMemo<MentionSourceState<ComposerPluginMentionItem>>(
    () => ({
      items:
        catalog?.status === "ready"
          ? catalog.plugins
              .filter((plugin) => plugin.installed)
              .map((plugin) => ({
                brand: plugin.brand,
                id: plugin.id,
                name: plugin.name,
                summary: plugin.summary,
              }))
          : [],
      status: catalog?.status === "loading" ? "loading" : "ready",
    }),
    [catalog]
  );

  // A routine's Task shows only while the core knows it is not archived.
  const routineTasks = useTaskSummaries(
    groupId ?? "",
    useMemo(
      () =>
        routines.items.flatMap((item) =>
          item.kind === "task" ? [item.conversationId] : []
        ),
      [routines.items]
    )
  );
  const hiddenRoutines = routines.items
    .filter((item) => {
      if (item.kind !== "task") return false;
      const status = routineTasks.get(item.conversationId)?.status;
      return status === undefined || status === "archived";
    })
    .map((item) => item.id)
    .join("\u0000");
  const visibleRoutines = useMemo(() => {
    const hidden = new Set(hiddenRoutines.split("\u0000"));
    return {
      ...routines,
      items: routines.items.filter((item) => !hidden.has(item.id)),
    };
  }, [routines, hiddenRoutines]);
  return useMemo(
    () => ({ drive, models, plugins, routines: visibleRoutines, tasks }),
    [drive, models, plugins, visibleRoutines, tasks]
  );
}
