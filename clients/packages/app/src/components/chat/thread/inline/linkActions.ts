import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../../../runtime-chat/nativePlatformActions";

/** Opens an http(s) URL in the OS browser (Electron) or a new tab (web). */
export async function openUrlInExternalBrowser(url: string): Promise<void> {
  await openNativePlatformExternalUrl(url);
}

export async function copyTextToClipboard(text: string): Promise<void> {
  await nativePlatformClipboard.writeText(text);
}

export function resolveHttpLinkFromEventTarget(
  target: EventTarget | null,
  root: Element
): string | null {
  const element =
    target instanceof Element
      ? target
      : target instanceof Node
        ? target.parentElement
        : null;
  const anchor = element?.closest<HTMLAnchorElement>("a[href]");
  if (!anchor || !root.contains(anchor)) return null;

  let url: URL;
  try {
    url = new URL(anchor.href);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  return url.toString();
}
