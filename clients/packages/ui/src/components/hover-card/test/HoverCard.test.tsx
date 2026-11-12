import { createRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { spacing } from "../../../tokens/spacing";
import { HoverCard } from "../HoverCard";

const rect = (left: number, top: number, width: number, height: number) =>
  DOMRect.fromRect({ height, width, x: left, y: top });

describe("HoverCard", () => {
  it.each([
    ["placed by React Aria's tooltip", false],
    ["kept inside a boundary", true],
  ])(
    "keeps presses in a card %s away from the trigger's ancestors",
    async (_, bounded) => {
      setInteractionModality("pointer");
      const user = userEvent.setup();
      const press = vi.fn();
      const boundary = createRef<HTMLDivElement>();
      render(
        <div
          onAuxClick={press}
          onClick={press}
          onContextMenu={press}
          onDoubleClick={press}
          onMouseDown={press}
          onPointerDown={press}
          ref={boundary}
          role="presentation"
        >
          <HoverCard
            boundaryRef={bounded ? boundary : undefined}
            content={<p>Preview</p>}
            delay={0}
          >
            <button type="button">Trigger</button>
          </HoverCard>
        </div>
      );
      await user.hover(screen.getByRole("button", { name: "Trigger" }));
      const card = await screen.findByRole("tooltip");
      for (const target of [card, screen.getByText("Preview")]) {
        fireEvent.pointerDown(target);
        fireEvent.mouseDown(target);
        fireEvent.click(target);
        fireEvent.doubleClick(target);
        fireEvent.contextMenu(target);
        fireEvent(target, new MouseEvent("auxclick", { bubbles: true, button: 1 }));
      }
      expect(press).not.toHaveBeenCalled();
    }
  );

  it("stays at its trigger when its content holds another hover card", async () => {
    setInteractionModality("pointer");
    const user = userEvent.setup();
    const boundary = createRef<HTMLDivElement>();
    const measure = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: Element) {
        if (this === boundary.current) return rect(0, 0, 1000, 1000);
        if (this.textContent === "Trigger") return rect(300, 400, 80, 20);
        if (this.textContent === "Nested chip") return rect(20, 30, 60, 20);
        return rect(0, 0, 320, 100);
      });
    try {
      render(
        <div ref={boundary}>
          <HoverCard
            boundaryRef={boundary}
            content={
              <HoverCard content={<p>Nested details</p>} pointerOnly>
                <span>Nested chip</span>
              </HoverCard>
            }
            delay={0}
          >
            <button type="button">Trigger</button>
          </HoverCard>
        </div>
      );
      await user.hover(screen.getByRole("button", { name: "Trigger" }));
      const card = await screen.findByRole("tooltip");
      expect(card.style.left).toBe("300px");
      expect(card.style.top).toBe(`${400 + 20 + spacing.md}px`);
    } finally {
      measure.mockRestore();
    }
  });
});
