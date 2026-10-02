import { Button, XIcon } from "@comma/ui";
import { useReducer } from "react";
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

/** Leaves a notice for the page at `pathname`, as a redirect's flash would. */
export function showFlash(item: FlashMessage, pathname: string) {
  flash.items = [item];
  flash.shownAt = pathname;
}

function currentFlash(pathname: string) {
  if (flash.shownAt === null) flash.shownAt = pathname;
  else if (flash.shownAt !== pathname) flash.items = [];
  return flash.items;
}

export function FlashNotice({ pathname }: { pathname: string }) {
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  const items = flash.items.length > 0 ? currentFlash(pathname) : flash.items;
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
            onPress={() => {
              flash.items = flash.items.filter((other) => other !== item);
              rerender();
            }}
            size="xs"
          />
        </div>
      ))}
    </div>
  );
}
