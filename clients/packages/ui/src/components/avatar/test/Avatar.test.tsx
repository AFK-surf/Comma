import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Avatar, getInitials } from "../Avatar";

describe("Avatar emoji alignment", () => {
  it("uses natural width on Windows so Segoe UI Emoji centers in the circle", () => {
    const { container } = render(
      <Avatar size="sm" name="pengx17" emoji="🖥️" platform="windows" />
    );
    const glyph = container.querySelector('[aria-hidden="true"]');
    expect(glyph).not.toBeNull();
    expect(glyph?.className).not.toContain("w-[1em]");
    expect(glyph?.className).toContain("-translate-y-[0.05em]");
  });

  it("keeps the 1em box on macOS unchanged", () => {
    const { container } = render(
      <Avatar size="sm" name="pengx17" emoji="🖥️" platform="macos" />
    );
    const glyph = container.querySelector('[aria-hidden="true"]');
    expect(glyph).not.toBeNull();
    expect(glyph?.className).toContain("w-[1em]");
    expect(glyph?.className).not.toContain("-translate-y-[0.05em]");
  });
});

describe("Avatar initials", () => {
  it("takes a Latin name's first letters and one character of a CJK name", () => {
    expect(getInitials("Lin Wei")).toBe("LW");
    expect(getInitials("  maya   chen  ")).toBe("MC");
    expect(getInitials("佐藤 健")).toBe("佐");
    expect(getInitials("王小明")).toBe("王");
    expect(getInitials("김민준")).toBe("김");
    expect(getInitials("𠮷野 家")).toBe("𠮷");
  });
});

describe("Avatar of a seat known only by an email", () => {
  it("shows a person, not the letter @", () => {
    const { container } = render(<Avatar size="xs" name="@" />);
    expect(container.textContent).toBe("");
    expect(container.querySelector("svg")).not.toBeNull();
  });
});
