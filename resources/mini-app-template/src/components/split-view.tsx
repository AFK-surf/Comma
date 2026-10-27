import { useState, type ReactNode } from "react";
import {
  ScreenPlaceContext,
  useNavigation,
  useSizeClass,
} from "@/components/navigation";

/**
 * A list and the detail of one of its items (DESIGN.md §3): on compact the
 * detail is pushed over the list, as on a phone; on regular and wide the two
 * stand side by side and the list shows which item is open, as Mail on an iPad
 * or a web inbox does.
 */
export function SplitView({
  list,
  detail,
  placeholder,
}: {
  /** The list screen. `open` shows an item; `selected` is the item in the detail column, if any. */
  list: (open: (id: string) => void, selected: string | null) => ReactNode;
  /** An item's screen. `close` leaves it (after the item is deleted, say). */
  detail: (id: string, close: () => void) => { title: string; screen: ReactNode };
  /** The detail column while no item is open. */
  placeholder: ReactNode;
}) {
  const sizeClass = useSizeClass();
  const navigation = useNavigation();
  const [selected, setSelected] = useState<string | null>(null);

  const compact = sizeClass === "compact";
  const shown =
    compact || selected === null ? null : detail(selected, () => setSelected(null));
  // The list keeps one place in the tree across size classes (on compact its
  // boxes take no part in layout), so a resize keeps what it holds: a draft,
  // its scroll position.
  return (
    <div className={compact ? "contents" : "flex h-full min-h-0"}>
      <div
        className={
          compact ? "contents" : "flex w-80 min-w-0 shrink-0 flex-col border-r lg:w-96"
        }
      >
        {compact
          ? list((id) => {
              const pushed = detail(id, navigation.pop);
              navigation.push(pushed.title, pushed.screen);
            }, null)
          : list(setSelected, selected)}
      </div>
      {compact ? null : (
        <div className="flex min-w-0 flex-1 flex-col">
          {shown ? (
            <ScreenPlaceContext.Provider
              key={selected}
              value={{ depth: 1, backTitle: undefined, inSplit: true }}
            >
              {shown.screen}
            </ScreenPlaceContext.Provider>
          ) : (
            <div className="flex min-h-0 flex-1 items-center justify-center p-6">
              {placeholder}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
