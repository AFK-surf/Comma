import { describe, expect, it } from "vitest";
import {
  findHasBeforeUniversalSubjects,
  findNativeSessionAdmissionViolations,
  findUncappedLoops,
} from "../check-foundation-kernel-lib.mjs";

describe("check-foundation-kernel native Session admission", () => {
  it("requires exhaustive classifications and rationale only for local-only leaves", () => {
    expect(
      findNativeSessionAdmissionViolations([
        {
          id: "native.info",
          sessionAdmission: "local_only",
          sessionAdmissionRationale: "Reads local metadata only.",
        },
        { id: "session.state", sessionAdmission: "lifecycle" },
        { id: "chat.state", sessionAdmission: "required" },
      ])
    ).toEqual([]);

    expect(
      findNativeSessionAdmissionViolations([
        { id: "native.info", sessionAdmission: "local_only" },
        { id: "session.state", sessionAdmission: "sometimes" },
        {
          id: "chat.state",
          sessionAdmission: "required",
          sessionAdmissionRationale: "This rationale is invalid here.",
        },
      ])
    ).toEqual([
      "native.info local_only is missing a rationale",
      "session.state has invalid sessionAdmission sometimes",
      "chat.state declares a local-only rationale with required",
    ]);
  });
});

describe("check-foundation-kernel :has() anchors", () => {
  it("finds a universal subject after a :has() compound, flat or nested", () => {
    expect(
      findHasBeforeUniversalSubjects(`
        .row:has(.preview) * { color: red; }
        :root :is(button, label:has(input:enabled)) {
          &, & * { &:not(:disabled) { cursor: pointer; } }
        }
        @media (hover: hover) { .card:has(:focus-visible) > :not(.title) { opacity: 1; } }
      `)
    ).toEqual([
      ".row:has(.preview) *",
      // The lowered nested rule, however lightningcss prints it.
      expect.stringMatching(/label:has\(input:enabled\).*\*/),
      ".card:has(:focus-visible) > :not(.title)",
    ]);
  });

  it("accepts a :has() on the subject or before a named descendant", () => {
    expect(
      findHasBeforeUniversalSubjects(`
        :root label:has(input:enabled) { cursor: pointer; }
        .row:has(> .preview) > .body { grid-row: 2; }
        .slot:not(:has(~ .slot)) > .bubble::before { content: ""; }
      `)
    ).toEqual([]);
  });

  it("reports what it cannot read: parse errors and Tailwind blocks holding :has()", () => {
    expect(
      findHasBeforeUniversalSubjects(`@source "./";
@custom-variant dark (&:where(.dark, .dark *));
@utility text-primary { color: var(--color-text-primary); }
.card { @apply text-primary; }
.row:has(.preview) *, { color: red; }
@utility reveal { &:has(.preview) * { opacity: 1; } }
`)
    ).toEqual([
      expect.stringMatching(/^line 6: @utility holds a :has\(\)/),
      expect.stringMatching(/^line 5: lightningcss could not parse this/),
    ]);
  });
});

describe("check-foundation-kernel looping animations", () => {
  it("finds loops that move on every display refresh", () => {
    expect(
      findUncappedLoops(`
.spin {
  animation: spin 1s linear infinite;
}
.pulse { animation-iteration-count: infinite; }
`)
    ).toEqual([
      "line 3: animation: spin 1s linear infinite",
      "line 5: animation-iteration-count: infinite",
    ]);
    expect(
      findUncappedLoops(
        `const style = { animation: "spin 1s linear infinite" };\nel.animate(frames, { duration: 900, iterations: Infinity });`
      )
    ).toHaveLength(2);
  });

  it("accepts capped, paused and exempted loops", () => {
    expect(
      findUncappedLoops(`
.spin { animation: spin 1s steps(60) infinite; }
.eye { animation: eye 1.6s var(--motion-loop-mascot-drift) infinite alternate; }
.held { animation: hold 10s linear infinite paused; }
.video {
  /* motion-loop: exempt plays the frames of a video */
  animation: frames 1s linear infinite;
}
.once { animation: fade 200ms ease-out; }
`)
    ).toEqual([]);
  });
});
