import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { InputField } from "../InputField";

describe("InputField", () => {
  it("forwards key and focus handlers to the input element", () => {
    const onBlur = vi.fn();
    const onFocus = vi.fn();
    const onKeyDown = vi.fn();
    render(
      <InputField
        aria-label="Name"
        onBlur={onBlur}
        onChange={() => undefined}
        onFocus={onFocus}
        onKeyDown={onKeyDown}
        value="draft"
      />
    );

    const input = screen.getByRole("textbox", { name: "Name" });
    fireEvent.focus(input);
    fireEvent.keyDown(input, { key: "Enter" });
    fireEvent.blur(input);

    expect(onFocus).toHaveBeenCalledOnce();
    expect(onKeyDown).toHaveBeenCalledOnce();
    expect(onKeyDown.mock.calls[0]?.[0]).toMatchObject({ key: "Enter" });
    expect(onBlur).toHaveBeenCalledOnce();
  });
});
