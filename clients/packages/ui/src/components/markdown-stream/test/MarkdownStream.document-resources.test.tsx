import { fireEvent, render, screen } from "@comma/test-utils/render";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import { MarkdownStream, MarkdownStreamLinkDecoratorContext } from "../MarkdownStream";

describe("file document resource policy", () => {
  it("routes only explicit web links through the host owner and never decorates or fetches embedded resources", () => {
    const onOpenLink = vi.fn();
    const decorate = vi.fn(({ anchor }: { anchor: ReactNode }) => anchor);
    const { container } = render(
      <MarkdownStreamLinkDecoratorContext.Provider value={decorate}>
        <MarkdownStream
          content={
            "[Web](https://example.com/report) [Relative](/v1/private-file) [Local](file:///private/file)\n\n![Image](https://example.com/image.png)\n\n```mermaid\ngraph TD; A --> B\n```"
          }
          final
          htmlPolicy="escape"
          documentResourcePolicy={{ onOpenLink }}
        />
      </MarkdownStreamLinkDecoratorContext.Provider>
    );
    expect(container.querySelector("img")).toBeNull();
    expect(container.querySelector("svg")).toBeNull();
    expect(screen.queryByRole("link", { name: "Relative" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Local" })).not.toBeInTheDocument();
    expect(decorate).not.toHaveBeenCalled();
    expect(onOpenLink).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("link", { name: "Web" }));
    expect(onOpenLink).toHaveBeenCalledExactlyOnceWith("https://example.com/report");
    expect(container.querySelector("pre")).toHaveTextContent("graph TD; A --> B");
  });
});
