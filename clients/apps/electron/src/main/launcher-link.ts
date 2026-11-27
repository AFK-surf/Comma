/**
 * Links the Raycast extension opens: `<scheme>://home`, `<scheme>://home/compose?text=…&entry=raycast`,
 * `<scheme>://task/<workspace>/<group>/<conversation>` and `<scheme>://connect/raycast?challenge=…`.
 *
 * Any app or web page can open these, and Main cannot tell which one did. So a link never acts for the person: it
 * shows a window, puts words in Home's draft for the person to send, or asks the person to confirm a connection.
 */

/** The longest text a compose link may carry. The extension refuses longer text before it opens the link. */
export const LAUNCHER_COMPOSE_MAX_CHARS = 8_000;

const id = /^[A-Za-z0-9_-]{1,128}$/;
/** An unpadded base64url SHA-256 (the extension's pairing challenge). */
const challenge = /^[A-Za-z0-9_-]{43}$/;

export type LauncherLink =
  /** A main window route to open. */
  | { kind: "route"; route: string }
  /** The Raycast extension asks to be connected; the person confirms in Comma. */
  | { kind: "connectRaycast"; challenge: string };

/** What a launcher link of this app's scheme asks for, or undefined when `value` is not one. */
export function parseLauncherLink(
  value: string,
  expectedScheme: string
): LauncherLink | undefined {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return undefined;
  }
  if (url.protocol !== `${expectedScheme}:`) return undefined;
  if (url.username || url.password || url.port || url.hash) return undefined;
  const params = [...url.searchParams.keys()];
  const only = (...names: string[]) =>
    params.length === new Set(params).size &&
    params.every((name) => names.includes(name));
  const path = url.pathname.replace(/\/$/, "");

  if (url.hostname === "home" && path === "" && only()) {
    return { kind: "route", route: "/" };
  }
  if (url.hostname === "home" && path === "/compose" && only("text", "entry")) {
    const text = url.searchParams.get("text") ?? "";
    const entry = url.searchParams.get("entry");
    if (!text.trim() || [...text].length > LAUNCHER_COMPOSE_MAX_CHARS) return undefined;
    if (entry !== null && entry !== "raycast") return undefined;
    // The router reads a search value as JSON when it can: the quotes keep "42" or "true" a text.
    const draft = encodeURIComponent(JSON.stringify(text));
    return {
      kind: "route",
      route: `/?draft=${draft}${entry ? "&entry=raycast" : ""}`,
    };
  }
  if (url.hostname === "task" && only()) {
    const ids = path.split("/").slice(1);
    if (ids.length !== 3 || !ids.every((part) => id.test(part))) return undefined;
    return { kind: "route", route: `/inbox/${ids.join("/")}` };
  }
  if (url.hostname === "connect" && path === "/raycast" && only("challenge")) {
    const asked = url.searchParams.get("challenge") ?? "";
    return challenge.test(asked)
      ? { kind: "connectRaycast", challenge: asked }
      : undefined;
  }
  return undefined;
}
