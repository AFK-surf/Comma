import { useCall, useTopic, type PluginToolGroup } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { PluginDetailSection, PluginResourceRow } from "@comma/ui/components/plugins";
import { toast } from "@comma/ui/components/toast";
import { Toggle } from "@comma/ui/components/toggle";
import type { ReactNode } from "react";

/**
 * An installed plugin's tool groups, one switch each (the core's
 * `pluginToolGroups`), for a plugin whose MCP has them (`Plugin.toolGroups`),
 * under a heading for each category. One change at a time: every switch waits
 * while one is under way.
 */
export function PluginToolGroups({
  icon,
  plugin,
  workspace,
}: {
  /** The plugin's own logo, shown on each group. */
  icon: ReactNode;
  plugin: string;
  workspace: string;
}) {
  const call = useCall();
  const messages = useCommaMessages();
  const { value } = useTopic({ topic: "pluginToolGroups", workspace, plugin });
  const groups = value?.groups;
  const busy = Boolean(value?.pending);

  if (!groups?.length) {
    return value?.error === "load_failed" ? (
      <PluginDetailSection title={messages.plugins_tool_groups()}>
        <output className="mx-md block rounded-lg bg-secondary px-md py-sm text-sm text-secondary">
          {messages.plugins_tool_groups_load_failed()}
        </output>
      </PluginDetailSection>
    ) : null;
  }

  const toggle = (id: string, name: string, enabled: boolean) =>
    void call("plugin.toolGroup.set", { workspace, plugin, group: id, enabled }).catch(
      () => toast.error(messages.plugins_tool_group_save_failed({ name }))
    );

  const row = (group: PluginToolGroup) => (
    <PluginResourceRow
      key={group.id}
      resource={{
        icon,
        id: group.id,
        name: group.name,
        trailingContent: (
          <Toggle
            aria-label={messages.plugins_tool_group_toggle_named({ name: group.name })}
            checked={group.enabled}
            disabled={busy}
            onChange={() => toggle(group.id, group.name, !group.enabled)}
            size="sm"
          />
        ),
      }}
    />
  );

  return (
    <PluginDetailSection title={messages.plugins_tool_groups()}>
      <div className="flex flex-col gap-lg">
        {categories(groups).map(({ category, groups: listed }) => (
          <section
            aria-label={category}
            className="flex flex-col gap-xs"
            key={category ?? listed[0]!.id}
          >
            {category ? (
              <h3 className="m-0 pl-md text-xs font-medium text-tertiary">
                {category}
              </h3>
            ) : null}
            <ul className="m-0 flex list-none flex-col gap-xs p-0">
              {listed.map(row)}
            </ul>
          </section>
        ))}
      </div>
    </PluginDetailSection>
  );
}

/** The groups in their order, each run of one category together. */
function categories(groups: readonly PluginToolGroup[]) {
  const runs: { category: string | undefined; groups: PluginToolGroup[] }[] = [];
  for (const group of groups) {
    const last = runs.at(-1);
    if (last && last.category === group.category) last.groups.push(group);
    else runs.push({ category: group.category, groups: [group] });
  }
  return runs;
}
