import userEvent from "@testing-library/user-event";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { stubProperty } from "@comma/test-utils/stub-property";
import { describe, expect, it, vi } from "vitest";
import { ChatPanel } from "../ChatPanel";
import { ChatPanelImageGroup, stackSlotForDistance } from "../ChatPanelImageGroup";
import type { ChatPanelMediaDownloadCapability } from "../ChatPanelMediaDownload";

const svgSource = (hue: number) =>
  `data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='30' height='40'%3E%3Crect width='30' height='40' fill='hsl(${hue} 60%25 60%25)'/%3E%3C/svg%3E`;

const sampleImages = (count: number) =>
  Array.from({ length: count }, (_, index) => ({
    alt: `Photo ${index + 1}`,
    src: svgSource(index * 40),
  }));

const downloadableSampleImages = (
  count: number,
  execute: ChatPanelMediaDownloadCapability["execute"]
) =>
  sampleImages(count).map((image, index) => ({
    ...image,
    download: {
      capability: { execute },
      fileName: `photo-${index + 1}.svg`,
    },
  }));

const stackCards = (container: HTMLElement) => [
  ...container.querySelectorAll<HTMLButtonElement>(".chat-panel-image-group-card"),
];

describe("stackSlotForDistance", () => {
  it("defaults everything onto the right fan with two visible depths", () => {
    expect([0, 1, 2, 3].map((index) => stackSlotForDistance(index, 0, 4))).toEqual([
      "0",
      "r1",
      "r2",
      "hidden-right",
    ]);
    expect([0, 1, 2, 3, 4].map((index) => stackSlotForDistance(index, 0, 5))).toEqual([
      "0",
      "r1",
      "r2",
      "hidden-right",
      "hidden-right",
    ]);
  });

  it("moves flipped-past cards onto the mirrored left fan", () => {
    expect(
      [0, 1, 2, 3, 4].map((index) => stackSlotForDistance(index, 1, 5, 1))
    ).toEqual(["l1", "0", "r1", "r2", "hidden-right"]);
    expect(
      [0, 1, 2, 3, 4].map((index) => stackSlotForDistance(index, 2, 5, 2))
    ).toEqual(["l2", "l1", "0", "r1", "r2"]);
    expect(
      [0, 1, 2, 3, 4].map((index) => stackSlotForDistance(index, 0, 5, 4))
    ).toEqual(["0", "hidden-left", "hidden-left", "l2", "l1"]);
  });

  it("wraps cyclically past the last image in both directions", () => {
    expect([0, 1, 2, 3, 4].map((index) => stackSlotForDistance(index, 3, 5))).toEqual([
      "r2",
      "hidden-right",
      "hidden-right",
      "0",
      "r1",
    ]);
    expect(stackSlotForDistance(0, 4, 5)).toBe("r1");
    expect(stackSlotForDistance(2, 6, 8)).toBe("hidden-right");
    expect(stackSlotForDistance(5, 6, 8, 7)).toBe("l1");
  });
});

/**
 * Stubs Web Animations and layout for the shared-element flight: every
 * `animate()` call is recorded with its own `cancel` spy, and cancelling one
 * fires its `cancel` listeners as a browser does.
 */
const stubSharedFlightLayout = () => {
  const cardRect = new DOMRect(40, 120, 165, 220);
  const slideRect = new DOMRect(200, 80, 600, 450);
  const animateCalls: {
    cancel: ReturnType<typeof vi.fn>;
    finish: () => void;
    keyframes: Keyframe[];
    options: KeyframeAnimationOptions;
  }[] = [];

  stubProperty(Element.prototype, "animate", {
    configurable: true,
    value: function mockAnimate(
      keyframes: Parameters<Element["animate"]>[0],
      options?: Parameters<Element["animate"]>[1]
    ) {
      const listeners = new Map<string, (() => void)[]>();
      const trigger = (event: string) => {
        for (const fn of listeners.get(event) ?? []) fn();
      };
      const cancel = vi.fn(() => trigger("cancel"));
      const animation = {
        addEventListener: (event: string, cb: () => void) => {
          const list = listeners.get(event) ?? [];
          list.push(cb);
          listeners.set(event, list);
        },
        cancel,
        finished: Promise.resolve(),
      } as unknown as Animation;
      animateCalls.push({
        cancel,
        finish: () => trigger("finish"),
        keyframes: Array.isArray(keyframes) ? (keyframes as Keyframe[]) : [],
        options: (options ?? {}) as KeyframeAnimationOptions,
      });
      return animation;
    },
  });
  const originalGetBoundingClientRect = Element.prototype.getBoundingClientRect;
  vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(
    function mockRect(this: Element) {
      if (this.classList.contains("chat-panel-image-filmstrip-slide")) {
        return slideRect;
      }
      if (this.classList.contains("chat-panel-image-group-card")) return cardRect;
      return originalGetBoundingClientRect.call(this);
    }
  );
  return animateCalls;
};

const previewOverlay = () =>
  document.querySelector(".chat-panel-media-preview-overlay");

describe("ChatPanelImageGroup", () => {
  it("renders nothing without images", () => {
    const { container } = render(<ChatPanelImageGroup images={[]} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("lays out three or fewer images as a plain row without controls", () => {
    const { container } = render(<ChatPanelImageGroup images={sampleImages(3)} />);

    expect(screen.getAllByRole("img")).toHaveLength(3);
    expect(screen.queryByRole("button", { name: /expand/i })).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Show next image" })
    ).not.toBeInTheDocument();
    expect(container.querySelector("[data-stack-pos]")).toBeNull();
    for (const card of stackCards(container)) {
      expect(card).not.toHaveAttribute("inert");
    }
  });

  it("lets a lone image keep its own ratio instead of the 3:4 card", () => {
    const { container, rerender } = render(
      <ChatPanelImageGroup images={sampleImages(1)} />
    );
    const cards = () =>
      container.querySelector<HTMLElement>(".chat-panel-image-group-cards");

    expect(cards()).toHaveAttribute("data-single", "true");
    expect(screen.getByRole("img")).toHaveAttribute("loading", "eager");

    rerender(<ChatPanelImageGroup images={sampleImages(2)} />);
    expect(cards()).not.toHaveAttribute("data-single");
    for (const img of screen.getAllByRole("img")) {
      expect(img).toHaveAttribute("loading", "lazy");
    }
  });

  it("marks only stackable groups (4+ images) with data-stackable for fan allowance", () => {
    const { container, rerender } = render(
      <ChatPanelImageGroup images={sampleImages(2)} />
    );
    const cards = () =>
      container.querySelector<HTMLElement>(".chat-panel-image-group-cards");

    expect(cards()).not.toHaveAttribute("data-stackable");

    rerender(<ChatPanelImageGroup images={sampleImages(3)} />);
    expect(cards()).not.toHaveAttribute("data-stackable");

    rerender(<ChatPanelImageGroup images={sampleImages(4)} />);
    expect(cards()).toHaveAttribute("data-stackable", "true");
  });

  it("stacks more than three images behind an expand pill", () => {
    const { container } = render(<ChatPanelImageGroup images={sampleImages(5)} />);

    const toggle = screen.getByRole("button", { name: "5 Images" });
    expect(toggle).toHaveAttribute("aria-expanded", "false");

    const cards = stackCards(container);
    expect(cards).toHaveLength(5);
    const frontCards = cards.filter((card) => card.dataset.stackPos === "0");
    expect(frontCards).toHaveLength(1);
    expect(frontCards[0]?.querySelector("img")).toHaveAttribute("alt", "Photo 1");
    const interactiveCards = cards.filter((card) => !card.hasAttribute("inert"));
    expect(interactiveCards).toEqual(frontCards);
    expect(
      cards.filter((card) => card.dataset.stackPos === "hidden-right")
    ).toHaveLength(2);
    for (const card of cards) {
      if (card.dataset.stackPos === "hidden-right") {
        expect(card.querySelector("img")).toBeNull();
      }
    }
  });

  it("expands into a row and collapses back into the stack", async () => {
    const user = userEvent.setup();
    const onExpandedChange = vi.fn();
    const { container } = render(
      <ChatPanelImageGroup
        images={sampleImages(4)}
        onExpandedChange={onExpandedChange}
      />
    );

    await user.click(screen.getByRole("button", { name: "4 Images" }));
    const hideToggle = screen.getByRole("button", { name: "Hide" });
    expect(hideToggle).toHaveAttribute("aria-expanded", "true");
    expect(onExpandedChange).toHaveBeenLastCalledWith(true);
    expect(container.querySelector("[data-stack-pos]")).toBeNull();
    for (const card of stackCards(container)) {
      expect(card).not.toHaveAttribute("inert");
      expect(card.querySelector("img")).not.toBeNull();
    }

    await user.click(hideToggle);
    expect(screen.getByRole("button", { name: "4 Images" })).toHaveAttribute(
      "aria-expanded",
      "false"
    );
    expect(onExpandedChange).toHaveBeenLastCalledWith(false);
    expect(container.querySelectorAll('[data-stack-pos="0"]')).toHaveLength(1);
  });

  it("starts expanded when defaultExpanded is set", () => {
    const { container } = render(
      <ChatPanelImageGroup defaultExpanded images={sampleImages(5)} />
    );

    expect(screen.getByRole("button", { name: "Hide" })).toHaveAttribute(
      "aria-expanded",
      "true"
    );
    expect(container.querySelector("[data-stack-pos]")).toBeNull();
  });

  it("rotates infinitely and wraps back to the first image", async () => {
    const user = userEvent.setup();
    const { container } = render(<ChatPanelImageGroup images={sampleImages(5)} />);

    const nextButton = screen.getByRole("button", { name: "Show next image" });
    const frontAlt = () =>
      container
        .querySelector('[data-stack-pos="0"]')
        ?.querySelector("img")
        ?.getAttribute("alt");

    await user.click(nextButton);
    expect(frontAlt()).toBe("Photo 2");
    expect(screen.getByText("Image 2 of 5: Photo 2")).toBeInTheDocument();

    for (let step = 0; step < 4; step += 1) {
      await user.click(nextButton);
    }
    expect(frontAlt()).toBe("Photo 1");
    expect(screen.getByText("Image 1 of 5: Photo 1")).toBeInTheDocument();
  });

  it("rotates backward from the previous button and wraps to the last image", async () => {
    const user = userEvent.setup();
    const { container } = render(<ChatPanelImageGroup images={sampleImages(5)} />);

    const previousButton = screen.getByRole("button", { name: "Show previous image" });
    const frontAlt = () =>
      container
        .querySelector('[data-stack-pos="0"]')
        ?.querySelector("img")
        ?.getAttribute("alt");

    await user.click(previousButton);
    expect(frontAlt()).toBe("Photo 5");
    expect(screen.getByText("Image 5 of 5: Photo 5")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Show next image" }));
    expect(frontAlt()).toBe("Photo 1");
  });

  it("opens the preview from the front card", async () => {
    const user = userEvent.setup();
    const { container } = render(<ChatPanelImageGroup images={sampleImages(5)} />);

    const frontCard =
      container.querySelector<HTMLButtonElement>('[data-stack-pos="0"]');
    expect(frontCard).not.toBeNull();
    await user.click(frontCard!);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    expect(dialog.querySelector("img")).toHaveAttribute("alt", "Photo 1");
  });

  it("removes the visible indicator and dismisses from preview whitespace", async () => {
    const user = userEvent.setup();
    const { container } = render(<ChatPanelImageGroup images={sampleImages(5)} />);
    const frontCard =
      container.querySelector<HTMLButtonElement>('[data-stack-pos="0"]');
    await user.click(frontCard!);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    expect(dialog.querySelector(".chat-panel-image-filmstrip-counter")).toBeNull();

    fireEvent.click(within(dialog).getByRole("img", { name: "Photo 1" }));
    expect(dialog).toBeInTheDocument();

    const previewBackdrop = document.querySelector(".chat-panel-media-preview-modal");
    expect(previewBackdrop).not.toBeNull();
    fireEvent.click(previewBackdrop!);
    await waitFor(() => expect(dialog).not.toBeInTheDocument());
    expect(frontCard).toHaveFocus();
  });

  it("downloads whichever preview image is currently active", async () => {
    const user = userEvent.setup();
    const execute = vi.fn().mockResolvedValue({ status: "success" });
    const images = downloadableSampleImages(3, execute);
    const { container } = render(<ChatPanelImageGroup images={images} />);
    await user.click(stackCards(container)[0]!);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    const preview = within(dialog);
    await user.click(preview.getByRole("button", { name: "Download image" }));
    await waitFor(() =>
      expect(execute).toHaveBeenNthCalledWith(1, {
        fileName: "photo-1.svg",
        kind: "image",
        source: images[0]!.src,
      })
    );

    await user.click(preview.getByRole("button", { name: "Show next image" }));
    await waitFor(() =>
      expect(preview.getByRole("button", { name: "Download image" })).toBeEnabled()
    );
    await user.click(preview.getByRole("button", { name: "Download image" }));
    await waitFor(() =>
      expect(execute).toHaveBeenNthCalledWith(2, {
        fileName: "photo-2.svg",
        kind: "image",
        source: images[1]!.src,
      })
    );
  });

  it("navigates the preview in both directions and keeps the stack front aligned", async () => {
    const user = userEvent.setup();
    const { container } = render(<ChatPanelImageGroup images={sampleImages(5)} />);

    const frontCard =
      container.querySelector<HTMLButtonElement>('[data-stack-pos="0"]');
    expect(frontCard).not.toBeNull();
    await user.click(frontCard!);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    const preview = within(dialog);
    // aria-disabled, not the native attribute: the control has to stay
    // focusable so reaching an end never drops focus out of the dialog.
    expect(
      preview.getByRole("button", { name: "Show previous image" })
    ).toHaveAttribute("aria-disabled", "true");

    await user.click(preview.getByRole("button", { name: "Show next image" }));
    await user.click(preview.getByRole("button", { name: "Show next image" }));

    expect(preview.getByRole("img", { name: "Photo 3" })).toBeInTheDocument();
    expect(preview.getByRole("status")).toHaveTextContent("Image 3 of 5: Photo 3");
    expect(
      container.querySelector('[data-stack-pos="0"]')?.querySelector("img")
    ).toHaveAttribute("alt", "Photo 3");
    expect(container.querySelectorAll('[data-flying="true"]')).toHaveLength(0);

    await user.click(preview.getByRole("button", { name: "Show previous image" }));
    expect(preview.getByRole("img", { name: "Photo 2" })).toBeInTheDocument();
    expect(
      container.querySelector('[data-stack-pos="0"]')?.querySelector("img")
    ).toHaveAttribute("alt", "Photo 2");
  });

  it("keeps viewer focus on an available navigation control at the boundaries", async () => {
    const user = userEvent.setup();
    const { container } = render(<ChatPanelImageGroup images={sampleImages(4)} />);
    const frontCard =
      container.querySelector<HTMLButtonElement>('[data-stack-pos="0"]');
    await user.click(frontCard!);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    const preview = within(dialog);
    const previous = preview.getByRole("button", { name: "Show previous image" });
    const next = preview.getByRole("button", { name: "Show next image" });
    await user.click(next);
    await user.click(next);
    await user.click(next);

    expect(next).toHaveAttribute("aria-disabled", "true");
    expect(next).not.toBeDisabled();
    expect(previous).toHaveFocus();
  });

  it("keeps three-or-fewer images tiled while their preview remains navigable", async () => {
    const user = userEvent.setup();
    const { container } = render(<ChatPanelImageGroup images={sampleImages(2)} />);
    const cards = stackCards(container);

    await user.click(cards[0]!);
    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    await user.click(within(dialog).getByRole("button", { name: "Show next image" }));

    expect(within(dialog).getByRole("img", { name: "Photo 2" })).toBeInTheDocument();
    expect(container.querySelector("[data-stack-pos]")).toBeNull();
    expect(screen.queryByRole("button", { name: /images/i })).not.toBeInTheDocument();
    for (const card of cards) expect(card).not.toHaveAttribute("inert");
  });

  it("aligns an expanded-card preview before the group collapses again", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <ChatPanelImageGroup defaultExpanded images={sampleImages(5)} />
    );
    const cards = stackCards(container);

    await user.click(cards[2]!);
    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    expect(within(dialog).getByRole("img", { name: "Photo 3" })).toBeInTheDocument();
    await user.click(within(dialog).getByRole("button", { name: "Show next image" }));
    expect(within(dialog).getByRole("img", { name: "Photo 4" })).toBeInTheDocument();

    await user.click(within(dialog).getByRole("button", { name: "Close preview" }));
    await user.click(screen.getByRole("button", { name: "Hide" }));
    expect(
      container.querySelector('[data-stack-pos="0"]')?.querySelector("img")
    ).toHaveAttribute("alt", "Photo 4");
  });

  it("renders only image cards — files stay out of the layout", () => {
    const { container } = render(<ChatPanelImageGroup images={sampleImages(6)} />);

    const cards = stackCards(container);
    expect(cards).toHaveLength(6);
    const hiddenCards = cards.filter(
      (card) =>
        card.dataset.stackPos === "hidden-right" ||
        card.dataset.stackPos === "hidden-left"
    );
    expect(hiddenCards).toHaveLength(3);
    for (const card of hiddenCards) {
      expect(card.querySelector("img")).toBeNull();
    }
    expect(container.querySelectorAll("img")).toHaveLength(3);
  });

  it("defaults to end alignment and supports start alignment for agent images", () => {
    const { container, rerender } = render(
      <ChatPanelImageGroup images={sampleImages(4)} />
    );
    expect(container.querySelector(".chat-panel-image-group")).toHaveAttribute(
      "data-align",
      "end"
    );

    rerender(<ChatPanelImageGroup align="start" images={sampleImages(4)} />);
    expect(container.querySelector(".chat-panel-image-group")).toHaveAttribute(
      "data-align",
      "start"
    );
  });

  it("exposes single-image hover copy toolbar and preview copy action when onCopy is provided", async () => {
    const user = userEvent.setup();
    const onCopy = vi.fn().mockResolvedValue(undefined);
    const images = sampleImages(1).map((image) => ({ ...image, onCopy }));
    const { container } = render(<ChatPanelImageGroup align="start" images={images} />);

    const figure = container.querySelector(".chat-panel-image-group");
    expect(figure).toHaveAttribute("data-single", "true");
    await user.click(screen.getByRole("button", { name: "Copy image" }));
    await waitFor(() => expect(onCopy).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Image copied" })).toBeInTheDocument()
    );

    await user.click(stackCards(container)[0]!);
    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    await user.click(
      within(dialog).getByRole("button", { name: /copy image|image copied/i })
    );
    await waitFor(() => expect(onCopy).toHaveBeenCalledTimes(2));
  });

  it("runs shared-element FLIP on preview open, navigation, and close back to the updated front card", async () => {
    const user = userEvent.setup();
    const animateCalls = stubSharedFlightLayout();

    const { container } = render(
      <ChatPanelImageGroup align="start" images={sampleImages(4)} />
    );
    const cards = stackCards(container);
    await user.click(cards[0]!);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    expect(cards[0]).toHaveAttribute("data-shared-hidden", "true");
    expect(document.querySelector(".chat-panel-media-preview-overlay")).toHaveAttribute(
      "data-shared-transition",
      "opening"
    );
    expect(animateCalls.length).toBeGreaterThanOrEqual(1);
    const openCall = animateCalls.at(-1)!;
    expect(openCall.options.duration).toBe(280);
    act(() => {
      openCall.finish();
    });

    await waitFor(() => expect(cards[0]).not.toHaveAttribute("data-shared-hidden"));

    await user.click(within(dialog).getByRole("button", { name: "Show next image" }));
    expect(cards[1]).toHaveAttribute("data-stack-pos", "0");

    await user.click(within(dialog).getByRole("button", { name: "Close preview" }));
    await waitFor(() => expect(cards[1]).toHaveAttribute("data-shared-hidden", "true"));
    expect(document.querySelector(".chat-panel-media-preview-overlay")).toHaveAttribute(
      "data-shared-transition",
      "closing"
    );
    const closeCall = animateCalls.at(-1)!;
    expect(closeCall.options.duration).toBe(260);
    act(() => {
      closeCall.finish();
    });

    await waitFor(() => expect(dialog).not.toBeInTheDocument());
    expect(cards[1]).not.toHaveAttribute("data-shared-hidden");
  });

  it("hands over to the filmstrip at once when the preview is browsed during the opening flight", async () => {
    const user = userEvent.setup();
    const animateCalls = stubSharedFlightLayout();
    const { container } = render(
      <ChatPanelImageGroup align="start" images={sampleImages(4)} />
    );
    const cards = stackCards(container);
    await user.click(cards[0]!);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    expect(previewOverlay()).toHaveAttribute("data-shared-transition", "opening");
    const openCall = animateCalls.at(-1)!;
    expect(openCall.options.duration).toBe(280);

    await user.click(within(dialog).getByRole("button", { name: "Show next image" }));

    expect(openCall.cancel).toHaveBeenCalled();
    expect(previewOverlay()).not.toHaveAttribute("data-shared-transition");
    expect(document.querySelector(".chat-panel-image-group-shared-flight")).toBeNull();
    expect(cards[0]).not.toHaveAttribute("data-shared-hidden");
    expect(cards[1]).toHaveAttribute("data-stack-pos", "0");
    expect(dialog.querySelector(".chat-panel-image-filmstrip")).toHaveAttribute(
      "data-active-index",
      "1"
    );
  });

  it("does not interrupt the closing flight when the preview is browsed", async () => {
    const user = userEvent.setup();
    const animateCalls = stubSharedFlightLayout();
    const { container } = render(
      <ChatPanelImageGroup align="start" images={sampleImages(4)} />
    );
    const cards = stackCards(container);
    await user.click(cards[0]!);
    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    act(() => {
      animateCalls.at(-1)!.finish();
    });
    await waitFor(() =>
      expect(previewOverlay()).not.toHaveAttribute("data-shared-transition")
    );

    await user.click(within(dialog).getByRole("button", { name: "Close preview" }));
    await waitFor(() =>
      expect(previewOverlay()).toHaveAttribute("data-shared-transition", "closing")
    );
    const closeCall = animateCalls.at(-1)!;
    expect(closeCall.options.duration).toBe(260);

    fireEvent.keyDown(document, { key: "ArrowRight" });

    expect(closeCall.cancel).not.toHaveBeenCalled();
    expect(previewOverlay()).toHaveAttribute("data-shared-transition", "closing");
    expect(cards[0]).toHaveAttribute("data-shared-hidden", "true");
  });

  it("renders inside the chat panel via message images, files as pills", () => {
    render(
      <ChatPanel
        messages={[
          {
            attachments: [{ id: "file-1", label: "Openai.pdf" }],
            content: "Mixed message",
            id: "user",
            images: sampleImages(5),
            kind: "user",
          },
        ]}
      />
    );

    expect(screen.getByRole("button", { name: "5 Images" })).toBeInTheDocument();
    expect(screen.getByText("Openai.pdf")).toBeInTheDocument();
    expect(screen.getByText("Mixed message")).toBeInTheDocument();
  });
});
