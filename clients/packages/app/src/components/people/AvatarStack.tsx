import type { TaskRequestContact } from "@comma/core-client";
import { cx } from "@comma/ui/components/utils";
import { useEffect, useLayoutEffect, useState, type CSSProperties } from "react";
import { UserAvatar } from "../UserAvatar";
import { useAvatarUrl } from "../useProfileAvatarUrl";

/** A face in a stack: who, by name or email, and their avatar if any. */
export type Face = {
  id: string;
  name: string | null;
  email: string | null;
  avatar: TaskRequestContact["avatar"];
};

const nameOf = (person: Face) => person.name || person.email || "";

/** The surface a stack sits on: its faces are cut out of each other by a ring of it. */
type Surface = "card" | "panel" | "popup";

/** `2xs` (16px) sits in a line of chips; `xs` (24px) and `sm` (32px) stand alone. */
type StackSize = "2xs" | "xs" | "sm";

const rings: Record<Surface, string> = {
  card: "ring-todo-kanban-bg-card-primary",
  panel: "ring-main-panel-bg",
  popup: "ring-bg-popup-primary",
};

/** A face on show, or still on its way in or out. */
type Shown = { face: Face; phase: "shown" | "entering" | "leaving" };

/**
 * The faces to draw for `people`: those there when it first shows are just there; one added grows in, one taken out
 * shrinks away and is let go once it has. Taken out and put back meanwhile, it grows back from where it is.
 */
function usePresence(people: readonly Face[], animate: boolean) {
  const [items, setItems] = useState<Shown[]>(() =>
    people.map((face) => ({ face, phase: "shown" }))
  );
  useLayoutEffect(() => {
    setItems((before) => {
      const had = new Map(before.map((item) => [item.face.id, item]));
      const next: Shown[] = people.map((face) => {
        const old = had.get(face.id);
        const phase = !animate
          ? "shown"
          : !old || old.phase === "leaving"
            ? "entering"
            : old.phase;
        return { face, phase };
      });
      const now = new Set(people.map((face) => face.id));
      // One taken out keeps its place while it goes.
      if (animate)
        before.forEach((item, index) => {
          if (!now.has(item.face.id))
            next.splice(Math.min(index, next.length), 0, {
              face: item.face,
              phase: "leaving",
            });
        });
      // Nothing changed: the same list, so nothing draws again.
      const same =
        next.length === before.length &&
        next.every(
          (item, i) => item.face === before[i]?.face && item.phase === before[i]?.phase
        );
      return same ? before : next;
    });
  }, [people, animate]);
  const settle = (id: string) =>
    setItems((before) =>
      before.flatMap((item) =>
        item.face.id !== id
          ? [item]
          : item.phase === "leaving"
            ? []
            : [{ face: item.face, phase: "shown" as const }]
      )
    );
  // With motion off no animation ends: one going is let go at once.
  // With motion off nothing shrinks and no transition ends: one taken out goes at once. (One whose transition is
  // dropped, hidden meanwhile, goes on `transitioncancel`.) No timer: it would run on while the page's own
  // animation time does not.
  const leaving = items.some((item) => item.phase === "leaving");
  useEffect(() => {
    if (!leaving) return;
    const reduced =
      document.documentElement.dataset.commaReducedMotion === "true" ||
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduced)
      setItems((before) => before.filter((item) => item.phase !== "leaving"));
  }, [leaving]);
  return { items, settle };
}

const faceSizes: Record<StackSize, string> = {
  "2xs": "var(--spacing-xl)",
  xs: "var(--spacing-3xl)",
  sm: "var(--spacing-4xl)",
};

/**
 * Faces side by side, each overlapping the one before by xxs: each has a hairline edge, so light faces stay apart,
 * and a ring of the surface behind cuts it out of the one it covers. With `animate`, a face added grows in and one
 * taken out shrinks away, while the others slide to make room.
 */
export function AvatarStack({
  animate = false,
  max = 6,
  people,
  size = "xs",
  surface = "panel",
}: {
  /** Faces added or taken out after it first shows grow in or shrink away. */
  animate?: boolean;
  /** Past this many, the last face is a count of the rest. */
  max?: number;
  people: readonly Face[];
  size?: StackSize;
  surface?: Surface;
}) {
  const shownPeople = people.length > max ? people.slice(0, max - 1) : people;
  const rest = people.length - shownPeople.length;
  const { items, settle } = usePresence(shownPeople, animate);
  // Every face overlaps the one before it, the first one the stack's own inset: none changes its overlap when a
  // face beside it comes or goes, so nothing jumps.
  return (
    <span className="flex items-center ps-xxs">
      {items.map(({ face, phase }) => {
        return (
          <span
            className="comma-face-presence"
            data-phase={phase === "shown" ? undefined : phase}
            key={face.id}
            onTransitionCancel={(event) => {
              // Dropped because it is no longer drawn (not turned around by a face put back or taken out).
              if (
                event.target === event.currentTarget &&
                event.currentTarget.getClientRects().length === 0
              )
                settle(face.id);
            }}
            onTransitionEnd={(event) => {
              if (
                event.target === event.currentTarget &&
                event.propertyName === "--face-presence"
              )
                settle(face.id);
            }}
            style={
              {
                "--face-size": faceSizes[size],
                "--face-overlap": "calc(var(--spacing-xxs) * -1)",
              } as CSSProperties
            }
          >
            <StackedAvatar person={face} size={size} surface={surface} />
          </span>
        );
      })}
      {rest > 0 ? (
        <span
          className={cx(
            "relative -ms-xxs flex items-center justify-center rounded-full bg-secondary font-medium tabular-nums text-secondary",
            size === "sm"
              ? "size-8 text-xs ring-2"
              : size === "xs"
                ? "size-6 text-[11px] ring-2"
                : "size-4 text-[8px] ring-1",
            rings[surface]
          )}
        >
          +{rest}
        </span>
      ) : null}
    </span>
  );
}

function StackedAvatar({
  person,
  size,
  surface,
}: {
  person: Face;
  size: StackSize;
  surface: Surface;
}) {
  const url = useAvatarUrl(person.avatar ?? undefined);
  return (
    <span
      className={cx(
        "relative flex rounded-full after:pointer-events-none after:absolute after:inset-0 after:rounded-full after:border-[0.5px] after:border-primary",
        size === "2xs" ? "ring-1" : "ring-2",
        rings[surface],
        // Initials a step smaller than a lone face's, so neighbours never touch.
        size === "xs" && "[&_span]:text-[10px]",
        size === "2xs" && "[&>*>img]:size-4! [&>*>span]:size-4! [&>*>span]:text-[8px]!"
      )}
    >
      <UserAvatar
        {...(url ? { avatarUrl: url } : {})}
        displayName={nameOf(person)}
        email={person.email ?? ""}
        size={size === "2xs" ? "xs" : size}
      />
    </span>
  );
}
