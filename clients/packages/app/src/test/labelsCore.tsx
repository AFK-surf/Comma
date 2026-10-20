import type { TaskLabelCatalog, TaskLabelsValue } from "@comma/core/contract";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act } from "@comma/test-utils/render";
import type { ReactNode } from "react";

/** A Group's catalog as the core keeps it (after the server's JSON is read): the fields a test leaves out are empty. */
export function labelCatalog(
  catalog: Partial<TaskLabelCatalog> = {}
): TaskLabelCatalog {
  return { approval_policy: "ask", colors: [], labels: [], proposals: [], ...catalog };
}

/**
 * What the core answers a `taskLabels.*` call with: the catalog the change (or a read, for `taskLabels.refresh`)
 * brought, which every reader then sees; `undefined` keeps the catalog as it is. Throwing fails the call (an Error
 * with `code`/`status`/`detail` for the failure the UI words); a failed `taskLabels.refresh` keeps the catalog and
 * reports `error`, as the core does.
 */
export type LabelsAnswer = (
  name: string,
  params: Record<string, unknown>,
  kept: TaskLabelCatalog | null
) => TaskLabelCatalog | undefined | Promise<TaskLabelCatalog | undefined>;

/**
 * A scripted core for a UI test of Task labels: every `taskLabels` topic shows `catalog` (with `error`/`loading`),
 * every `taskLabelCounts` topic shows `counts`, and each `taskLabels.*` call the UI sends is recorded (`sentTo`) and
 * answered by `answer`. Wrap a UI in it, or give its `client` to another scripted core (`delegateScriptedCore`).
 */
export function labelsCore({
  catalog = null,
  error = false,
  loading = false,
  counts = null,
  answer = () => undefined,
}: {
  catalog?: TaskLabelCatalog | null;
  error?: boolean;
  loading?: boolean;
  counts?: Record<string, number> | null;
  answer?: LabelsAnswer;
} = {}) {
  let value: TaskLabelsValue = { catalog, error, loading };
  /** Each `taskLabels` topic a UI subscribed to, in order (the core reads the catalog for each but a `known` one). */
  const subscribed: Record<string, unknown>[] = [];
  const scripted = createScriptedCore({
    owns: (name) => name === "taskLabelCounts" || name.startsWith("taskLabels"),
    values: (topic) =>
      topic.topic === "taskLabels"
        ? value
        : topic.topic === "taskLabelCounts"
          ? counts
          : undefined,
    onSubscribe: (topic) => {
      if (topic.topic === "taskLabels") subscribed.push(topic);
    },
    calls: async (name, raw) => {
      const params = (raw ?? {}) as Record<string, unknown>;
      try {
        const next = await answer(name, params, value.catalog);
        if (next !== undefined || value.error)
          set({ catalog: next ?? value.catalog, error: false });
      } catch (failure) {
        if (name === "taskLabels.refresh") set({ error: true });
        throw failure;
      }
      return null;
    },
  });
  /** Changes what the `taskLabels` topics show and sends it to every reader. */
  function set(next: Partial<TaskLabelsValue>) {
    value = { ...value, ...next };
    scripted.changed("taskLabels");
  }
  return {
    ...scripted,
    /** What the `taskLabels` topics show now. */
    value: () => value,
    subscribed,
    /** Changes what the topics show, inside `act` (the UI sees it on the next `flush`). */
    set: (next: Partial<TaskLabelsValue>) => act(() => set(next)),
    /** For renderHook and render: `{ wrapper }`. */
    wrapper: ({ children }: { children: ReactNode }) => scripted.wrap(children),
  };
}
