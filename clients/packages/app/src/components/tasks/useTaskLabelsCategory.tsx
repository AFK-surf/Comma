import { useCallback, useEffect, useMemo, useState } from "react";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui";
import { useNavigate } from "@tanstack/react-router";
import type {
  CommaApiClient,
  CommaTaskLabelApprovalPolicy,
  CommaTaskLabelCatalog,
} from "../../api";
import { useCommaAuth } from "../AuthGate";
import { useProductInboxProjection } from "../../product-inbox";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";
import { useTaskLabelsCatalogStatus } from "../chat/tasks/labels/useTaskLabelsCatalog";
import { useLabelProposalTitle } from "./LabelProposalList";
import { TaskLabelsPage, type TaskLabelDraft } from "./TaskLabelsSettings";

/**
 * The Settings › Labels category: a page of its own (title, toolbar, table)
 * rather than a list of setting rows. Agent proposals still waiting for the
 * person sit above the table. General Permissions shares this Group's catalog
 * and server-owned approval policy.
 */
export function useTaskLabelsCategory(
  api: CommaApiClient,
  enabled: boolean,
  policyEnabled = false
) {
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const locale = useCommaLocale();
  const auth = useCommaAuth();
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  useEffect(() => subscribeActiveWorkspace(setWorkspaceId), []);
  const { result } = useProductInboxProjection({
    enabled: enabled || policyEnabled,
    session: auth.productLease,
    ...(workspaceId ? { workspaceId } : {}),
  });
  const workspace = result?.workspaces?.find(
    (w) => w.id === (workspaceId ?? result?.activeWorkspaceId)
  );
  const groupId = workspace?.group_id;

  const { catalog, error, loading, refresh, replace } = useTaskLabelsCatalogStatus(
    api,
    groupId,
    enabled || policyEnabled
  );
  const [busy, setBusy] = useState<string>();
  const [saveError, setSaveError] = useState(false);

  // Label usage counts come from the Task list the app already exposes; a
  // failed count read only hides the column, never the catalog.
  const [counts, setCounts] = useState<Record<string, number>>();
  useEffect(() => {
    if (!enabled || !groupId) return undefined;
    // The closure flag, not a ref, is what the cleanup flips: each effect run
    // owns exactly one request and a superseded one simply drops its result.
    let cancelled = false;
    void api
      .listConversations(groupId)
      .then((tasks) => {
        if (cancelled) return;
        const next: Record<string, number> = {};
        for (const task of tasks) {
          for (const id of task.labels ?? []) next[id] = (next[id] ?? 0) + 1;
        }
        setCounts(next);
      })
      .catch(() => {
        if (!cancelled) setCounts(undefined);
      });
    return () => {
      cancelled = true;
    };
  }, [api, enabled, groupId, catalog?.updated_at]);

  const mutate = useCallback(
    async (key: string, run: () => Promise<CommaTaskLabelCatalog>) => {
      setBusy(key);
      setSaveError(false);
      try {
        replace(await run());
      } catch {
        setSaveError(true);
      } finally {
        setBusy(undefined);
      }
    },
    [replace]
  );

  const onCreate = useCallback(
    (draft: TaskLabelDraft) => {
      if (!groupId) return;
      void mutate("create", () => api.createTaskLabel(groupId, draft));
    },
    [api, groupId, mutate]
  );
  const onUpdate = useCallback(
    (labelId: string, draft: Partial<TaskLabelDraft>) => {
      if (!groupId) return;
      void mutate(labelId, () => api.updateTaskLabel(groupId, labelId, draft));
    },
    [api, groupId, mutate]
  );
  const onDelete = useCallback(
    (labelId: string) => {
      if (!groupId) return;
      void mutate(labelId, () => api.deleteTaskLabel(groupId, labelId));
    },
    [api, groupId, mutate]
  );
  const onViewTasks = useCallback(
    (labelId: string) => {
      void navigate({ search: { label: labelId }, to: "/tasks" });
    },
    [navigate]
  );
  const onResolveProposal = useCallback(
    (proposalId: string, decision: "approve" | "reject") => {
      if (!groupId) return;
      void mutate(proposalId, () =>
        api.resolveTaskLabelProposal(groupId, proposalId, decision)
      );
    },
    [api, groupId, mutate]
  );

  const pendingProposals = useMemo(
    () =>
      (catalog?.proposals ?? []).filter(
        (proposal) =>
          proposal.status === "pending" ||
          (proposal.status === "approved" &&
            ["pending", "conflict"].includes(proposal.application_status ?? ""))
      ),
    [catalog]
  );

  const proposalTitle = useLabelProposalTitle(catalog);

  const category: SettingsCategoryDefinition = {
    id: "labels",
    icon: "labels",
    keywords: ["label", "tag", "标签"],
    label: messages.settings_labels(),
    title: messages.settings_labels_title(),
    // Search still needs one indexable entry for the page; the page itself
    // renders through `content`.
    sections: [
      {
        id: "labels.catalog",
        title: messages.settings_labels_title(),
        items: [
          {
            id: "labels.catalog.table",
            title: messages.settings_labels_title(),
            description: messages.settings_labels_description(),
          },
        ],
      },
    ],
    content: (
      <TaskLabelsPage
        busy={busy}
        catalog={catalog}
        counts={counts}
        error={
          error
            ? messages.settings_labels_error()
            : saveError
              ? messages.settings_labels_save_failed()
              : undefined
        }
        loading={loading && !catalog}
        locale={locale}
        onCreate={onCreate}
        onDelete={onDelete}
        onResolveProposal={onResolveProposal}
        onRetry={() => void refresh()}
        onUpdate={onUpdate}
        onViewTasks={onViewTasks}
        onViewProposalTask={(conversationId) => {
          if (!workspace?.id || !groupId) return;
          void navigate({
            to: "/tasks/$workspaceId/$groupId/$conversationId",
            params: { workspaceId: workspace.id, groupId, conversationId },
          });
        }}
        pendingProposals={pendingProposals}
        proposalTitle={proposalTitle}
      />
    ),
  };
  return {
    category,
    approvalPolicy: {
      value: catalog?.approval_policy ?? "ask",
      disabled: !groupId || !catalog || loading || busy !== undefined,
      error: error || saveError,
      set: (policy: CommaTaskLabelApprovalPolicy) => {
        if (!groupId) return;
        void mutate("policy", () => api.setTaskLabelApprovalPolicy(groupId, policy));
      },
    },
  };
}
