import { useCallback, useMemo, useState } from "react";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { useNavigate } from "@tanstack/react-router";
import { useCall, useTopic } from "@comma/core-client";
import type { CommaTaskLabelApprovalPolicy } from "@comma/core/api-schemas";
import { useProductInboxProjection } from "../../product-inbox";
import { useActiveWorkspaceId } from "../activeWorkspace";
import { useTaskLabelsCatalogStatus } from "../chat/tasks/labels/useTaskLabelsCatalog";
import { useLabelProposalTitle } from "./LabelProposalList";
import { TaskLabelsPage, type TaskLabelDraft } from "./TaskLabelsSettings";

/**
 * The Settings › Labels category: a page of its own (title, toolbar, table)
 * rather than a list of setting rows. Agent proposals still waiting for the
 * person sit above the table. General Permissions shares this Group's catalog
 * and server-owned approval policy.
 */
export function useTaskLabelsCategory(enabled: boolean, policyEnabled = false) {
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const locale = useCommaLocale();
  const workspaceId = useActiveWorkspaceId();
  const { result } = useProductInboxProjection({
    enabled: enabled || policyEnabled,
    ...(workspaceId ? { workspaceId } : {}),
  });
  const workspace = result?.workspaces?.find(
    (w) => w.id === (workspaceId ?? result?.activeWorkspaceId)
  );
  const groupId = workspace?.group_id;

  const call = useCall();
  const { catalog, error, loading, refresh } = useTaskLabelsCatalogStatus(
    groupId,
    enabled || policyEnabled
  );
  const [busy, setBusy] = useState<string>();
  const [saveError, setSaveError] = useState(false);

  // Label usage counts come from the Task list (the core reads its first page again when the catalog changes); a
  // failed count read only hides the column, never the catalog.
  const { value: counts } = useTopic(
    enabled && groupId
      ? {
          topic: "taskLabelCounts",
          group: groupId,
          key: String(catalog?.updated_at ?? ""),
        }
      : null
  );

  const mutate = useCallback(async (key: string, run: () => Promise<unknown>) => {
    setBusy(key);
    setSaveError(false);
    try {
      await run();
    } catch {
      setSaveError(true);
    } finally {
      setBusy(undefined);
    }
  }, []);

  const onCreate = useCallback(
    (draft: TaskLabelDraft) => {
      if (!groupId) return;
      void mutate("create", () =>
        call("taskLabels.create", { group: groupId, ...draft })
      );
    },
    [call, groupId, mutate]
  );
  const onUpdate = useCallback(
    (labelId: string, draft: Partial<TaskLabelDraft>) => {
      if (!groupId) return;
      void mutate(labelId, () =>
        call("taskLabels.update", { group: groupId, label: labelId, ...draft })
      );
    },
    [call, groupId, mutate]
  );
  const onDelete = useCallback(
    (labelId: string) => {
      if (!groupId) return;
      void mutate(labelId, () =>
        call("taskLabels.delete", { group: groupId, label: labelId })
      );
    },
    [call, groupId, mutate]
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
        call("taskLabels.resolve", { group: groupId, proposal: proposalId, decision })
      );
    },
    [call, groupId, mutate]
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
        counts={counts ?? undefined}
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
        void mutate("policy", () =>
          call("taskLabels.setPolicy", { group: groupId, policy })
        );
      },
    },
  };
}
