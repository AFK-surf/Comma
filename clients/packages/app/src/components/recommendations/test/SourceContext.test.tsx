import { fireEvent, render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { recommendationSourceQuote } from "@comma/recommendation-contract";
import { SourceContext } from "../SourceContext";

it("opens supported source links without executing source markup", () => {
  const open = vi.fn();
  render(
    <SourceContext
      lines={recommendationSourceQuote(
        "<@U123|Alex> <#C123|team> <https://example.com/fix|fix> https://example.com/a(b). <https://user:password@example.com|private> <javascript:alert(1)|unsafe> <img src=x onerror=alert(1)>",
        "https://comma.slack.com/archives/C123/p123"
      )}
      onOpenUrl={open}
    />
  );
  fireEvent.click(screen.getByRole("link", { name: "@Alex" }));
  fireEvent.click(screen.getByRole("link", { name: "#team" }));
  fireEvent.click(screen.getByRole("link", { name: "fix" }));
  fireEvent.click(screen.getByRole("link", { name: "example.com/a(b)" }));
  expect(open.mock.calls).toEqual([
    ["https://comma.slack.com/team/U123"],
    ["https://comma.slack.com/archives/C123"],
    ["https://example.com/fix"],
    ["https://example.com/a(b)"],
  ]);
  expect(screen.queryByRole("link", { name: "private" })).toBeNull();
  expect(screen.queryByRole("link", { name: "unsafe" })).toBeNull();
  expect(document.querySelector("img")).toBeNull();
});

it("shows quote markup as lines, list items, links and literal text", () => {
  const open = vi.fn();
  const { container } = render(
    <SourceContext
      lines={recommendationSourceQuote(
        "Fix &lt;upload&gt; test\nChecks failing · Changes requested\nmira: See <https://github.com/o/r/runs/812?a=1&b=2|run 812>\n• Keep &lt;b&gt;bold&lt;/b&gt; and &lt;@U1|Alex&gt; &amp; text\nImage: [https://statici.icloud.com/fmipmobile/deviceImages-4.0/online_2x.png]",
        "https://github.com/o/r/pull/1"
      )}
      onOpenUrl={open}
    />
  );
  const lines = [...container.querySelectorAll(".comma-recommendation-source-line")];
  expect(
    lines.map((line) => [line.textContent, line.getAttribute("data-list-item")])
  ).toEqual([
    ["Fix <upload> test", null],
    ["Checks failing · Changes requested", null],
    ["mira: See run 812", null],
    ["Keep <b>bold</b> and <@U1|Alex> & text", "true"],
    // A long bare URL names its host and last path segment.
    ["Image: [statici.icloud.com/…/online_2x.png]", null],
  ]);
  fireEvent.click(screen.getByRole("link", { name: "run 812" }));
  fireEvent.click(
    screen.getByRole("link", { name: "statici.icloud.com/…/online_2x.png" })
  );
  expect(open.mock.calls).toEqual([
    ["https://github.com/o/r/runs/812?a=1&b=2"],
    ["https://statici.icloud.com/fmipmobile/deviceImages-4.0/online_2x.png"],
  ]);
  expect(screen.getAllByRole("link")).toHaveLength(2);
});
