import { fireEvent, render } from "@comma/test-utils/render";
import { expect, it, onTestFinished } from "vitest";
import { TaskProgressText } from "../TaskProgressText";

/** Gives every progress line this transition, as task-board.css would. */
function lineTransition(duration: string) {
  const style = document.createElement("style");
  style.textContent = `.comma-task-progress-line { transition-duration: ${duration}; }`;
  document.head.append(style);
  onTestFinished(() => style.remove());
}

function lines(container: HTMLElement) {
  return [...container.querySelectorAll<HTMLElement>(".comma-task-progress-line")].map(
    (line) => ({ state: line.dataset.state, text: line.textContent })
  );
}

it("shows the first words at rest, so a mounting list does not animate", () => {
  const { container } = render(<TaskProgressText>Read SKILL.md</TaskProgressText>);

  expect(lines(container)).toEqual([{ state: undefined, text: "Read SKILL.md" }]);
});

it("brings new words in over the leaving ones and drops the old line once it fades", () => {
  lineTransition("200ms");
  const { container, rerender } = render(<TaskProgressText>Thinking</TaskProgressText>);

  rerender(<TaskProgressText>Read SKILL.md</TaskProgressText>);
  expect(lines(container)).toEqual([
    { state: "leaving", text: "Thinking" },
    { state: "entering", text: "Read SKILL.md" },
  ]);

  fireEvent.transitionEnd(container.querySelector('[data-state="leaving"]')!, {
    propertyName: "opacity",
  });
  expect(lines(container)).toEqual([{ state: "entering", text: "Read SKILL.md" }]);
});

it("keeps one leaving line through a quick run of changes", () => {
  lineTransition("200ms");
  const { container, rerender } = render(<TaskProgressText>a</TaskProgressText>);

  rerender(<TaskProgressText>b</TaskProgressText>);
  rerender(<TaskProgressText>c</TaskProgressText>);

  expect(lines(container)).toEqual([
    { state: "leaving", text: "b" },
    { state: "entering", text: "c" },
  ]);
});

it("drops the leaving line at once when it has no fade to run", () => {
  lineTransition("0s");
  const { container, rerender } = render(<TaskProgressText>Thinking</TaskProgressText>);

  rerender(<TaskProgressText>Read SKILL.md</TaskProgressText>);

  expect(lines(container)).toEqual([{ state: "entering", text: "Read SKILL.md" }]);
});
