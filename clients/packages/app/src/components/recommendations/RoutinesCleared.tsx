import { useCommaMessages } from "@comma/i18n/react";
import { CelebrateIcon } from "@comma/ui/components/icons";
import { isReducedMotionEnabled, motionRoutineCleared } from "@comma/ui/tokens";
import { useLayoutEffect, useRef, useState } from "react";

type Range = readonly [number, number];

/** One piece a popper throws: what it is, and the flight it was given. */
type ConfettiPiece = {
  id: number;
  kind: "paper" | "dot" | "ribbon";
  tone: number;
  /** The popper's side: -1 throws from the left edge, 1 from the right. */
  side: -1 | 1;
  /** When it leaves the popper, in ms after the burst starts. */
  delay: number;
  flight: number;
  reach: number;
  angle: number;
  fall: number;
  sway: number;
  swayRate: number;
  swayAt: number;
  turn: number;
  spin: number;
  flip: number;
  flipAt: number;
};

const confettiTones = 6;

/** The same draws every time (mulberry32), so every burst is the same throw. */
function seededDraws(seed: number) {
  let state = seed;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let mixed = Math.imul(state ^ (state >>> 15), 1 | state);
    mixed = (mixed + Math.imul(mixed ^ (mixed >>> 7), 61 | mixed)) ^ mixed;
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
}

/** What the two poppers throw: paper mostly, with dots and ribbons among it. */
export function routineConfetti(): ConfettiPiece[] {
  const draw = seededDraws(motionRoutineCleared.pieces);
  const within = ([from, to]: Range) => from + (to - from) * draw();
  return ([-1, 1] as const).flatMap((side, popper) =>
    Array.from({ length: motionRoutineCleared.pieces }, (_, index) => {
      const kind = index % 4 === 3 ? "ribbon" : index % 4 === 1 ? "dot" : "paper";
      return {
        id: popper * motionRoutineCleared.pieces + index,
        kind,
        tone: (index + popper) % confettiTones,
        side,
        delay: within(motionRoutineCleared.delay),
        flight: within(motionRoutineCleared.flight),
        reach: within(motionRoutineCleared.reach),
        angle: within(motionRoutineCleared.angle),
        fall: within(motionRoutineCleared.fall),
        sway: within(motionRoutineCleared.sway),
        swayRate: within(motionRoutineCleared.swayRate),
        swayAt: draw(),
        turn: draw(),
        spin: within(motionRoutineCleared.spin) * (draw() < 0.5 ? -1 : 1),
        flip: kind === "paper" ? within(motionRoutineCleared.flip) : 0,
        flipAt: draw(),
      } satisfies ConfettiPiece;
    })
  );
}

/**
 * A piece's flight across a stage `width` wide, from a popper at `originY` on
 * its side's edge. The throw loses its speed to the air (an exponential), and
 * from then on the piece drifts down and sways. The positions lie closer
 * together at the start, where the piece is fast.
 */
export function confettiFlight(
  piece: ConfettiPiece,
  stage: { width: number; originY: number }
): Keyframe[] {
  const { drag, fadeFrom, reachLimit, samples } = motionRoutineCleared;
  const turn = 2 * Math.PI;
  const reach = Math.min(piece.reach * stage.width, reachLimit);
  const angle = (piece.angle * Math.PI) / 180;
  const originX = piece.side < 0 ? 0 : stage.width;
  return Array.from({ length: samples + 1 }, (_, sample) => {
    const offset = (sample / samples) ** 2;
    const seconds = (offset * piece.flight) / 1000;
    const spent = 1 - Math.exp(-drag * seconds);
    const x =
      originX -
      piece.side * Math.cos(angle) * reach * spent +
      piece.sway * spent * Math.sin(turn * (piece.swayRate * seconds + piece.swayAt));
    const y = stage.originY - Math.sin(angle) * reach * spent + piece.fall * seconds;
    const rotation = 360 * (piece.turn + piece.spin * seconds);
    const flip = piece.flip
      ? Math.cos(turn * (piece.flip * seconds + piece.flipAt))
      : 1;
    return {
      offset,
      opacity: offset <= fadeFrom ? 1 : (1 - offset) / (1 - fadeFrom),
      transform: `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0) rotate(${rotation.toFixed(1)}deg) scaleY(${flip.toFixed(3)})`,
    };
  });
}

/**
 * The Routines with every card cleared. Its copy stays until a refresh brings
 * new cards. With `celebrate`, the moment the member clears the last card, a
 * popper at each side of the rail throws paper and ribbons across it once.
 * Reduced motion keeps the copy and leaves the burst out.
 */
export function RoutinesCleared({ celebrate }: { celebrate: boolean }) {
  const messages = useCommaMessages();
  const stageRef = useRef<HTMLDivElement>(null);
  const copyRef = useRef<HTMLDivElement>(null);
  const [pieces, setPieces] = useState<readonly ConfettiPiece[]>([]);

  useLayoutEffect(() => {
    // Without an animation engine (jsdom) nothing could fly or leave.
    if (
      celebrate &&
      !isReducedMotionEnabled() &&
      typeof stageRef.current?.animate === "function"
    )
      setPieces(routineConfetti());
  }, [celebrate]);

  useLayoutEffect(() => {
    const stage = stageRef.current;
    const copy = copyRef.current;
    if (!stage || !copy || pieces.length === 0) return undefined;
    const bounds = stage.getBoundingClientRect();
    // The poppers stand under the copy, so the throw rises past it.
    const originY =
      copy.getBoundingClientRect().bottom - bounds.top + motionRoutineCleared.drop;
    const flights = pieces.flatMap((piece) => {
      const element = stage.children[piece.id];
      return element
        ? [
            element.animate(confettiFlight(piece, { width: bounds.width, originY }), {
              delay: piece.delay,
              duration: piece.flight,
              fill: "backwards",
            }),
          ]
        : [];
    });
    let cancelled = false;
    void Promise.allSettled(flights.map((flight) => flight.finished)).then(() => {
      if (!cancelled) setPieces([]);
    });
    return () => {
      cancelled = true;
      for (const flight of flights) flight.cancel();
    };
  }, [pieces]);

  return (
    <div
      className="comma-routines-cleared"
      data-celebrating={celebrate ? "true" : undefined}
      data-testid="routines-cleared"
    >
      <div className="comma-routines-cleared-copy" ref={copyRef}>
        <CelebrateIcon aria-hidden="true" className="comma-routines-cleared-mark" />
        <p className="comma-routines-cleared-title">
          {messages.recommendations_cleared()}
        </p>
      </div>
      <div
        aria-hidden="true"
        className="comma-routines-cleared-burst"
        data-testid="routines-cleared-burst"
        ref={stageRef}
      >
        {pieces.map((piece) => (
          <span
            className="comma-routines-confetti"
            data-kind={piece.kind}
            data-tone={piece.tone}
            key={piece.id}
          >
            {piece.kind === "ribbon" ? (
              <svg fill="none" viewBox="0 0 32 12">
                <path
                  d="M2 6c3.5-6 7-6 10.5 0s7 6 10.5 0c2.3-4 4.7-5.3 7-4"
                  stroke="currentColor"
                  strokeLinecap="round"
                  strokeWidth="2.5"
                />
              </svg>
            ) : null}
          </span>
        ))}
      </div>
    </div>
  );
}
