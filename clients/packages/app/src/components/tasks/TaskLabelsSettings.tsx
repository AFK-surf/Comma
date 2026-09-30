import { LoadingIndicator } from "@comma/ui";
import type { CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  EditBigIcon,
  FlashcardsIcon,
  InputField,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  MoreHorizontalIcon,
  PlusIcon,
  TrashCanIcon,
} from "@comma/ui";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
} from "react";
import { Input, TextField as AriaTextField } from "react-aria-components";
import { InlineTextEditor } from "./InlineTextEditor";
import { LabelColorPicker } from "./LabelColorPicker";
import type {
  CommaTaskLabel,
  CommaTaskLabelCatalog,
  CommaTaskLabelProposal,
} from "../../api";
import { LabelProposalList } from "./LabelProposalList";

export type TaskLabelDraft = { name: string; color: string; description?: string };

export interface TaskLabelsPageProps {
  /** Id of the label / proposal (or "create") whose write is in flight. */
  busy: string | undefined;
  catalog: CommaTaskLabelCatalog | undefined;
  /** Task count per label id; absent while unknown. */
  counts: Record<string, number> | undefined;
  error: string | undefined;
  loading: boolean;
  locale: CommaLocale;
  onCreate: (draft: TaskLabelDraft) => void;
  onDelete: (labelId: string) => void;
  onResolveProposal: (proposalId: string, decision: "approve" | "reject") => void;
  onRetry: () => void;
  onUpdate: (labelId: string, draft: Partial<TaskLabelDraft>) => void;
  /** Opens the Task list narrowed to this label. */
  onViewTasks: (labelId: string) => void;
  onViewProposalTask: (conversationId: string) => void;
  /** Requests awaiting approval or needing attention after Task application failed. */
  pendingProposals: readonly CommaTaskLabelProposal[];
  proposalTitle: (proposal: CommaTaskLabelProposal) => string;
}

// Tailwind only emits classes it can see, so each swatch is a literal.
const DEFAULT_COLOR = "gray";

/**
 * Moves focus into the field inside the wrapped element the moment it mounts,
 * without the autoFocus attribute (which a11y tooling rightly flags).
 */
function useFocusOnMount() {
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    ref.current?.querySelector("input")?.focus();
  }, []);
  return ref;
}

/**
 * A text field that sits exactly where the static text was: no padding of its
 * own, the cell's font, and its edge painted outside the box (see
 * `.comma-inline-field`), so opening it never moves the text or grows the row.
 */
function InlineField({
  ariaLabel,
  className = "",
  onBlur,
  onChange,
  onKeyDown,
  placeholder,
  value,
}: {
  ariaLabel: string;
  className?: string;
  onBlur?: (() => void) | undefined;
  onChange: (next: string) => void;
  onKeyDown: (event: KeyboardEvent<HTMLInputElement>) => void;
  placeholder: string;
  value: string;
}) {
  return (
    <AriaTextField
      aria-label={ariaLabel}
      className={`comma-inline-field ${className}`}
      onChange={onChange}
      value={value}
    >
      <Input
        className="comma-inline-field-input"
        onBlur={onBlur}
        onKeyDown={onKeyDown}
        placeholder={placeholder}
      />
    </AriaTextField>
  );
}

function formatCreated(timestamp: number | undefined, locale: CommaLocale): string {
  if (!timestamp) return "—";
  return new Date(timestamp).toLocaleDateString(locale, {
    month: "short",
    day: "numeric",
  });
}

function DraftRow({
  busy,
  draft,
  onCancel,
  onChange,
  onCommit,
}: {
  busy: boolean;
  draft: TaskLabelDraft;
  onCancel: () => void;
  onChange: (next: TaskLabelDraft) => void;
  onCommit: () => void;
}) {
  const messages = useCommaMessages();
  const nameRef = useFocusOnMount();
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      event.preventDefault();
      onCommit();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onCancel();
    }
  };

  // The draft commits when focus leaves the whole row, not one field: moving
  // from name to description or into the colour menu (a popover outside the
  // row) is still editing the same draft.
  const onBlur = (event: FocusEvent<HTMLTableRowElement>) => {
    const next = event.relatedTarget;
    if (next instanceof Node && event.currentTarget.contains(next)) return;
    if (next instanceof Element && next.closest('[data-slot="menu-popover"]')) return;
    onCommit();
  };

  return (
    <tr
      className="comma-task-labels-row"
      data-testid="task-label-draft"
      onBlur={onBlur}
    >
      <td className="comma-task-labels-cell">
        <LabelColorPicker
          color={draft.color}
          disabled={busy}
          label={messages.settings_labels_color()}
          onChange={(color) => onChange({ ...draft, color })}
        />
      </td>
      <td className="comma-task-labels-cell">
        <span className="contents" ref={nameRef}>
          <InlineField
            ariaLabel={messages.settings_labels_name_placeholder()}
            onChange={(name) => onChange({ ...draft, name })}
            onKeyDown={onKeyDown}
            placeholder={messages.settings_labels_name_placeholder()}
            value={draft.name}
          />
        </span>
      </td>
      <td className="comma-task-labels-cell" colSpan={4}>
        <InlineField
          ariaLabel={messages.settings_labels_description_placeholder()}
          onChange={(description) => onChange({ ...draft, description })}
          onKeyDown={onKeyDown}
          placeholder={messages.settings_labels_description_placeholder()}
          value={draft.description ?? ""}
        />
      </td>
    </tr>
  );
}

function LabelRow({
  busy,
  count,
  label,
  locale,
  onDelete,
  onUpdate,
  onViewTasks,
}: {
  busy: boolean;
  count: number | undefined;
  label: CommaTaskLabel;
  locale: CommaLocale;
  onDelete: (labelId: string) => void;
  onUpdate: (labelId: string, draft: Partial<TaskLabelDraft>) => void;
  onViewTasks: (labelId: string) => void;
}) {
  const messages = useCommaMessages();
  const [renameRequest, setRenameRequest] = useState(0);
  const actionsLabel = messages.settings_labels_actions();

  return (
    <tr className="comma-task-labels-row" data-testid={`task-label-row-${label.id}`}>
      <td className="comma-task-labels-cell">
        <LabelColorPicker
          color={label.color}
          disabled={busy}
          label={messages.settings_labels_color()}
          onChange={(color) => onUpdate(label.id, { color })}
        />
      </td>
      <td className="comma-task-labels-cell">
        <InlineTextEditor
          disabled={busy}
          editRequest={renameRequest}
          label={messages.settings_labels_rename()}
          onCommit={(name) => name && onUpdate(label.id, { name })}
          placeholder={messages.settings_labels_name_placeholder()}
          value={label.name}
        />
      </td>
      <td className="comma-task-labels-cell">
        <InlineTextEditor
          disabled={busy}
          label={messages.settings_labels_column_description()}
          onCommit={(description) => onUpdate(label.id, { description })}
          placeholder={messages.settings_labels_description_placeholder()}
          value={label.description ?? ""}
        />
      </td>
      <td className="comma-task-labels-cell comma-task-labels-num">{count ?? "—"}</td>
      <td className="comma-task-labels-cell comma-task-labels-num">
        {formatCreated(label.created_at, locale)}
      </td>
      <td className="comma-task-labels-cell comma-task-labels-actions">
        <MenuTrigger>
          <Button
            aria-label={actionsLabel}
            hierarchy="tertiary-gray"
            iconLeading={<MoreHorizontalIcon />}
            iconOnly
            isDisabled={busy}
            size="sm"
          />
          <MenuPopover placement="bottom end">
            <Menu
              aria-label={actionsLabel}
              onAction={(key) => {
                if (key === "rename") setRenameRequest((request) => request + 1);
                else if (key === "view") onViewTasks(label.id);
                else if (key === "delete") onDelete(label.id);
              }}
            >
              <MenuItem icon={<EditBigIcon />} id="rename">
                {messages.settings_labels_rename()}
              </MenuItem>
              <MenuSeparator />
              <MenuItem icon={<FlashcardsIcon />} id="view">
                {messages.settings_labels_view_tasks()}
              </MenuItem>
              <MenuSeparator />
              <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
                {messages.settings_labels_delete()}
              </MenuItem>
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      </td>
    </tr>
  );
}

export function TaskLabelsPage({
  busy,
  catalog,
  counts,
  error,
  loading,
  locale,
  onCreate,
  onDelete,
  onResolveProposal,
  onRetry,
  onUpdate,
  onViewTasks,
  onViewProposalTask,
  pendingProposals,
  proposalTitle,
}: TaskLabelsPageProps) {
  const messages = useCommaMessages();
  const [filter, setFilter] = useState("");
  const [draft, setDraft] = useState<TaskLabelDraft>();

  const labels = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    const all = catalog?.labels ?? [];
    return needle
      ? all.filter((label) => label.name.toLowerCase().includes(needle))
      : all;
  }, [catalog, filter]);

  // A committed create shows up as a new catalog version; that is when the
  // draft row retires. A failed create keeps it, with the person's text.
  const lastCatalogVersion = useRef(catalog?.updated_at);
  useEffect(() => {
    if (catalog?.updated_at !== lastCatalogVersion.current) {
      lastCatalogVersion.current = catalog?.updated_at;
      setDraft(undefined);
    }
  }, [catalog?.updated_at]);

  const commitDraft = () => {
    if (!draft) return;
    const name = draft.name.trim();
    if (!name) {
      setDraft(undefined);
      return;
    }
    onCreate({ ...draft, name });
  };

  const startDraft = () =>
    setDraft({ name: "", color: DEFAULT_COLOR, description: "" });
  // A catalog with nothing in it shows no table at all — just the empty copy
  // and the way to create the first label; starting a draft brings the table
  // (and its header) in around that first row.
  const noLabels =
    !loading &&
    !error &&
    catalog !== undefined &&
    catalog.labels.length === 0 &&
    !draft;

  return (
    <div className="comma-task-labels-page" data-testid="task-labels-settings">
      <header className="flex flex-col gap-xs">
        <h1 className="comma-task-labels-title">{messages.settings_labels_title()}</h1>
        <p className="m-0 text-sm text-tertiary">
          {messages.settings_labels_description()}
        </p>
      </header>

      <div className="comma-task-labels-toolbar">
        <InputField
          className="comma-task-labels-toolbar-filter"
          fieldSize="sm"
          onChange={(event) => setFilter(event.target.value)}
          placeholder={messages.settings_labels_filter_placeholder()}
          value={filter}
        />
        <div className="ml-auto">
          <Button
            className="h-auto px-lg py-xs"
            hierarchy="primary"
            iconLeading={<PlusIcon />}
            isDisabled={busy !== undefined || draft !== undefined || !catalog}
            onPress={startDraft}
            size="sm"
          >
            {messages.settings_labels_new()}
          </Button>
        </div>
      </div>

      <LabelProposalList
        busy={busy}
        onResolve={onResolveProposal}
        onViewTask={onViewProposalTask}
        proposals={pendingProposals}
        proposalTitle={proposalTitle}
      />

      {noLabels ? (
        <div className="comma-task-labels-empty" data-testid="task-labels-none">
          <div className="comma-task-labels-state-stack">
            {messages.settings_labels_none()}
            <Button
              className="h-7 px-lg"
              hierarchy="secondary-gray"
              onPress={startDraft}
              size="sm"
            >
              {messages.settings_labels_new()}
            </Button>
          </div>
        </div>
      ) : (
        <table className="comma-task-labels-table">
          <thead>
            <tr className="comma-task-labels-head">
              <th
                className="comma-task-labels-cell comma-task-labels-swatch"
                scope="col"
              >
                <span className="app-sr-only">{messages.settings_labels_color()}</span>
              </th>
              <th className="comma-task-labels-cell" scope="col">
                {messages.settings_labels_column_name()}
              </th>
              <th className="comma-task-labels-cell" scope="col">
                {messages.settings_labels_column_description()}
              </th>
              <th className="comma-task-labels-cell comma-task-labels-num" scope="col">
                {messages.settings_labels_column_tasks()}
              </th>
              <th className="comma-task-labels-cell comma-task-labels-num" scope="col">
                {messages.settings_labels_column_created()}
              </th>
              <th
                className="comma-task-labels-cell comma-task-labels-actions"
                scope="col"
              >
                <span className="app-sr-only">
                  {messages.settings_labels_actions()}
                </span>
              </th>
            </tr>
          </thead>
          <tbody>
            {draft ? (
              <DraftRow
                busy={busy !== undefined}
                draft={draft}
                onCancel={() => setDraft(undefined)}
                onChange={setDraft}
                onCommit={commitDraft}
              />
            ) : null}

            {error ? (
              <tr>
                <td
                  className="comma-task-labels-cell comma-task-labels-state"
                  colSpan={6}
                >
                  <div
                    aria-live="polite"
                    className="comma-task-labels-state-stack"
                    data-testid="task-labels-error"
                  >
                    {error}
                    <Button
                      className="h-7 px-lg"
                      hierarchy="secondary-gray"
                      onPress={onRetry}
                      size="sm"
                    >
                      {messages.common_retry()}
                    </Button>
                  </div>
                </td>
              </tr>
            ) : null}

            {loading && !error ? (
              <tr>
                <td
                  className="comma-task-labels-cell comma-task-labels-state"
                  colSpan={6}
                >
                  <span data-testid="task-labels-loading">
                    <LoadingIndicator label={messages.settings_labels_loading()} />
                  </span>
                </td>
              </tr>
            ) : null}

            {!loading && catalog && labels.length === 0 && !draft ? (
              <tr>
                <td
                  className="comma-task-labels-cell comma-task-labels-state"
                  colSpan={6}
                >
                  {messages.settings_labels_empty()}
                </td>
              </tr>
            ) : null}

            {labels.map((label: CommaTaskLabel) => (
              <LabelRow
                busy={busy === label.id}
                count={counts ? (counts[label.id] ?? 0) : undefined}
                key={label.id}
                label={label}
                locale={locale}
                onDelete={onDelete}
                onUpdate={onUpdate}
                onViewTasks={onViewTasks}
              />
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
