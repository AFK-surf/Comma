import { useCommaLocale } from "@comma/i18n/react";
import {
  getNativeBridge,
  type ApplicationMenuCommand,
  type ApplicationMenuItems,
} from "@comma/native-bridge";
import { useEffect, useRef } from "react";
import { toast } from "@comma/ui";

type MenuAction = ApplicationMenuItems[number] & { run: () => unknown };
const owners = new Map<symbol, readonly MenuAction[]>();
let locale: "en" | "zh-CN" = "en";
let unsubscribe: (() => void) | undefined;
let publishQueued = false;
function publish() {
  if (publishQueued) return;
  publishQueued = true;
  queueMicrotask(() => {
    publishQueued = false;
    publishCurrentOwners();
  });
}

function publishCurrentOwners() {
  const bridge = getNativeBridge();
  if (bridge.platform !== "electron") return;
  const actions = new Map<ApplicationMenuCommand, MenuAction>();
  for (const group of owners.values())
    for (const action of group) {
      if (action.enabled || !actions.get(action.id)?.enabled)
        actions.set(action.id, action);
    }
  void bridge.applicationMenu
    .update({
      locale,
      items: [...actions.values()].map(({ run: _run, ...item }) => item),
    })
    .catch(console.error);
}

/** Mounted surfaces own commands; unmount withdraws them from the native menu. */
export function useApplicationMenu(actions: readonly MenuAction[]) {
  const currentLocale = useCommaLocale();
  const owner = useRef(Symbol("application-menu"));
  const current = useRef(actions);
  current.current = actions;
  const presentation = JSON.stringify(actions.map(({ run: _run, ...item }) => item));
  useEffect(() => {
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron" || current.current.length === 0) return;
    locale = currentLocale;
    const key = owner.current;
    if (!unsubscribe)
      unsubscribe = bridge.applicationMenu.onCommand((id) => {
        const action = [...owners.values()]
          .flat()
          .findLast((item) => item.id === id && item.enabled);
        if (action?.enabled)
          void Promise.resolve()
            .then(action.run)
            .catch((error: unknown) => {
              toast.error(
                error instanceof Error ? error.message : "Menu action failed"
              );
            });
      });
    owners.set(
      key,
      current.current.map((item) => ({
        ...item,
        run: () => current.current.find((candidate) => candidate.id === item.id)?.run(),
      }))
    );
    publish();
    return () => {
      owners.delete(key);
      publish();
      if (!owners.size) {
        unsubscribe?.();
        unsubscribe = undefined;
      }
    };
  }, [presentation, currentLocale]);
}
