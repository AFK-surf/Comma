import { parseMiniAppRunLink } from "@comma/config";
import { messages } from "@comma/i18n";
import { toast } from "@comma/ui/components/toast";

export function openMiniAppRunLink(value: string): boolean {
  const link = parseMiniAppRunLink(value, [window.location.origin]);
  if (!link) return false;
  if (link.kind === "invalid") {
    window.location.hash = "/apps";
    toast.error(messages.mini_app_unavailable_title());
  } else window.location.hash = link.route;
  return true;
}

export function installMiniAppRunLinkClicks(document: Document): () => void {
  const click = (event: MouseEvent) => {
    const element = event.target instanceof Element ? event.target : null;
    const anchor = element?.closest<HTMLAnchorElement>("a[href]");
    if (!anchor || !openMiniAppRunLink(anchor.href)) return;
    event.preventDefault();
    event.stopPropagation();
  };
  document.addEventListener("click", click, true);
  document.addEventListener("auxclick", click, true);
  return () => {
    document.removeEventListener("click", click, true);
    document.removeEventListener("auxclick", click, true);
  };
}
