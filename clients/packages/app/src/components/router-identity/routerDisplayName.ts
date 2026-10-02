// Workspace provisioning names the Router "<workspace name> Router", and every
// workspace starts as "Default workspace". That generated prefix is noise in a
// label, so it is dropped; a name the user chose is shown as written.
const defaultWorkspacePrefix = /^Default workspace\s+/i;
// What provisioning names every Router once that prefix is dropped: a role,
// not a name anyone chose. An assistant without a name of its own takes the
// fallback instead.
const provisionedRouterName = "router";

/** The brand, not the build flavor's product name ("Comma Dev"). */
export const assistantBrandName = "Comma";

export function routerDisplayName(name: string | undefined, fallback: string) {
  const displayName = name?.replace(defaultWorkspacePrefix, "").trim();
  return displayName && displayName.toLowerCase() !== provisionedRouterName
    ? displayName
    : fallback;
}
