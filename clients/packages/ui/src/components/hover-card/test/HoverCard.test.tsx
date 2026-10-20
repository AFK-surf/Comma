import { createRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { HoverCard } from "../HoverCard";

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
});
