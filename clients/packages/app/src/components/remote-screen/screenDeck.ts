import { uiClock } from "@comma/ui/clock";
import { keepClearElementMoved } from "@comma/ui/components/keep-clear/keepClear";
import {
  createSpring,
  placeSpring,
  retargetSpring,
  springAtRest,
  springStateAt,
  type Spring,
  type SpringConfig,
} from "@comma/ui/motion";
import { isReducedMotionEnabled } from "@comma/ui/tokens";
import { useEffect, useId, useSyncExternalStore } from "react";

/**
 * The small screen cards on the page, as one deck in one corner. The front
 * card plays; the ones behind it show an edge each and hold no stream. A card
 * comes to the front when it joins or when the person picks its edge.
 *
 * The deck moves as things do. Held, the front card stays under the pointer
 * and the cards behind follow on springs, each a little slower than the one
 * before it. Let go, the deck carries on at the pointer's speed to where the
 * throw was going, kept inside its area, with a little bounce only when it was
 * thrown. Past the edge of its area the held card follows less and less. It
 * can be taken again at any moment, from wherever it is.
 */

/** Where the deck rests: the offset from each card's resting corner. */
type Offset = { x: number; y: number };

let order: readonly string[] = [];
let rest: Offset = { x: 0, y: 0 };
// Counts up with each change to the deck, for its readers.
let revision = 0;
const listeners = new Set<() => void>();
const changed = () => {
  revision += 1;
  for (const listener of listeners) listener();
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/** A card on the page: its element, its resting corner, and its springs. */
type Card = { element: HTMLElement; corner: Offset; x: Spring; y: Spring };
const cards = new Map<string, Card>();
// Who shows each card: two Agents on one computer and app share one card, the first one's.
const owners = new Map<string, string[]>();

// A spring as Apple names it: how fast it gets there (seconds) and how much it
// passes its place (1 never does).
const spring = (response: number, damping: number): SpringConfig => ({
  stiffness: ((2 * Math.PI) / response) ** 2,
  damping: (4 * Math.PI * damping) / response,
});
// Following a held card: no overshoot, each card behind slower than the last.
const FOLLOW_RESPONSE = [0.16, 0.24, 0.32, 0.4];
// Coming to rest after a move, and after a throw.
const SETTLE = spring(0.4, 1);
const THROWN = spring(0.4, 0.9);
// Faster than this at release (px/s), it was thrown.
const THROW_SPEED = 400;
// How far a release carries: scroll deceleration, on the snappy side.
const DECELERATION = 0.99;
const RUBBER = 0.55;

const depthOf = (key: string) => Math.max(0, order.indexOf(key));

function configure(card: Card, config: SpringConfig, time: number) {
  for (const axis of ["x", "y"] as const) {
    const state = springStateAt(card[axis], time);
    card[axis] = { config, target: card[axis].target, start: state, startTime: time };
  }
}

let cancelFrame: (() => void) | undefined;

function draw(time: number) {
  cancelFrame = undefined;
  let moving = false;
  for (const card of cards.values()) {
    const x = springStateAt(card.x, time);
    const y = springStateAt(card.y, time);
    card.element.style.translate = `${card.corner.x + x.position}px ${card.corner.y + y.position}px`;
    if (
      !springAtRest(x, card.x.target, 0.25, 4) ||
      !springAtRest(y, card.y.target, 0.25, 4)
    )
      moving = true;
  }
  if (moving) cancelFrame = uiClock.frame(draw);
  else keepClearElementMoved();
}

function run() {
  cancelFrame ??= uiClock.frame(draw);
}

/** Sends every card but the held one toward `target`, each on its own spring. */
function follow(target: Offset, time: number, held: string | undefined) {
  for (const [key, card] of cards) {
    if (key === held) continue;
    if (isReducedMotionEnabled()) {
      placeSpring(card.x, time, target.x);
      placeSpring(card.y, time, target.y);
      continue;
    }
    const response =
      FOLLOW_RESPONSE[Math.min(depthOf(key), FOLLOW_RESPONSE.length - 1)]!;
    configure(card, spring(response, 1), time);
    retargetSpring(card.x, time, target.x);
    retargetSpring(card.y, time, target.y);
  }
}

/** Past an edge the card follows less the further it goes. */
function rubberBand(value: number, min: number, max: number, dimension: number) {
  const band = (over: number) =>
    (over * dimension * RUBBER) / (dimension + RUBBER * Math.abs(over));
  if (value < min) return min + band(value - min);
  if (value > max) return max + band(value - max);
  return value;
}

/** The offsets that keep a card inside its area, and the area's size. */
export type DragRoom = {
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
  width: number;
  height: number;
};

/**
 * Takes the deck by `key`'s card at pointer point `at`. The card is taken
 * where it is, also in mid flight. Returns the drag: `move` with each pointer
 * point, `end` at release.
 */
export function holdScreenDeck(key: string, at: Offset, room: DragRoom) {
  const card = cards.get(key);
  if (!card) return undefined;
  const start = uiClock.monotonic();
  const grab = {
    x: at.x - springStateAt(card.x, start).position,
    y: at.y - springStateAt(card.y, start).position,
  };
  // The last pointer points, for the speed at release.
  let trail: { time: number; x: number; y: number }[] = [{ time: start, ...at }];
  const place = (point: Offset, time: number) => {
    const held = {
      x: rubberBand(point.x - grab.x, room.minX, room.maxX, room.width),
      y: rubberBand(point.y - grab.y, room.minY, room.maxY, room.height),
    };
    placeSpring(card.x, time, held.x);
    placeSpring(card.y, time, held.y);
    follow(held, time, key);
    run();
    return held;
  };
  let held = place(at, start);
  return {
    move(point: Offset) {
      const time = uiClock.monotonic();
      trail = [
        ...trail.filter((sample) => time - sample.time < 100),
        { time, ...point },
      ];
      held = place(point, time);
    },
    end() {
      const time = uiClock.monotonic();
      const first = trail[0]!;
      const last = trail.at(-1)!;
      const seconds = Math.max(0.001, (last.time - first.time) / 1000);
      // A pointer that stopped before it let go throws nothing.
      const still = time - last.time > 80;
      const velocity = still
        ? { x: 0, y: 0 }
        : { x: (last.x - first.x) / seconds, y: (last.y - first.y) / seconds };
      const carry = (speed: number) =>
        ((speed / 1000) * DECELERATION) / (1 - DECELERATION);
      rest = {
        x: Math.min(room.maxX, Math.max(room.minX, held.x + carry(velocity.x))),
        y: Math.min(room.maxY, Math.max(room.minY, held.y + carry(velocity.y))),
      };
      if (isReducedMotionEnabled()) {
        for (const other of cards.values()) {
          placeSpring(other.x, time, rest.x);
          placeSpring(other.y, time, rest.y);
        }
      } else {
        const thrown = Math.hypot(velocity.x, velocity.y) > THROW_SPEED;
        for (const [otherKey, other] of cards) {
          configure(other, thrown ? THROWN : SETTLE, time);
          // The held card leaves the hand at the hand's speed; the others keep their own.
          retargetSpring(
            other.x,
            time,
            rest.x,
            otherKey === key ? velocity.x : undefined
          );
          retargetSpring(
            other.y,
            time,
            rest.y,
            otherKey === key ? velocity.y : undefined
          );
        }
      }
      run();
    },
  };
}

/** Brings a card to the front. */
export function frontScreenCard(key: string) {
  if (order[0] === key || !order.includes(key)) return;
  order = [key, ...order.filter((other) => other !== key)];
  changed();
}

/**
 * Puts a card's element under the deck's motion: the deck writes its place.
 * `corner` is where the card rests with the deck at rest. Returns the release.
 */
export function placeScreenCard(key: string, element: HTMLElement, corner: Offset) {
  const time = uiClock.monotonic();
  const known = cards.get(key);
  // A card that joins, or whose element changed, starts where the deck is going.
  const x = known?.x ?? createSpring(SETTLE, rest.x, time);
  const y = known?.y ?? createSpring(SETTLE, rest.y, time);
  const card = { element, corner, x, y };
  cards.set(key, card);
  const at = { x: springStateAt(x, time).position, y: springStateAt(y, time).position };
  element.style.translate = `${corner.x + at.x}px ${corner.y + at.y}px`;
  return () => {
    if (cards.get(key) === card) cards.delete(key);
  };
}

/**
 * Keeps a card in the deck while it is shown. A card joins once it is `ready`
 * (its first picture plays): until then the deck does not count it. Answers
 * how far behind the front it is (0 is the front), how many cards the deck
 * holds, and whether another instance already shows this card.
 */
export function useScreenDeck(key: string, ready: boolean) {
  const instance = useId();
  useEffect(() => {
    owners.set(key, [...(owners.get(key) ?? []), instance]);
    changed();
    return () => {
      const left = (owners.get(key) ?? []).filter((other) => other !== instance);
      if (left.length) owners.set(key, left);
      else owners.delete(key);
      changed();
    };
  }, [instance, key]);
  useEffect(() => {
    if (!ready) return undefined;
    // The newest card is the one the person has not seen: it joins at the front.
    order = [key, ...order.filter((other) => other !== key)];
    changed();
    return () => {
      // Another instance of the same card keeps its place in the deck.
      if ((owners.get(key) ?? []).some((other) => other !== instance)) return;
      order = order.filter((other) => other !== key);
      changed();
    };
  }, [instance, key, ready]);
  const version = useSyncExternalStore(subscribe, () => revision);
  void version;
  const depth = order.indexOf(key);
  const owner = owners.get(key)?.[0];
  return {
    depth: depth < 0 ? 0 : depth,
    count: Math.max(1, order.length),
    duplicate: owner !== undefined && owner !== instance,
  };
}

/**
 * A spring's travel from 0 to 1 as animation keyframes: one value per frame
 * until it rests. The motion has no set length; it takes what the spring takes.
 */
export function springFrames(response: number, damping: number) {
  const config = spring(response, damping);
  const values: number[] = [];
  const step = 1000 / 60;
  const flight = createSpring(config, 0, 0);
  flight.target = 1;
  for (let time = 0; time <= 2000; time += step) {
    const state = springStateAt(flight, time);
    values.push(state.position);
    if (springAtRest(state, 1, 0.002, 0.02)) break;
  }
  values.push(1);
  return { values, duration: (values.length - 1) * step };
}
