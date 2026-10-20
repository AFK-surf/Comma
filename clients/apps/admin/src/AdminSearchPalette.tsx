import { messages } from "@comma/i18n";
import {
  CommandPalette,
  type CommandPaletteGroup,
  type CommandPaletteItem,
} from "@comma/ui/components/command-palette";
import { useEffect } from "react";
import type { AdminLookupResult } from "./adminApi";
import type { AdminSection } from "./adminNavigation";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import type { SearchModel } from "./adminSearch";
import { displayText } from "./adminUi";

/** ⌘K: find an account by email or by any id it is known by, or go to a section. */
export function AdminSearchPalette({
  model,
  onOpenSection,
  onOpenUser,
  sections,
}: {
  model: SearchModel;
  onOpenSection: (section: AdminSection) => void;
  onOpenUser: (userId: string) => void;
  sections: ReadonlyArray<{ readonly label: string; readonly section: AdminSection }>;
}) {
  const run = useAdminCommand();
  const { open, query, results } = useAdminState(model.state);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        run(model.setOpen(true));
      }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [model, run]);

  const needle = query.trim().toLowerCase();
  const sectionItems: CommandPaletteItem[] = sections
    .filter((item) => !needle || item.label.toLowerCase().includes(needle))
    .map((item) => ({ title: item.label, value: `section:${item.section}` }));
  const accounts: CommandPaletteItem[] =
    results.status === "ready"
      ? results.results.map((result) => ({
          meta: lookupMatchLabel(result),
          subtitle: lookupSubtitle(result),
          title: displayText(result.user.email),
          value: `user:${result.user.id}`,
        }))
      : [];
  const groups: CommandPaletteGroup[] = [
    { heading: messages.admin_search_accounts(), id: "accounts", items: accounts },
    { heading: messages.admin_search_sections(), id: "sections", items: sectionItems },
  ];

  return (
    <CommandPalette
      closeLabel={messages.admin_close()}
      emptyDescription={
        results.status === "error"
          ? results.message
          : needle.length < 2
            ? messages.admin_search_hint()
            : undefined
      }
      emptyTitle={messages.admin_search_empty()}
      footerHints={[
        { keys: ["↑", "↓"], label: messages.admin_search_navigate() },
        { keys: ["↵"], label: messages.admin_search_open() },
      ]}
      groups={groups}
      label={messages.admin_search_label()}
      listLabel={messages.admin_search_results()}
      loading={results.status === "loading"}
      loadingLabel={messages.admin_loading()}
      onOpenChange={(next) => run(model.setOpen(next))}
      onQueryChange={(next) => run(model.setQuery(next))}
      onSelect={(item) => {
        run(model.setOpen(false));
        const [kind, id] = splitValue(item.value);
        if (kind === "user") onOpenUser(id);
        else onOpenSection(id as AdminSection);
      }}
      open={open}
      placeholder={messages.admin_search_placeholder()}
      query={query}
    />
  );
}

function splitValue(value: string): [string, string] {
  const index = value.indexOf(":");
  return [value.slice(0, index), value.slice(index + 1)];
}

export function lookupSubtitle(result: AdminLookupResult): string {
  const name = result.user.name?.trim();
  const workspace = result.workspace?.name?.trim();
  return [name, workspace, result.user.id].filter(Boolean).join(" · ");
}

export function lookupMatchLabel(result: AdminLookupResult): string {
  switch (result.match) {
    case "email":
      return messages.admin_search_match_email();
    case "user_id":
      return messages.admin_search_match_user();
    case "workspace_id":
      return messages.admin_search_match_workspace();
    case "tenant_id":
      return messages.admin_search_match_tenant();
    case "group_id":
      return messages.admin_search_match_group();
  }
}
