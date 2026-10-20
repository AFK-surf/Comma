import { Button } from "@comma/ui/components/Button";
import { XIcon } from "@comma/ui/components/icons";
import { useSyncExternalStore } from "react";
import { messages } from "./messages";

export interface FlashMessage {
  kind: "info" | "error";
  text: string;
}

/**
 * The flash a LiveView redirect left for this page. Phoenix writes it
 * (translated and escaped) into `<meta name="bft-flash">` of the served page.
 */
export function readFlash(doc: Document): FlashMessage[] {
  return [...doc.querySelectorAll('meta[name="bft-flash"]')].flatMap((meta) => {
    const text = meta.getAttribute("content")?.trim();
    const kind = meta.getAttribute("data-kind") === "error" ? "error" : "info";
    return text ? [{ kind, text }] : [];
  });
}

// Read once on boot. The notice stays on the page it first appears on (after
// any redirect such as /orgs to an organization) and goes away when dismissed
// or when the user moves to another page.
const flash = {
  items: typeof document === "undefined" ? [] : readFlash(document),
  shownAt: null as string | null,
};

const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
const setItems = (items: FlashMessage[]) => {
  flash.items = items;
  for (const listener of listeners) listener();
};

/**
 * Leaves a notice for the page at `pathname`, as a redirect's flash would; a
 * notice already on screen shows it at once.
 */
export function showFlash(item: FlashMessage, pathname: string) {
  flash.shownAt = pathname;
  setItems([item]);
}

function currentFlash(pathname: string) {
  if (flash.shownAt === null) flash.shownAt = pathname;
  else if (flash.shownAt !== pathname) flash.items = [];
  return flash.items;
}

export function FlashNotice({ pathname }: { pathname: string }) {
  const all = useSyncExternalStore(subscribe, () => flash.items);
  const items = all.length > 0 ? currentFlash(pathname) : all;
  if (items.length === 0) return null;

  return (
    <div className="bft-flash">
      {items.map((item) => (
        <div
          className="bft-notice bft-flash-notice"
          data-kind={item.kind}
          key={`${item.kind}:${item.text}`}
          role={item.kind === "error" ? "alert" : "status"}
        >
          <p>{item.text}</p>
          <Button
            aria-label={messages.common.dismiss}
            hierarchy="tertiary-gray"
            iconLeading={<XIcon />}
            iconOnly
            onPress={() => setItems(flash.items.filter((other) => other !== item))}
            size="xs"
          />
        </div>
      ))}
    </div>
  );
}
