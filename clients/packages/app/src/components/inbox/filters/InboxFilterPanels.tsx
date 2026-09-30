import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { FilterOptionsPanel, Menu, MenuItem } from "@comma/ui";
import { useState } from "react";

export interface InboxWorkspaceSelector {
  activeWorkspaceId: string;
  onChange: (workspaceId: string) => void;
  workspaces: { id: string; name: string }[];
}

/** The "{n} notifications" count beside every Inbox filter option. */
export function InboxNotificationCount({ count }: { count: number }) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  return (
    <span className="tabular-nums">
      {messages.inbox_filter_notification_count({
        count,
        formattedCount: formatNumber(count, locale),
      })}
    </span>
  );
}

// The panel chrome is the one the Tasks status filter uses so both menus read
// as the same control.
export function InboxWorkspaceFilterPanel({
  workspaceSelector,
}: {
  workspaceSelector: InboxWorkspaceSelector;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const workspaces = workspaceSelector.workspaces.filter((workspace) =>
    workspace.name.toLocaleLowerCase(locale).includes(normalizedQuery)
  );

  return (
    <div data-testid="inbox-workspace-select">
      <FilterOptionsPanel
        empty={workspaces.length === 0}
        label={messages.inbox_workspace()}
        onQueryChange={setQuery}
        query={query}
      >
        <Menu
          aria-label={messages.inbox_workspace()}
          className="flex min-w-0 flex-col gap-xxs px-sm py-sm"
          onSelectionChange={(keys) => {
            const next = keys === "all" ? undefined : Array.from(keys, String)[0];
            if (next) workspaceSelector.onChange(next);
          }}
          selectedKeys={
            workspaceSelector.activeWorkspaceId
              ? new Set([workspaceSelector.activeWorkspaceId])
              : new Set<string>()
          }
          selectionMode="single"
          variant="embedded"
        >
          {workspaces.map((workspace) => (
            <MenuItem
              activeClassName="bg-secondary-hover"
              contentClassName="h-8"
              gutter="none"
              id={workspace.id}
              key={workspace.id}
              selectionIndicator="checkbox"
              textValue={workspace.name}
            >
              <span className="text-primary">{workspace.name}</span>
            </MenuItem>
          ))}
        </Menu>
      </FilterOptionsPanel>
    </div>
  );
}
