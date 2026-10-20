import { useCallback, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { InputField } from "@comma/ui/components/input";
import { MoreHorizontalIcon, PlusIcon } from "@comma/ui/components/icons";
import {
  type SettingsCategoryDefinition,
  type SettingsCategoryDetail,
} from "@comma/ui/components/settings";
import { type SettingsPanelItem } from "@comma/ui/components/settings-panel";
import { useCall, useTopic } from "@comma/core-client";
import type { CommaCondensedWorkspaceOperation } from "@comma/core/api-schemas";
import { useWorkspacePreference } from "../activeWorkspace";

type Editor = { id?: string; text: string };

/**
 * Settings › Condensed Workspace: the Group's shared list of current facts
 * that every Router and Worker Session keeps in context. The owner turns it
 * on and edits the statements; Agents keep it current with their own tool.
 */
export function useCondensedWorkspaceCategory(enabled: boolean) {
  const m = useCommaMessages();
  const call = useCall();
  const prefer = useWorkspacePreference();
  // The core reads it when the category opens, for the active workspace's Group.
  const { value } = useTopic(
    enabled && prefer !== undefined ? { topic: "condensedWorkspace", prefer } : null
  );
  const state = value?.state ?? undefined;
  const groupId = value?.group ?? undefined;
  const [writeFailed, setWriteFailed] = useState(false);
  const failed = (value?.error ?? false) || writeFailed;
  const [busy, setBusy] = useState(false);
  const [editor, setEditor] = useState<Editor>();

  const run = useCallback(async (write: () => Promise<unknown>) => {
    setBusy(true);
    setWriteFailed(false);
    try {
      await write();
      return true;
    } catch {
      setWriteFailed(true);
      return false;
    } finally {
      setBusy(false);
    }
  }, []);

  const apply = useCallback(
    (operations: CommaCondensedWorkspaceOperation[]) =>
      groupId
        ? run(() => call("condensedWorkspace.apply", { group: groupId, operations }))
        : undefined,
    [call, groupId, run]
  );

  const save = useCallback(async () => {
    const text = editor?.text.trim();
    if (!editor || !text) return;
    const done = await apply([
      editor.id ? { op: "replace", id: editor.id, text } : { op: "add", text },
    ]);
    if (done) setEditor(undefined);
  }, [apply, editor]);

  const statementRows: SettingsPanelItem[] = (state?.statements ?? []).map(
    (statement) => ({
      id: `condensed-workspace.statement.${statement.id}`,
      title: statement.text,
      control: {
        type: "menu",
        label: m.settings_condensed_workspace_statement_actions(),
        icon: <MoreHorizontalIcon />,
        disabled: busy,
        items: [
          {
            id: "edit",
            label: m.settings_condensed_workspace_edit(),
            onPress: () => setEditor({ id: statement.id, text: statement.text }),
          },
          {
            id: "remove",
            label: m.settings_condensed_workspace_remove(),
            tone: "destructive",
            onPress: () => void apply([{ op: "remove", id: statement.id }]),
          },
        ],
      },
    })
  );

  const summaryRows: SettingsPanelItem[] = [
    ...(state && statementRows.length === 0
      ? [
          {
            id: "condensed-workspace.empty",
            title: m.settings_condensed_workspace_empty(),
          },
        ]
      : []),
    ...(state
      ? [
          {
            id: "condensed-workspace.size",
            title: m.settings_condensed_workspace_size({
              bytes: String(state.bytes),
              recommended: String(state.recommended_max_bytes),
            }),
          },
        ]
      : []),
  ];

  const category: SettingsCategoryDefinition = {
    id: "condensed-workspace",
    icon: "general",
    keywords: ["condensed", "workspace", "facts", "agents", "共享事实"],
    label: m.settings_condensed_workspace(),
    sections: [
      {
        id: "condensed-workspace.feature",
        title: m.settings_condensed_workspace(),
        items: [
          {
            id: "condensed-workspace.enabled",
            title: m.settings_condensed_workspace_enabled(),
            description: failed
              ? m.settings_condensed_workspace_failed()
              : m.settings_condensed_workspace_description(),
            control: {
              type: "toggle",
              checked: state?.enabled ?? false,
              disabled: !groupId || !state || busy,
              onChange: (event) => {
                if (!groupId) return;
                const checked = event.target.checked;
                void run(() =>
                  call("condensedWorkspace.setEnabled", {
                    group: groupId,
                    enabled: checked,
                  })
                );
              },
            },
          },
        ],
      },
      {
        id: "condensed-workspace.statements",
        title: m.settings_condensed_workspace_statements(),
        titleAction: (
          <Button
            hierarchy="secondary-gray"
            iconLeading={<PlusIcon />}
            isDisabled={!state || busy}
            onPress={() => setEditor({ text: "" })}
            size="sm"
          >
            {m.settings_condensed_workspace_add()}
          </Button>
        ),
        items: [...statementRows, ...summaryRows],
      },
    ],
  };

  const detail: SettingsCategoryDetail | undefined = editor
    ? {
        id: "condensed-workspace.editor",
        title: editor.id
          ? m.settings_condensed_workspace_edit()
          : m.settings_condensed_workspace_add(),
        description: m.settings_condensed_workspace_editor_hint(),
        backLabel: m.settings_condensed_workspace(),
        onBack: () => setEditor(undefined),
        onSubmit: () => void save(),
        actions: (
          <Button
            hierarchy="primary"
            isDisabled={busy || !editor.text.trim()}
            onPress={() => void save()}
            size="sm"
          >
            {m.settings_condensed_workspace_save()}
          </Button>
        ),
        content: (
          <InputField
            aria-label={m.settings_condensed_workspace_statement()}
            onChange={(event) => setEditor({ ...editor, text: event.target.value })}
            placeholder={m.settings_condensed_workspace_statement()}
            value={editor.text}
          />
        ),
      }
    : undefined;

  return detail ? { ...category, detail } : category;
}
