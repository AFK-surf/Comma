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
  it("lets the host draw a picture the document writes, and names the ones the host does not draw", () => {
    const renderPicture = vi.fn((picture: { src: string } | { html: string }) =>
      "html" in picture ? (
        <b data-testid="sided">{picture.html}</b>
      ) : picture.src === "chart.png" ? (
        <b data-testid="own">{picture.src}</b>
      ) : undefined
    );
    const { container } = render(
      <MarkdownStream
        content={
          '![Chart](chart.png)\n\n<p align="center"><img src="wide.png" alt="Wide" width="60"></p>\n\n![Far](https://example.com/far.png)'
        }
        final
        htmlPolicy="escape"
        documentResourcePolicy={{ onOpenLink: () => undefined, renderPicture }}
      />
    );
    expect(screen.getByTestId("own")).toHaveTextContent("chart.png");
    expect(screen.getByTestId("sided")).toHaveTextContent(
      '<p align="center"><img src="wide.png" alt="Wide" width="60"></p>'
    );
    expect(container.querySelector("img")).toBeNull();
    expect(container).toHaveTextContent("Image: Far (not loaded)");
  });
  it("draws text that has a colour and a ground at once as one element in the other, and none of it as HTML", () => {
    const { container } = render(
      <MarkdownStream
        content={
          'Text <mark data-color="yellow"><span data-color="blue">**both**</span></mark> and <span data-color="red">one</span>.'
        }
        final
        htmlPolicy="escape"
      />
    );
    const ground = container.querySelector('mark[data-color="yellow"]')!;
    expect(ground.querySelector('span[data-color="blue"] strong')).toHaveTextContent(
      "both"
    );
    expect(container.querySelector('span[data-color="red"]')).toHaveTextContent("one");
    expect(container.querySelector("code")).toBeNull();
    expect(container).toHaveTextContent("Text both and one.");
  });
});
