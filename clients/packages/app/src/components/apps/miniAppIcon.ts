import { useTopic, type MiniAppVia } from "@comma/core-client";

/**
 * An app's image URL as an image the page can show: the server answers it only to the viewer's session with the access
 * path (`x-comma-app-via`), which an `<img>` cannot send, so the core reads it (`miniAppImage`). Undefined until it is
 * known (or while `wanted` is false: a gallery card reads its `cover_url` only near the view), null when there is none or
 * it could not be read. An image read before in the account's session is known at once.
 */
export function useMiniAppImage(
  url: string | null | undefined,
  via: MiniAppVia,
  wanted: boolean
): string | null | undefined {
  const { value, error } = useTopic(
    url && wanted
      ? {
          topic: "miniAppImage",
          url,
          ...("workspace" in via ? { workspace: via.workspace } : { link: via.token }),
        }
      : null
  );
  if (!url || error) return null;
  return value?.status === "ready" ? value.src : undefined;
}

/** An app's `icon_url` as an image; null while it loads, and when the app has no icon or it could not be read. */
export function useMiniAppIcon(url: string | null | undefined, via: MiniAppVia) {
  return useMiniAppImage(url, via, true) ?? null;
}
