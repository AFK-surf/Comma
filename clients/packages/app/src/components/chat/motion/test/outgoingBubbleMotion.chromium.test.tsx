import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock, type VirtualUiClock } from "@comma/ui/clock/virtual";
import { afterEach, beforeEach, expect, it } from "vitest";
import {
  animateOutgoingBubble,
  holdTranscript,
  transcriptHeld,
} from "../outgoingBubbleMotion";

let clock: VirtualUiClock;
let restoreClock: () => void;

beforeEach(() => {
  clock = createVirtualUiClock();
  restoreClock = installUiClock(clock);
});

afterEach(() => {
  restoreClock();
  document.body.replaceChildren();
});

/** A transcript column in its scroll viewport. */
function transcript() {
  const viewport = document.createElement("div");
  viewport.dataset.slot = "scroll-area-viewport";
  const column = document.createElement("div");
  column.className = "comma-chat-column";
  viewport.append(column);
  document.body.append(viewport);
  return { column, viewport };
}

/** A sent row in a transcript column: its slot, bubble and text. */
function sentRow(column: HTMLElement) {
  // The slot hugs the bubble at the row's end, as MessageRow lays it out.
  const line = document.createElement("div");
  line.className = "comma-chat-user-bubble-row";
  const slot = document.createElement("div");
  slot.className = "comma-chat-user-bubble-slot";
  const bubble = document.createElement("div");
  bubble.className = "comma-chat-user-bubble";
  const content = document.createElement("div");
  content.className = "comma-chat-user-bubble-content";
  content.textContent = "A message sent from the composer.";
  bubble.append(content);
  slot.append(bubble);
  line.append(slot);
  column.append(line);
  return { bubble, content, slot };
}

function launch(row: ReturnType<typeof sentRow>, transcriptShift: number) {
  return animateOutgoingBubble({
    ...row,
    source: { left: 40, top: 500, right: 440, bottom: 540, width: 400, height: 40 },
    reducedMotion: false,
    transcriptShift,
    onComplete: () => {},
  });
}

it("leaves a landed flight alone when a later send's glide that carried it starts or is cleaned up", () => {
  const { column } = transcript();
  const first = sentRow(column);
  const second = sentRow(column);

  const firstFlight = launch(first, 0);
  // The second send's glide carries the first flight, which then lands before
  // the second has started.
  const secondFlight = launch(second, 120);
  firstFlight.cleanup();

  clock.advanceFrames(3);
  expect(first.bubble.getAnimations(), "starting the second flight").toHaveLength(0);

  secondFlight.cleanup();
  expect(first.bubble.getAnimations(), "cleaning up the second flight").toHaveLength(0);
});

it("keeps a flight with its row while a later send holds the transcript", () => {
  const { column } = transcript();
  const above = document.createElement("div");
  const turn = document.createElement("div");
  turn.className = "comma-chat-turn-shell";
  column.append(above, turn);
  const row = sentRow(turn);
  const flight = launch(row, 0);
  clock.advanceFrames(1);

  // The next send holds the transcript where it was painted while the turn
  // its row follows has moved down in the layout.
  const painted = turn.getBoundingClientRect().top;
  above.style.height = "50px";
  const hold = holdTranscript(turn, painted);
  clock.advanceFrames(2);

  const [, drawn = "0"] = row.bubble.style.translate.split(" ");
  expect(Math.abs(Number.parseFloat(drawn) || 0)).toBeLessThan(1);
  hold?.cancel();
  flight.cleanup();
});

it("moves a flight across with its row when the window resizes under it", () => {
  const { column } = transcript();
  const row = sentRow(column);
  const flight = launch(row, 0);
  clock.advanceFrames(1);

  // The column narrows by 40px on the row's end.
  row.slot.parentElement!.style.paddingRight = "40px";
  clock.advanceFrames(2);

  const [across = "0"] = row.bubble.style.translate.split(" ");
  expect(Number.parseFloat(across) || 0).toBeCloseTo(-40, 0);
  flight.cleanup();
});

it("lets the transcript go when a held send does not launch", () => {
  const { column, viewport } = transcript();
  const turn = document.createElement("div");
  turn.className = "comma-chat-turn-shell";
  column.append(turn);
  const hold = holdTranscript(turn, turn.getBoundingClientRect().top - 40);
  expect(transcriptHeld(viewport)).toBe(true);

  // A window in the background runs no frames, so its flight never launches.
  clock.advance(500);
  expect(transcriptHeld(viewport)).toBe(false);
  expect(column.getAnimations()).toHaveLength(0);
  expect(hold?.release()).toBeUndefined();
});

it("eases the slot to the height its row lands at when the text changed in flight", async () => {
  const { column } = transcript();
  const row = sentRow(column);
  const flight = launch(row, 0);
  const held = row.slot.getBoundingClientRect().height;

  row.content.textContent = Array.from(
    { length: 8 },
    () => "A longer delivered text."
  ).join("\n");
  row.content.style.whiteSpace = "pre-line";
  flight.animation?.finish();
  await flight.animation?.finished;
  clock.advanceFrames(1);

  const [ease] = row.slot.getAnimations();
  const [from, to] = (ease?.effect as KeyframeEffect | undefined)?.getKeyframes() ?? [];
  expect(Number.parseFloat(String(from?.height))).toBeCloseTo(held, 0);
  expect(Number.parseFloat(String(to?.height))).toBeGreaterThan(held + 20);
});
