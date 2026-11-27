/**
 * A Task deep link `<scheme>://task?workspace=<ws>&group=<group>&task=<task>`
 * opens that Task in Comma's main window. This is a navigation hint only: the
 * workspace and conversation belong to the signed-in account, and the server
 * authorizes access.
 */
const MAX_ID_LENGTH = 256;
const SAFE_ID = /^[A-Za-z0-9_.:-]+$/;

function validId(value: string | null): string | undefined {
  if (
    !value ||
    value.length > MAX_ID_LENGTH ||
    value === "." ||
    value === ".." ||
    !SAFE_ID.test(value)
  ) {
    return undefined;
  }
  return value;
}

/** The main window route for a Task deep link of this app's scheme, or undefined. */
export function taskLinkRoute(
  value: string,
  expectedScheme: string
): string | undefined {
  try {
    const url = new URL(value);
    if (url.protocol !== `${expectedScheme}:` || url.hostname !== "task")
      return undefined;
    if (url.username || url.password || url.port || url.hash) return undefined;
    if (url.pathname !== "" && url.pathname !== "/") return undefined;
    const workspace = validId(url.searchParams.get("workspace"));
    const group = validId(url.searchParams.get("group"));
    const task = validId(url.searchParams.get("task"));
    if (!workspace || !group || !task) return undefined;
    return `/tasks/${encodeURIComponent(workspace)}/${encodeURIComponent(group)}/${encodeURIComponent(task)}`;
  } catch {
    return undefined;
  }
}
