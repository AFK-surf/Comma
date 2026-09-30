import { describe, expect, it } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { plainTextWithLinks } from "../plainTextLinks";

function check(text: string, hrefs: string[]) {
  const { container } = render(<span>{plainTextWithLinks(text) ?? text}</span>);
  expect(container.textContent).toBe(text);
  expect(
    screen.queryAllByRole("link").map((link) => link.getAttribute("href"))
  ).toEqual(hrefs);
  expect(container.querySelector("a a")).toBeNull();
  return container;
}

describe("plainTextWithLinks", () => {
  it("preserves Chinese paths, queries, fragments and English/CJK punctuation", () => {
    check(
      "查看（https://example.com/中文?q=1&b=2#part），再看 https://example.org/a(b).",
      ["https://example.com/中文?q=1&b=2#part", "https://example.org/a(b)"]
    );
  });

  it("recognizes adjacent URLs separated by Chinese punctuation", () => {
    check("https://example.com/a，https://example.org/b。", [
      "https://example.com/a",
      "https://example.org/b",
    ]);
  });

  it("keeps Markdown literal, with no nested anchors", () => {
    check("[Docs](https://example.com/docs) and https://example.org/", [
      "https://example.com/docs",
      "https://example.org/",
    ]);
  });

  it("does not turn code spans into links", () => {
    check(
      "`https://code.example` ``https://two.example ` inside`` https://example.com",
      ["https://example.com"]
    );
  });

  it.each(["```", "~~~"])(
    "does not link fenced code (%s), even when unclosed",
    (fence) => {
      check(`https://example.com\n\n${fence}txt\nhttps://code.example\n`, [
        "https://example.com",
      ]);
    }
  );

  it("does not link indented code or multiline code spans", () => {
    check(
      "    https://code.example\r\n\r\n`code\nhttps://span.example`\nhttps://example.com",
      ["https://example.com"]
    );
  });

  it.each(["\n", "\r\n", "\r"])(
    "preserves code boundaries with %j line endings",
    (newline) => {
      check(
        [
          "https://before.example",
          "",
          "~~~txt",
          "https://fenced.example",
          "~~~",
          "",
          "    https://indented.example",
          "",
          "https://after.example",
        ].join(newline),
        ["https://before.example", "https://after.example"]
      );
    }
  );

  it("accepts explicit HTTP(S) only", () => {
    check(
      "javascript:alert(1) data:text/html,hello file:///tmp/a ftp://example.com mailto:a@example.com www.example.com comma:task/cnv1_test",
      []
    );
  });

  it("does not interpret HTML or event handler text", () => {
    const container = check(
      '<img src=x onerror="alert(1)"> https://example.com/?q=%22%3E%3Cscript%3E',
      ["https://example.com/?q=%22%3E%3Cscript%3E"]
    );
    expect(container.querySelector("img, script")).toBeNull();
  });

  it("keeps encoded punctuation and avoids linking an invalid hostname", () => {
    check("https://example.com/a%EF%BC%8Cb https://", [
      "https://example.com/a%EF%BC%8Cb",
    ]);
  });

  it("keeps ordinary text on the fast path", () => {
    expect(plainTextWithLinks("hello world")).toBeUndefined();
  });

  it("uses keyboard-focusable anchors with the existing new-tab fallback", async () => {
    check("https://example.com", ["https://example.com"]);
    const user = userEvent.setup();
    await user.tab();
    const anchor = screen.getByRole("link");
    expect(anchor).toHaveFocus();
    expect(anchor).toHaveAttribute("target", "_blank");
    expect(anchor).toHaveAttribute("rel", "noopener noreferrer");
  });
});
