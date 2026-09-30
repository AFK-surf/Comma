import { fireEvent, render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { SourceContext } from "../SourceContext";

it("opens supported source links without executing source markup", () => {
  const open = vi.fn();
  render(
    <SourceContext
      sourceHref="https://comma.slack.com/archives/C123/p123"
      text={
        "&lt;@U123|Alex&gt; <#C123|team> <https://example.com/fix|fix> https://example.com/a(b). <https://user:password@example.com|private> <javascript:alert(1)|unsafe> <img src=x onerror=alert(1)>"
      }
      onOpenUrl={open}
    />
  );
  fireEvent.click(screen.getByRole("button", { name: "@Alex" }));
  fireEvent.click(screen.getByRole("button", { name: "#team" }));
  fireEvent.click(screen.getByRole("button", { name: "fix" }));
  fireEvent.click(screen.getByRole("button", { name: "https://example.com/a(b)" }));
  expect(open.mock.calls).toEqual([
    ["https://comma.slack.com/team/U123"],
    ["https://comma.slack.com/archives/C123"],
    ["https://example.com/fix"],
    ["https://example.com/a(b)"],
  ]);
  expect(screen.queryByRole("button", { name: "private" })).toBeNull();
  expect(screen.queryByRole("button", { name: "unsafe" })).toBeNull();
  expect(document.querySelector("img")).toBeNull();
});
