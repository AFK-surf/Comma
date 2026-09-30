const sidebarNavItemIds = ["home", "inbox", "tasks", "drive", "plugins"] as const;

export type SidebarNavItemId = (typeof sidebarNavItemIds)[number];

const knownIds: ReadonlySet<string> = new Set(sidebarNavItemIds);

function isSidebarNavItemId(id: string): id is SidebarNavItemId {
  return knownIds.has(id);
}

/**
 * The rail order to show for a stored preference. Ids the build no longer
 * ships are dropped, duplicates collapse to their first position, and items
 * the preference predates take their place in the default order after the
 * ones the reader arranged. An empty preference is the default order.
 */
export function reconcileSidebarNavOrder(
  storedOrder: readonly string[]
): SidebarNavItemId[] {
  const retained: SidebarNavItemId[] = [];
  for (const id of storedOrder) {
    if (isSidebarNavItemId(id) && !retained.includes(id)) retained.push(id);
  }
  return [...retained, ...sidebarNavItemIds.filter((id) => !retained.includes(id))];
}
