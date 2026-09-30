import userEvent from "@testing-library/user-event";
import { StrictMode, useState, type KeyboardEvent } from "react";
import { afterEach, describe, expect, expectTypeOf, it, vi } from "vitest";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { getMenuPointerOffsets } from "../../menu";
import { MicrophoneFilledIcon } from "../../icons";
import { OverlayPortalProvider } from "../../portal";
import { AiInput } from "../composer/AiInput";
import {
  createAiInputRichValue,
  createPlainAiInputRichValue,
  type AiInputMenuRegistration,
  type AiInputRichTokenSegment,
} from "../richText";
import {
  AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX,
  AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX,
  AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX,
  AI_INPUT_TEXTAREA_MAX_HEIGHT_PX,
  AI_INPUT_TEXTAREA_MIN_HEIGHT_PX,
} from "../styles";
import type { AiInputAttachment, AiInputProps } from "../types";

const imageSource = (hue: number) =>
  `data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='30' height='40'%3E%3Crect width='30' height='40' fill='hsl(${hue} 60%25 60%25)'/%3E%3C/svg%3E`;

const originalTextareaScrollHeight = Object.getOwnPropertyDescriptor(
  HTMLTextAreaElement.prototype,
  "scrollHeight"
);

function iconSvgMarkup(icon: React.ReactElement) {
  const { container, unmount } = render(icon);
  const markup = container.querySelector("svg")?.innerHTML;
  unmount();
  return markup;
}

const expectToolbarColorTokens = () => {
  expect(screen.getByRole("button", { name: "Add attachment" })).toHaveClass(
    "text-ai-input-panel-icon-primary"
  );
  const access = screen.getByRole("button", { name: "Full-access" });
  expect(access).toHaveClass(
    "bg-transparent",
    "hover:bg-quaternary",
    "h-[30px]",
    "w-[143px]",
    "px-md",
    "py-xs",
    "text-ai-input-panel-text-warning"
  );
  expect(access).not.toHaveClass(
    "h-9",
    "hover:bg-secondary",
    "px-lg",
    "py-md",
    "py-sm"
  );
  expect(screen.getByText("Full-access")).toHaveClass(
    "shrink-0",
    "whitespace-nowrap",
    "px-xxs"
  );
  expect(access.querySelector("svg")).toHaveClass("text-ai-input-panel-icon-warning");
  expect(screen.queryByRole("button", { name: "Send message" })).toBeNull();
  expect(screen.getByRole("button", { name: "Voice input" })).toHaveClass(
    "bg-button-primary-bg",
    "text-ai-input-panel-icon-fg",
    "hover:bg-button-primary-bg-hover"
  );
};

const VoiceFocusFallbackFixture = () => {
  const [showVoiceButton, setShowVoiceButton] = useState(true);
  return (
    <AiInput
      onVoiceCancel={() => setShowVoiceButton(false)}
      showVoiceButton={showVoiceButton}
    />
  );
};

const TokenTooltipPortalFixture = ({
  onRichValueChange,
  onValueChange,
}: {
  onRichValueChange: NonNullable<AiInputProps["onRichValueChange"]>;
  onValueChange: NonNullable<AiInputProps["onValueChange"]>;
}) => {
  const [portalHost, setPortalHost] = useState<HTMLDivElement | null>(null);

  return (
    <>
      <div data-testid="token-tooltip-portal-host" ref={setPortalHost} />
      <OverlayPortalProvider getContainer={() => portalHost}>
        <div
          data-testid="transformed-token-ancestor"
          style={{ transform: "translate(120px, 80px)" }}
        >
          <AiInput
            menuRegistrations={richMenus}
            onRichValueChange={onRichValueChange}
            onValueChange={onValueChange}
          />
        </div>
      </OverlayPortalProvider>
    </>
  );
};

afterEach(() => {
  vi.restoreAllMocks();
  if (originalTextareaScrollHeight) {
    Object.defineProperty(
      HTMLTextAreaElement.prototype,
      "scrollHeight",
      originalTextareaScrollHeight
    );
  } else {
    Reflect.deleteProperty(HTMLTextAreaElement.prototype, "scrollHeight");
  }
});

describe("AiInput", () => {
  it("renders empty send as a filled microphone and hides unavailable access", () => {
    render(<AiInput />);

    const shell =
      screen.getByLabelText("AI prompt").parentElement?.parentElement?.parentElement;
    expect(shell).toHaveClass("min-w-0", "max-w-[744px]", "shadow-xs");
    expect(shell).not.toHaveClass("shadow-sm");

    expect(screen.getByLabelText("AI prompt")).toHaveAttribute(
      "placeholder",
      "Do anything"
    );
    expect(screen.getByRole("button", { name: "Add attachment" })).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Full-access" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Send message" })).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeEnabled();

    ["Add attachment", "Voice input"].forEach((label) => {
      const control = screen.getByRole("button", { name: label });
      expect(control).toHaveClass("size-[30px]", "p-sm");
      expect(control.querySelector("svg")).toHaveClass("size-4");
    });
    expect(screen.getByRole("button", { name: "Add attachment" })).toHaveClass(
      "bg-quaternary",
      "hover:bg-fg-senary"
    );
    expect(screen.getByRole("button", { name: "Voice input" })).toHaveClass(
      "bg-button-primary-bg",
      "hover:bg-button-primary-bg-hover"
    );
  });

  it("starts at two lines, grows with content, and caps height before scrolling", () => {
    let scrollHeight = 40;
    Object.defineProperty(HTMLTextAreaElement.prototype, "scrollHeight", {
      configurable: true,
      get() {
        return scrollHeight;
      },
    });

    const { rerender } = render(<AiInput value="" />);
    const textarea = screen.getByLabelText("AI prompt");

    expect(AI_INPUT_TEXTAREA_MIN_HEIGHT_PX).toBe(40);
    expect(textarea).toHaveClass("leading-5");
    expect(textarea).toHaveStyle({
      height: "40px",
      minHeight: "40px",
    });

    scrollHeight = 90;
    rerender(<AiInput value={"line\n".repeat(4)} />);
    expect(textarea).toHaveStyle({ height: "90px" });

    scrollHeight = 400;
    rerender(<AiInput value={"line\n".repeat(24)} />);
    expect(textarea).toHaveStyle({
      height: `${AI_INPUT_TEXTAREA_MAX_HEIGHT_PX}px`,
      maxHeight: `${AI_INPUT_TEXTAREA_MAX_HEIGHT_PX}px`,
    });
    expect(textarea).toHaveClass("overflow-y-auto");

    scrollHeight = 20;
    rerender(<AiInput value="short again" />);
    expect(textarea).toHaveStyle({
      height: `${AI_INPUT_TEXTAREA_MIN_HEIGHT_PX}px`,
    });
  });

  it("keeps measuring typed text after Strict Mode replays its effects", async () => {
    const scrollHeight = vi
      .spyOn(HTMLTextAreaElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLTextAreaElement) {
        return this.value.includes("\n") ? 90 : 40;
      });

    try {
      render(
        <StrictMode>
          <AiInput />
        </StrictMode>
      );
      const textarea = screen.getByLabelText("AI prompt");

      // Typing asks for a read in the next frame; the replayed mount must not
      // leave that request stuck behind the frame its first mount cancelled.
      fireEvent.change(textarea, { target: { value: "line\n".repeat(4) } });
      await nextFrame();

      expect(textarea).toHaveStyle({ height: "90px" });
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("reports an edit's height at the edit to a host that sizes itself from it", () => {
    let scrollHeight = 20;
    const onLayoutHeightChange = vi.fn();
    const scrollHeightSpy = vi
      .spyOn(HTMLTextAreaElement.prototype, "scrollHeight", "get")
      .mockImplementation(() => scrollHeight);

    try {
      render(
        <AiInput
          onLayoutHeightChange={onLayoutHeightChange}
          textareaMaxHeight={118}
          textareaMinHeight={20}
        />
      );
      const textarea = screen.getByLabelText("AI prompt");

      // No frame runs here: a native window around the composer must hear
      // the new size before the renderer paints it.
      scrollHeight = 64;
      fireEvent.change(textarea, { target: { value: "line\n".repeat(3) } });

      expect(onLayoutHeightChange).toHaveBeenLastCalledWith({
        contentHeight: 64,
        textareaHeight: 64,
      });
    } finally {
      scrollHeightSpy.mockRestore();
    }
  });

  it("reports measured height when a compact textarea overrides the defaults", () => {
    let scrollHeight = 12;
    const onLayoutHeightChange = vi.fn();
    const onTextareaHeightChange = vi.fn();
    Object.defineProperty(HTMLTextAreaElement.prototype, "scrollHeight", {
      configurable: true,
      get() {
        return scrollHeight;
      },
    });

    const { rerender } = render(
      <AiInput
        onLayoutHeightChange={onLayoutHeightChange}
        onTextareaHeightChange={onTextareaHeightChange}
        textareaMaxHeight={118}
        textareaMinHeight={20}
        value=""
      />
    );
    const textarea = screen.getByLabelText("AI prompt");

    expect(textarea).toHaveStyle({
      height: "20px",
      maxHeight: "118px",
      minHeight: "20px",
    });
    expect(onTextareaHeightChange).toHaveBeenLastCalledWith(20);
    expect(onLayoutHeightChange).toHaveBeenLastCalledWith({
      contentHeight: 20,
      textareaHeight: 20,
    });

    scrollHeight = 64;
    rerender(
      <AiInput
        onLayoutHeightChange={onLayoutHeightChange}
        onTextareaHeightChange={onTextareaHeightChange}
        textareaMaxHeight={118}
        textareaMinHeight={20}
        value={"line\n".repeat(3)}
      />
    );
    expect(textarea).toHaveStyle({ height: "64px" });
    expect(onTextareaHeightChange).toHaveBeenLastCalledWith(64);
    expect(onLayoutHeightChange).toHaveBeenLastCalledWith({
      contentHeight: 64,
      textareaHeight: 64,
    });

    scrollHeight = 200;
    rerender(
      <AiInput
        onLayoutHeightChange={onLayoutHeightChange}
        onTextareaHeightChange={onTextareaHeightChange}
        textareaMaxHeight={118}
        textareaMinHeight={20}
        value={"line\n".repeat(12)}
      />
    );
    expect(textarea).toHaveStyle({ height: "118px" });
    expect(onTextareaHeightChange).toHaveBeenLastCalledWith(118);

    scrollHeight = 12;
    rerender(
      <AiInput
        onLayoutHeightChange={onLayoutHeightChange}
        onTextareaHeightChange={onTextareaHeightChange}
        textareaMaxHeight={118}
        textareaMinHeight={20}
        value="short again"
      />
    );
    expect(textarea).toHaveStyle({ height: "20px" });
    expect(onTextareaHeightChange).toHaveBeenLastCalledWith(20);
  });

  it("shrinks against intrinsic content without touching the prompt's transition", () => {
    let intrinsicHeight = 60;
    const transitionsDuringReads: string[] = [];
    const scrollHeight = vi
      .spyOn(HTMLTextAreaElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLTextAreaElement) {
        transitionsDuringReads.push(this.style.transition);
        return intrinsicHeight;
      });

    try {
      const { rerender } = render(
        <AiInput textareaMaxHeight={80} textareaMinHeight={20} value="three lines" />
      );
      const textarea = screen.getByLabelText("AI prompt");
      expect(textarea).toHaveStyle({ height: "60px" });

      // A slide in flight lives on the prompt's transform; overriding the
      // prompt's transition to measure it would cancel the slide.
      textarea.style.transition = "transform 150ms ease";
      transitionsDuringReads.length = 0;
      intrinsicHeight = 20;
      rerender(<AiInput textareaMaxHeight={80} textareaMinHeight={20} value="short" />);

      expect(textarea).toHaveStyle({
        height: "20px",
        transition: "transform 150ms ease",
      });
      expect(transitionsDuringReads).not.toHaveLength(0);
      expect(new Set(transitionsDuringReads)).toEqual(
        new Set(["transform 150ms ease"])
      );
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("does not restart an active transition when the height target is unchanged", () => {
    const scrollHeight = vi
      .spyOn(HTMLTextAreaElement.prototype, "scrollHeight", "get")
      .mockReturnValue(40);
    let textarea: HTMLTextAreaElement | undefined;
    let liveOffsetHeightReads = 0;
    const offsetHeight = vi
      .spyOn(HTMLElement.prototype, "offsetHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        if (this === textarea) liveOffsetHeightReads += 1;
        return 0;
      });

    try {
      const { rerender } = render(
        <AiInput textareaMaxHeight={80} textareaMinHeight={20} value="first" />
      );
      textarea = screen.getByLabelText("AI prompt") as HTMLTextAreaElement;
      expect(textarea).toHaveStyle({ height: "40px" });
      liveOffsetHeightReads = 0;

      rerender(
        <AiInput textareaMaxHeight={80} textareaMinHeight={20} value="second" />
      );

      expect(textarea).toHaveStyle({ height: "40px" });
      expect(liveOffsetHeightReads).toBe(0);
    } finally {
      offsetHeight.mockRestore();
      scrollHeight.mockRestore();
    }
  });

  it("keeps wrap measurement at the collapsed width until text fits again", () => {
    let renderedWidth = 100;
    const bounds = vi
      .spyOn(HTMLTextAreaElement.prototype, "getBoundingClientRect")
      .mockImplementation(
        () =>
          ({
            bottom: 20,
            height: 20,
            left: 0,
            right: renderedWidth,
            top: 0,
            width: renderedWidth,
            x: 0,
            y: 0,
            toJSON: () => ({}),
          }) as DOMRect
      );
    const scrollHeight = vi
      .spyOn(HTMLTextAreaElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLTextAreaElement) {
        if (this.value === "short") return 20;
        return Number.parseFloat(this.style.width) <= 100 ? 40 : 20;
      });

    try {
      const { rerender } = render(
        <AiInput
          textareaMaxHeight={80}
          textareaMeasurementWidthMode="narrowest"
          textareaMinHeight={20}
          value="wrap at collapsed width"
        />
      );
      const textarea = screen.getByLabelText("AI prompt");
      expect(textarea).toHaveStyle({ height: "40px" });

      renderedWidth = 160;
      rerender(
        <AiInput
          textareaMaxHeight={80}
          textareaMeasurementWidthMode="narrowest"
          textareaMinHeight={20}
          value="still measured at collapsed width"
        />
      );
      expect(textarea).toHaveStyle({ height: "40px" });

      rerender(
        <AiInput
          textareaMaxHeight={80}
          textareaMeasurementWidthMode="narrowest"
          textareaMinHeight={20}
          value="short"
        />
      );
      expect(textarea).toHaveStyle({ height: "20px" });
    } finally {
      scrollHeight.mockRestore();
      bounds.mockRestore();
    }
  });

  it("enables accessory controls only when they have actions", async () => {
    const onAccessPress = vi.fn();
    const onAttachPress = vi.fn();
    const onVoicePress = vi.fn();
    render(
      <AiInput
        onAccessPress={onAccessPress}
        onAttachPress={onAttachPress}
        onVoicePress={onVoicePress}
        showAccessButton
      />
    );

    await userEvent.click(screen.getByRole("button", { name: "Add attachment" }));
    await userEvent.click(screen.getByRole("button", { name: "Full-access" }));
    await userEvent.click(screen.getByRole("button", { name: "Voice input" }));

    expect(onAttachPress).toHaveBeenCalledOnce();
    expect(onAccessPress).toHaveBeenCalledOnce();
    expect(onVoicePress).toHaveBeenCalledOnce();
    expect(screen.getByRole("img", { name: "Voice recording" })).toBeInTheDocument();
    expect(screen.getByText("0:00")).toBeInTheDocument();
  });

  it("shows an add-files tooltip with an @ shortcut on the plus control", async () => {
    render(<AiInput onAttachPress={vi.fn()} />);

    await userEvent.hover(screen.getByRole("button", { name: "Add attachment" }));

    expect(await screen.findByRole("tooltip")).toHaveTextContent("Add files and more");
    expect(screen.getByLabelText("Keyboard shortcut: @")).toBeInTheDocument();
    expect(screen.getByText("@")).toHaveClass("bg-tooltip-shortcut-bg");
  });

  it("shows a dictate tooltip with a control-D shortcut on the microphone", async () => {
    render(<AiInput />);

    await userEvent.hover(screen.getByRole("button", { name: "Voice input" }));

    const tooltip = await screen.findByRole("tooltip");
    expect(tooltip).toHaveTextContent("Click or hold");
    expect(tooltip).toHaveTextContent("to dictate");
    const shortcut = screen.getByLabelText("Keyboard shortcut: ⌃ D");
    expect(shortcut.querySelectorAll("kbd")).toHaveLength(2);
    expect(screen.getByText("⌃")).toHaveClass("bg-tooltip-shortcut-bg");
    expect(screen.getByText("D")).toHaveClass("bg-tooltip-shortcut-bg");
  });

  it("shows the dictate tooltip on the trailing microphone after the prompt has content", async () => {
    render(<AiInput value="Draft" />);

    await userEvent.hover(screen.getByRole("button", { name: "Voice input" }));

    const tooltip = await screen.findByRole("tooltip");
    expect(tooltip).toHaveTextContent("Click or hold");
    expect(tooltip).toHaveTextContent("to dictate");
    expect(
      screen.getByLabelText("Keyboard shortcut: ⌃ D").querySelectorAll("kbd")
    ).toHaveLength(2);
  });

  it("shows send and newline shortcut rows on the send control", async () => {
    render(<AiInput value="Draft" />);

    await userEvent.hover(screen.getByRole("button", { name: "Send message" }));

    const tooltip = await screen.findByRole("tooltip");
    expect(tooltip).toHaveTextContent("Send");
    expect(tooltip).toHaveTextContent("New line");
    expect(screen.getByLabelText("Keyboard shortcut: Enter")).toHaveTextContent("↩");
    const newlineShortcut = screen.getByLabelText("Keyboard shortcut: Shift Enter");
    expect(newlineShortcut.querySelectorAll("kbd")).toHaveLength(2);
    expect(newlineShortcut).toHaveTextContent("⇧");
    expect(newlineShortcut).toHaveTextContent("↩");
  });

  it("uses the same Figma toolbar color tokens for default and small", () => {
    const props = {
      onAccessPress: vi.fn(),
      onAttachPress: vi.fn(),
      onVoicePress: vi.fn(),
      showAccessButton: true,
    };
    const { rerender } = render(<AiInput {...props} />);

    expectToolbarColorTokens();
    rerender(<AiInput {...props} size="small" />);
    expectToolbarColorTokens();
  });

  it("keeps the compact prompt clear of the access control", () => {
    render(<AiInput richText showAccessButton size="small" />);

    expect(screen.getByLabelText("AI prompt").parentElement).toHaveClass(
      "pl-[calc(30px+var(--spacing-xxs)+143px+8px)]"
    );
  });

  it("can hide inactive accessory buttons without affecting submit", () => {
    render(
      <AiInput
        showAccessButton={false}
        showAttachButton={false}
        showVoiceButton={false}
        value="Ready"
      />
    );

    expect(screen.queryByRole("button", { name: "Add attachment" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Full-access" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Voice input" })).toBeNull();
    expect(screen.getByRole("button", { name: "Send message" })).toBeEnabled();
  });

  it("keeps a disabled send control when voice is hidden and the prompt is empty", () => {
    render(<AiInput showVoiceButton={false} />);

    expect(screen.queryByRole("button", { name: "Voice input" })).toBeNull();
    expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();
  });

  it("uses the filled microphone as send until the prompt has content", async () => {
    const onSubmit = vi.fn();
    const onVoiceCancel = vi.fn();
    const onVoicePress = vi.fn();
    render(
      <AiInput
        onSubmit={onSubmit}
        onVoiceCancel={onVoiceCancel}
        onVoicePress={onVoicePress}
      />
    );

    expect(screen.queryByRole("button", { name: "Send message" })).toBeNull();
    const plus = screen.getByRole("button", { name: "Add attachment" });
    await userEvent.click(screen.getByRole("button", { name: "Voice input" }));
    expect(onVoicePress).toHaveBeenCalledOnce();
    expect(onSubmit).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Add attachment" })).toBe(plus);
    expect(plus).toHaveClass("bg-quaternary", "hover:bg-fg-senary");
    expect(
      document
        .querySelector('[data-slot="ai-input-voice-recording"]')
        ?.querySelector('[aria-label="Add attachment"]')
    ).toBeNull();
    const waveform = screen.getByRole("img", { name: "Voice recording" });
    expect(waveform.style.webkitMaskImage).toContain("linear-gradient(to right");
    expect(waveform.style.maskImage).toMatch(/rgba\(0,\s*0,\s*0,\s*0\)/);
    expect(
      document.querySelector('[data-slot="ai-input-voice-recording-actions"]')
    ).toHaveClass("gap-xs");
    expect(
      screen
        .getByRole("button", { name: "Cancel voice recording" })
        .querySelector("svg")
    ).toHaveClass("size-6");
    expect(
      screen
        .getByRole("button", { name: "Confirm voice recording" })
        .querySelector("svg")
    ).toHaveClass("size-6");

    await userEvent.click(
      screen.getByRole("button", { name: "Cancel voice recording" })
    );
    expect(onVoiceCancel).toHaveBeenCalledOnce();
    expect(screen.queryByRole("img", { name: "Voice recording" })).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeEnabled();
  });

  it("moves the microphone beside send after the prompt has content", async () => {
    const onVoiceConfirm = vi.fn();
    const onVoicePress = vi.fn();
    render(
      <AiInput
        onVoiceConfirm={onVoiceConfirm}
        onVoicePress={onVoicePress}
        value="Draft"
      />
    );

    expect(screen.getByRole("button", { name: "Voice input" })).toHaveClass(
      "bg-transparent",
      "hover:bg-quaternary"
    );
    expect(
      screen
        .getByRole("button", { name: "Voice input" })
        .querySelector("svg[data-comma-icon]")?.innerHTML
    ).toBe(iconSvgMarkup(<MicrophoneFilledIcon />));
    expect(screen.getByRole("button", { name: "Send message" })).toBeEnabled();

    await userEvent.click(screen.getByRole("button", { name: "Voice input" }));
    expect(onVoicePress).toHaveBeenCalledOnce();
    await userEvent.click(
      screen.getByRole("button", { name: "Confirm voice recording" })
    );
    expect(onVoiceConfirm).toHaveBeenCalledOnce();
    expect(onVoiceConfirm).toHaveBeenCalledWith(expect.any(Number));
    expect(screen.getByRole("button", { name: "Send message" })).toBeEnabled();
  });

  it("cancels voice recording with Escape", async () => {
    const onVoiceCancel = vi.fn();
    render(<AiInput onVoiceCancel={onVoiceCancel} />);

    const voiceTrigger = screen.getByRole("button", { name: "Voice input" });
    await userEvent.click(voiceTrigger);
    const recording = screen.getByRole("group", { name: "Voice recording" });
    expect(recording).toHaveAttribute("aria-keyshortcuts", "Enter Escape");
    expect(recording).toHaveClass("focus-visible:shadow-focus-gray");
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onVoiceCancel).not.toHaveBeenCalled();
    expect(screen.getByRole("img", { name: "Voice recording" })).toBeVisible();

    fireEvent.keyDown(recording, { key: "Escape" });

    expect(onVoiceCancel).toHaveBeenCalledOnce();
    expect(screen.queryByRole("img", { name: "Voice recording" })).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toHaveFocus();
  });

  it("confirms voice recording with Enter and restores the initiating control", async () => {
    const onVoiceConfirm = vi.fn();
    render(<AiInput onVoiceConfirm={onVoiceConfirm} />);

    const voiceTrigger = screen.getByRole("button", { name: "Voice input" });
    await userEvent.click(voiceTrigger);
    fireEvent.keyDown(
      document.querySelector('[data-slot="ai-input-voice-recording"]')!,
      { key: "Enter" }
    );

    expect(onVoiceConfirm).toHaveBeenCalledOnce();
    expect(screen.queryByRole("img", { name: "Voice recording" })).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toHaveFocus();
  });

  it("starts voice recording from the advertised Control+D shortcut", () => {
    const onVoicePress = vi.fn();
    render(<AiInput onVoicePress={onVoicePress} />);

    fireEvent.keyDown(screen.getByRole("textbox", { name: "AI prompt" }), {
      ctrlKey: true,
      key: "d",
    });

    expect(onVoicePress).toHaveBeenCalledOnce();
    expect(screen.getByRole("img", { name: "Voice recording" })).toBeVisible();
  });

  it("starts rich voice recording from Control+D", () => {
    const onVoicePress = vi.fn();
    render(<AiInput onVoicePress={onVoicePress} richText />);

    fireEvent.keyDown(screen.getByRole("textbox", { name: "AI prompt" }), {
      ctrlKey: true,
      key: "d",
    });

    expect(onVoicePress).toHaveBeenCalledOnce();
    expect(screen.getByRole("img", { name: "Voice recording" })).toBeVisible();
  });

  it("lets the consumer prevent the Control+D voice shortcut", () => {
    const onKeyDown = vi.fn((event: KeyboardEvent<HTMLElement>) => {
      event.preventDefault();
    });
    const onVoicePress = vi.fn();
    render(<AiInput onKeyDown={onKeyDown} onVoicePress={onVoicePress} />);

    fireEvent.keyDown(screen.getByRole("textbox", { name: "AI prompt" }), {
      ctrlKey: true,
      key: "d",
    });

    expect(onKeyDown).toHaveBeenCalledOnce();
    expect(onVoicePress).not.toHaveBeenCalled();
    expect(screen.queryByRole("img", { name: "Voice recording" })).toBeNull();
  });

  it.each([
    ["disabled", { disabled: true }],
    ["readOnly", { readOnly: true }],
    ["submit pending", { submitPending: true }],
    ["voice hidden", { showVoiceButton: false }],
  ] as const)(
    "does not start voice with Control+D while %s",
    (_label, unavailableProps) => {
      const onVoicePress = vi.fn();
      render(<AiInput onVoicePress={onVoicePress} {...unavailableProps} />);

      fireEvent.keyDown(screen.getByRole("textbox", { name: "AI prompt" }), {
        ctrlKey: true,
        key: "d",
      });

      expect(onVoicePress).not.toHaveBeenCalled();
      expect(screen.queryByRole("img", { name: "Voice recording" })).toBeNull();
    }
  );

  it.each([
    ["disabled", { disabled: true }],
    ["readOnly", { readOnly: true }],
    ["submit pending", { submitPending: true }],
    ["voice hidden", { showVoiceButton: false }],
  ] as const)(
    "cancels recording when the component becomes %s",
    async (_label, changedProps) => {
      const onVoiceCancel = vi.fn();
      const { rerender } = render(<AiInput onVoiceCancel={onVoiceCancel} />);

      await userEvent.click(screen.getByRole("button", { name: "Voice input" }));
      rerender(<AiInput onVoiceCancel={onVoiceCancel} {...changedProps} />);

      await waitFor(() => {
        expect(screen.queryByRole("img", { name: "Voice recording" })).toBeNull();
      });
      expect(onVoiceCancel).toHaveBeenCalledOnce();
    }
  );

  it("disables voice start while readOnly", () => {
    render(<AiInput readOnly />);

    expect(screen.getByRole("button", { name: "Voice input" })).toBeDisabled();
  });

  it("restores focus to the prompt when cancel hides the voice trigger", async () => {
    render(<VoiceFocusFallbackFixture />);

    await userEvent.click(screen.getByRole("button", { name: "Voice input" }));
    fireEvent.keyDown(screen.getByRole("group", { name: "Voice recording" }), {
      key: "Escape",
    });

    expect(screen.queryByRole("button", { name: "Voice input" })).toBeNull();
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveFocus();
  });

  it("preserves focus moved by a voice cancel consumer", async () => {
    const consumerTarget = document.createElement("button");
    document.body.append(consumerTarget);
    try {
      const onVoiceCancel = vi.fn(() => consumerTarget.focus());
      render(<AiInput onVoiceCancel={onVoiceCancel} />);

      await userEvent.click(screen.getByRole("button", { name: "Voice input" }));
      fireEvent.keyDown(screen.getByRole("group", { name: "Voice recording" }), {
        key: "Escape",
      });

      expect(onVoiceCancel).toHaveBeenCalledOnce();
      expect(consumerTarget).toHaveFocus();
    } finally {
      consumerTarget.remove();
    }
  });

  it("shows the image glyph, not a stand-in picture, for an image without a thumbnail", () => {
    render(
      <AiInput attachments={[{ id: "image-1", name: "IMG_1999.jpg", type: "image" }]} />
    );

    const tile = screen.getByTestId("image-attachment");
    expect(tile.querySelector('[data-state="ready"]')).not.toBeNull();
    expect(tile.querySelector("img")).toBeNull();
    expect(tile.querySelector('[data-slot="image-attachment-glyph"]')).not.toBeNull();
    expect(screen.queryByRole("button", { name: "Preview IMG_1999.jpg" })).toBeNull();
  });

  it("previews a settled image tile and browses every staged image", async () => {
    const user = userEvent.setup();
    render(
      <AiInput
        attachments={[
          {
            id: "image-1",
            name: "shot.png",
            thumbnailSrc: imageSource(0),
            type: "image",
          },
          {
            id: "file-1",
            meta: "PDF",
            name: "Reference",
            type: "file",
          },
          {
            id: "image-2",
            name: "chart.png",
            thumbnailSrc: imageSource(120),
            type: "image",
          },
        ]}
      />
    );

    const trigger = screen.getByRole("button", { name: "Preview shot.png" });
    await user.click(trigger);

    const dialog = await screen.findByRole("dialog", { name: "Preview image" });
    const preview = within(dialog);
    expect(preview.getByRole("img", { name: "shot.png" })).toBeInTheDocument();
    // The file chip sits between the two images; the strip skips it.
    expect(preview.getByRole("status")).toHaveTextContent("Image 1 of 2: shot.png");

    await user.click(preview.getByRole("button", { name: "Show next image" }));
    expect(preview.getByRole("img", { name: "chart.png" })).toBeInTheDocument();

    fireEvent.keyDown(document, { key: "ArrowLeft" });
    expect(preview.getByRole("img", { name: "shot.png" })).toBeInTheDocument();

    await user.click(preview.getByRole("button", { name: "Close preview" }));
    await waitFor(() => expect(dialog).not.toBeInTheDocument());
    await waitFor(() => expect(trigger).toHaveFocus());
  });

  it("shows an image glyph instead of an unrelated photo when a thumbnail is unavailable", () => {
    render(
      <AiInput
        attachments={[
          { id: "image-1", name: "settling.png", type: "image" },
          {
            id: "image-2",
            name: "uploading.png",
            state: "loading",
            thumbnailSrc: imageSource(60),
            type: "image",
          },
          {
            id: "image-3",
            name: "broken.png",
            state: "error",
            thumbnailSrc: imageSource(180),
            type: "image",
          },
        ]}
      />
    );

    expect(screen.queryByRole("button", { name: /^Preview / })).toBeNull();
    expect(screen.queryByRole("img", { name: "settling.png" })).toBeNull();
    expect(
      screen.getAllByTestId("image-attachment")[0]?.querySelector("svg")
    ).not.toBeNull();
  });

  it("does not reopen a preview when the same attachment id becomes ready again", async () => {
    const user = userEvent.setup();
    const attachment: AiInputAttachment = {
      id: "image-1",
      name: "shot.png",
      thumbnailSrc: imageSource(0),
      type: "image",
    };
    const { rerender } = render(<AiInput attachments={[attachment]} />);

    await user.click(screen.getByRole("button", { name: "Preview shot.png" }));
    expect(
      await screen.findByRole("dialog", { name: "Preview image" })
    ).toBeInTheDocument();

    rerender(<AiInput attachments={[{ ...attachment, state: "loading" as const }]} />);
    await waitFor(() =>
      expect(
        screen.queryByRole("dialog", { name: "Preview image" })
      ).not.toBeInTheDocument()
    );

    rerender(<AiInput attachments={[attachment]} />);
    expect(
      screen.queryByRole("dialog", { name: "Preview image" })
    ).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Preview shot.png" }));
    expect(
      await screen.findByRole("dialog", { name: "Preview image" })
    ).toBeInTheDocument();
  });

  it("renders the small composer with attachments above its compact input row", () => {
    const { rerender } = render(
      <AiInput
        attachments={[{ id: "file", type: "file", name: "Reference", meta: "PDF" }]}
        onAttachPress={vi.fn()}
        onVoicePress={vi.fn()}
        size="small"
      />
    );

    const prompt = screen.getByLabelText("AI prompt");
    const attachment = screen.getByText("Reference");
    const attachmentScroller = screen.getByLabelText("Attachments");

    expect(prompt).toHaveAttribute("placeholder", "Ask Comma, @ for context");
    expect(prompt).toHaveStyle({
      minHeight: `${AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX}px`,
      maxHeight: `${AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX}px`,
    });
    expect(prompt).toHaveClass("min-h-[36px]", "py-[calc((36px-1lh)/2)]");
    expect(prompt).not.toHaveClass("content-center");
    expect(attachmentScroller).toHaveAttribute("data-orientation", "horizontal");
    expect(attachmentScroller).toHaveAttribute("data-edge-effect", "mask");
    expect(
      attachmentScroller.querySelector('[data-slot="scroll-area-content"]')
    ).toHaveClass("w-max", "gap-md");
    expect(
      attachmentScroller.querySelector('[data-slot="scroll-area-content"]')
    ).not.toHaveClass("flex-wrap");
    expect(prompt.parentElement?.parentElement?.parentElement).toHaveClass(
      "min-w-0",
      "max-w-[744px]",
      "pt-xs",
      "pb-0",
      "gap-md",
      "rounded-3xl"
    );
    expect(prompt.parentElement?.parentElement?.parentElement).not.toHaveClass(
      "rounded-[19px]",
      "max-w-none"
    );
    expect(screen.queryByRole("button", { name: "Full-access" })).toBeNull();
    const compactControls = [
      screen.getByRole("button", { name: "Add attachment" }),
      screen.getByRole("button", { name: "Voice input" }),
      screen.getByRole("button", { name: "Send message" }),
    ];
    expect(compactControls[0]).toHaveClass("bg-quaternary", "hover:bg-fg-senary");
    expect(compactControls[0]).not.toHaveClass("hover:bg-secondary", "bg-transparent");
    expect(compactControls[1]).toHaveClass("bg-transparent", "hover:bg-quaternary");
    expect(compactControls[1]).not.toHaveClass(
      "hover:bg-secondary",
      "hover:bg-fg-senary"
    );
    compactControls.forEach((control) => {
      expect(control).toHaveClass("size-[30px]", "p-sm", "pointer-events-auto");
      expect(control.querySelector("svg")).toHaveClass("size-4");
    });
    expect(
      attachment.compareDocumentPosition(prompt) & Node.DOCUMENT_POSITION_FOLLOWING
    ).toBeTruthy();

    rerender(<AiInput onAttachPress={vi.fn()} onVoicePress={vi.fn()} size="small" />);
    expect(prompt.parentElement?.parentElement?.parentElement).toHaveClass(
      "rounded-[19px]",
      "pt-0"
    );
    expect(prompt.parentElement?.parentElement?.parentElement).not.toHaveClass(
      "rounded-3xl"
    );
  });

  it("promotes multiline small drafts with attachments to the default layout", () => {
    let scrollHeight = AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;
    Object.defineProperty(HTMLTextAreaElement.prototype, "scrollHeight", {
      configurable: true,
      get() {
        return scrollHeight;
      },
    });

    const attachments = [
      { id: "file", type: "file" as const, name: "Reference", meta: "PDF" },
    ];
    const { rerender } = render(
      <AiInput attachments={attachments} size="small" value="One line" />
    );
    const compactPrompt = screen.getByLabelText("AI prompt");

    expect(compactPrompt.parentElement).toHaveClass(
      "h-[36px]",
      "justify-center",
      "pl-7"
    );
    expect(compactPrompt.parentElement?.parentElement).toHaveClass(
      "relative",
      "flex-col"
    );
    expect(compactPrompt).toHaveStyle({
      minHeight: `${AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX}px`,
      maxHeight: `${AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX}px`,
    });

    scrollHeight = AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX + 20;
    rerender(
      <AiInput
        attachments={attachments}
        size="small"
        value="This draft now wraps onto a second line"
      />
    );

    const expandedPrompt = screen.getByLabelText("AI prompt");
    const expandedShell = expandedPrompt.parentElement?.parentElement?.parentElement;

    expect(expandedPrompt).toBe(compactPrompt);
    expect(expandedPrompt.parentElement).toHaveClass("flex-col", "gap-md");
    expect(expandedShell).toContainElement(screen.getByText("Reference"));
    expect(expandedPrompt.parentElement?.nextElementSibling).toHaveClass("h-[36px]");
    expect(expandedPrompt).toHaveStyle({
      minHeight: `${AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX}px`,
      maxHeight: `${AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX}px`,
    });
    expect(expandedShell).toHaveClass(
      "ai-input-small-shell-motion",
      "rounded-3xl",
      "pt-sm",
      "pb-0",
      "px-xs"
    );
    expect(expandedShell).not.toHaveClass("rounded-[19px]");

    scrollHeight = AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;
    rerender(<AiInput attachments={attachments} size="small" value="Short again" />);
    expect(screen.getByLabelText("AI prompt")).toBe(compactPrompt);
    expect(compactPrompt.parentElement).toHaveClass("h-[36px]", "justify-center");
  });

  it("measures wrapped small rich drafts at the rendered editor width", async () => {
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        if (!this.classList.contains("ai-input-rich-editor")) return 0;
        const measurementWidth =
          Number.parseFloat(this.style.width) || this.getBoundingClientRect().width;
        return this.textContent?.includes("3333") && measurementWidth <= 196
          ? AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX + 20
          : AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;
      });

    try {
      render(<AiInput menuRegistrations={richMenus} size="small" />);
      const editor = screen.getByRole("textbox", { name: "AI prompt" });
      vi.spyOn(editor, "getBoundingClientRect").mockImplementation(() => {
        const width = editor.parentElement?.classList.contains("h-[36px]") ? 196 : 302;
        return {
          bottom: 36,
          height: 36,
          left: 0,
          right: width,
          top: 0,
          width,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        };
      });

      typeIntoRichEditor(editor, "实测两者均为 320px；280px 3333");
      await nextFrame();

      expect(editor.parentElement).not.toHaveClass("h-[36px]", "justify-center");
      expect(editor.parentElement?.parentElement?.parentElement).toHaveClass(
        "rounded-3xl"
      );
      expect(editor).toHaveStyle({
        minHeight: `${AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX}px`,
      });
      expect(editor.style.height).toBe("");
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("expands a composing small rich draft without committing the intermediate value", async () => {
    const onRichValueChange = vi.fn();
    const onValueChange = vi.fn();
    const composingText = "大傻的大傻的两回事还得看脸色 d s d s d s d sa";
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        if (!this.classList.contains("ai-input-rich-editor")) return 0;
        return this.textContent === composingText
          ? AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX + 20
          : AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;
      });

    try {
      render(
        <AiInput
          onRichValueChange={onRichValueChange}
          onValueChange={onValueChange}
          richText
          size="small"
        />
      );
      const editor = screen.getByRole("textbox", { name: "AI prompt" });

      fireEvent.compositionStart(editor, { data: composingText });
      editor.textContent = composingText;
      const composingNode = editor.firstChild;
      if (!composingNode) throw new Error("expected composing text node");
      setCaret(composingNode, composingText.length);
      fireEvent.input(editor, {
        data: composingText,
        inputType: "insertCompositionText",
      });
      await nextFrame();

      expect(editor.parentElement).not.toHaveClass("h-[36px]", "justify-center");
      expect(editor.parentElement?.parentElement?.parentElement).toHaveClass(
        "rounded-3xl"
      );
      expect(editor).toHaveStyle({
        minHeight: `${AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX}px`,
      });
      expect(editor.style.height).toBe("");
      expect(editor.parentElement?.parentElement?.style.height).toBe(
        `calc(${AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX + 20 + 36}px + var(--spacing-xs))`
      );
      expect(onValueChange).not.toHaveBeenCalled();
      expect(onRichValueChange).not.toHaveBeenCalled();

      fireEvent.compositionEnd(editor, { data: composingText });

      expect(onValueChange).toHaveBeenCalledOnce();
      expect(onRichValueChange).toHaveBeenCalledOnce();
      expect(onValueChange).toHaveBeenLastCalledWith(composingText);
      expect(onRichValueChange).toHaveBeenLastCalledWith(
        expect.objectContaining({ plainText: composingText })
      );
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("resizes the same shell and interpolates prompt position without scaling", () => {
    let scrollHeight = AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;
    Object.defineProperty(HTMLTextAreaElement.prototype, "scrollHeight", {
      configurable: true,
      get() {
        return scrollHeight;
      },
    });

    const { rerender } = render(<AiInput size="small" value="One line" />);
    const prompt = screen.getByLabelText("AI prompt") as HTMLTextAreaElement;
    const compactComposer = prompt.parentElement?.parentElement;
    const compactShell = compactComposer?.parentElement;
    const flushedStyles: { transform: string; transition: string }[] = [];
    vi.spyOn(HTMLElement.prototype, "offsetWidth", "get").mockImplementation(function (
      this: HTMLElement
    ) {
      if (this === prompt) {
        flushedStyles.push({
          transform: prompt.style.transform,
          transition: prompt.style.transition,
        });
      }
      return 0;
    });
    vi.spyOn(prompt, "getBoundingClientRect").mockImplementation(() => {
      const isExpanded = !prompt.parentElement?.classList.contains("h-[36px]");
      const left = isExpanded ? 20 : 54;
      const width = isExpanded ? 382 : 280;
      return {
        bottom: 36,
        height: 36,
        left,
        right: left + width,
        top: 0,
        width,
        x: left,
        y: 0,
        toJSON: () => ({}),
      };
    });

    expect(compactComposer).toHaveClass("t-resize", "relative", "flex-col");
    expect(compactShell).toHaveClass(
      "ai-input-small-shell-motion",
      "rounded-[19px]",
      "pt-0",
      "pb-0"
    );
    expect(prompt).toHaveClass("ai-input-small-prompt-motion");
    expect(compactComposer).toHaveStyle({
      height: `${AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX}px`,
    });
    scrollHeight = AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX + 20;
    rerender(<AiInput size="small" value="This draft wraps onto a second line" />);

    const expandedComposer = prompt.parentElement?.parentElement;
    const expandedShell = expandedComposer?.parentElement;
    expect(expandedComposer).toBe(compactComposer);
    expect(expandedShell).toBe(compactShell);
    expect(expandedComposer).toHaveClass("t-resize", "relative", "flex", "flex-col");
    expect(expandedShell).toHaveClass(
      "ai-input-small-shell-motion",
      "rounded-3xl",
      "pt-sm",
      "pb-0",
      "px-xs"
    );
    // The offset is flushed with transitions off, then released in the same
    // pass, so the slide starts in the frame the resize starts.
    expect(flushedStyles).toEqual([
      { transform: "translateX(34px)", transition: "none" },
    ]);
    expect(prompt.style.transition).toBe("");
    expect(prompt).toHaveStyle({ transform: "translateX(0)" });
    expect(prompt.style.transform).not.toContain("scale");

    const toolbar = screen.getByRole("button", { name: "Add attachment" }).parentElement
      ?.parentElement;
    expect(toolbar).toHaveClass(
      "ai-input-small-toolbar-hit-area",
      "absolute",
      "inset-x-0",
      "bottom-0",
      "h-[36px]"
    );
  });

  it("uses the expanded width for visible prompt height while preserving compact wrap detection", () => {
    let multiline = false;
    Object.defineProperty(HTMLTextAreaElement.prototype, "scrollHeight", {
      configurable: true,
      get() {
        if (!multiline) return AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;
        return Number.parseFloat(this.style.width) <= 280 ? 300 : 80;
      },
    });

    const { rerender } = render(<AiInput size="small" value="One line" />);
    const prompt = screen.getByLabelText("AI prompt") as HTMLTextAreaElement;
    vi.spyOn(prompt, "getBoundingClientRect").mockImplementation(() => {
      const width = prompt.parentElement?.classList.contains("h-[36px]") ? 280 : 400;
      return {
        bottom: 36,
        height: 36,
        left: 0,
        right: width,
        top: 0,
        width,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      };
    });

    multiline = true;
    rerender(<AiInput size="small" value={"Long prompt ".repeat(20)} />);

    expect(prompt.parentElement?.parentElement).toHaveClass("relative", "flex-col");
    expect(prompt).toHaveStyle({
      height: "80px",
      minHeight: `${AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX}px`,
      maxHeight: `${AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX}px`,
    });
  });

  it("keeps the send affordance disabled and visible as a spinner while pending", () => {
    render(<AiInput submitPending value="Sending now" />);

    const send = screen.getByRole("button", { name: "Sending message" });
    expect(send).toBeDisabled();
    expect(send).toHaveAttribute("data-submit-state", "pending");
    expect(screen.getByTestId("ai-input-submit-spinner")).toBeInTheDocument();
  });

  it("updates the prompt and submits with the current value", async () => {
    const onValueChange = vi.fn();
    const onSubmit = vi.fn();
    render(<AiInput onSubmit={onSubmit} onValueChange={onValueChange} />);

    await userEvent.type(screen.getByLabelText("AI prompt"), "Build this");
    await userEvent.click(screen.getByRole("button", { name: "Send message" }));

    expect(onValueChange).toHaveBeenLastCalledWith("Build this");
    expect(onSubmit).toHaveBeenCalledWith("Build this");
  });

  it("submits with Enter and reserves Shift+Enter for a newline", async () => {
    const onSubmit = vi.fn();
    render(<AiInput onSubmit={onSubmit} />);
    const prompt = screen.getByLabelText("AI prompt");

    await userEvent.type(prompt, "Send this");
    await userEvent.keyboard("{Enter}");
    expect(onSubmit).toHaveBeenCalledWith("Send this");

    onSubmit.mockClear();
    await userEvent.keyboard("{Shift>}{Enter}{/Shift}");
    expect(onSubmit).not.toHaveBeenCalled();
    expect(prompt).toHaveValue("Send this\n");
  });

  it.each([
    { vendor: "Google Inc.", sendsImmediately: true },
    { vendor: "Apple Computer, Inc.", sendsImmediately: false },
  ])(
    "handles Enter right after an IME commit ($vendor)",
    ({ vendor, sendsImmediately }) => {
      const vendorGetter = vi
        .spyOn(window.navigator, "vendor", "get")
        .mockReturnValue(vendor);
      const onSubmit = vi.fn();
      render(<AiInput defaultValue="你好" onSubmit={onSubmit} />);
      const prompt = screen.getByLabelText("AI prompt");

      fireEvent.compositionStart(prompt);
      fireEvent.keyDown(prompt, { key: "Enter", keyCode: 229, isComposing: true });
      expect(onSubmit).not.toHaveBeenCalled();
      fireEvent.compositionEnd(prompt, { data: "你好" });

      // WebKit delivers the confirming Enter after compositionend; Chromium
      // already flagged it above, so this one is a new press.
      fireEvent.keyDown(prompt, { key: "Enter" });
      expect(onSubmit).toHaveBeenCalledTimes(sendsImmediately ? 1 : 0);
      fireEvent.keyDown(prompt, { key: "Enter" });
      expect(onSubmit).toHaveBeenCalledTimes(sendsImmediately ? 2 : 1);

      vendorGetter.mockRestore();
    }
  );

  it("renders attachments and removes them through the close affordance", async () => {
    const user = userEvent.setup();
    const onAttachmentRemove = vi.fn();
    render(
      <AiInput
        attachments={[
          { id: "file", type: "file", name: "Openai", meta: "PDF" },
          {
            id: "image",
            type: "image",
            name: "Asset",
            onRemove: vi.fn(),
          },
        ]}
        onAttachmentRemove={onAttachmentRemove}
      />
    );

    const fileName = screen.getByText("Openai");
    expect(fileName).toBeInTheDocument();
    expect(screen.getByText("PDF")).toBeInTheDocument();
    expect(fileName.closest("div.shadow-xs")).toHaveClass("pt-xs");

    const fileSurface = fileName.parentElement?.parentElement;
    expect(fileSurface).toHaveClass("bg-popup-primary");
    expect(fileSurface).not.toHaveClass("bg-panel-bg-file");

    const fileIconSurface = fileName.parentElement?.previousElementSibling;
    expect(fileIconSurface).toHaveClass(
      "bg-panel-bg-file",
      "text-ai-input-header-text-secondary"
    );
    expect(fileIconSurface).not.toHaveClass("bg-ai-input-panel-bg-attachment");

    // No thumbnail yet: the tile shows the image glyph on the attachment fill.
    const imageSurface = screen
      .getByTestId("image-attachment")
      .querySelector('[data-state="ready"]');
    expect(imageSurface).toContainElement(
      imageSurface!.querySelector('[data-slot="image-attachment-glyph"]')
    );
    expect(imageSurface).toHaveClass("bg-ai-input-panel-bg-attachment");
    expect(imageSurface).not.toHaveClass("bg-panel-bg-file");

    const removeButton = screen.getByRole("button", { name: "Remove Asset" });
    expect(removeButton.className).toMatch(/\bopacity-0\b/);
    expect(removeButton.className).toMatch(/group-hover\/attachment:opacity-100/);

    await user.click(removeButton);

    expect(onAttachmentRemove).toHaveBeenCalledWith(
      expect.objectContaining({ id: "image", name: "Asset" })
    );
  });

  it.each(["default", "small"] as const)(
    "uses the shared rich editor and inserts /skill tokens in the %s layout",
    (size) => {
      const onValueChange = vi.fn();
      const onRichValueChange = vi.fn();
      render(
        <AiInput
          menuRegistrations={richMenus}
          onRichValueChange={onRichValueChange}
          onValueChange={onValueChange}
          size={size}
        />
      );
      const editor = screen.getByRole("textbox", { name: "AI prompt" });

      typeIntoRichEditor(editor, "/cod");
      expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();
      expect(screen.getByRole("option", { name: /Code Review/ })).toBeVisible();

      fireEvent.keyDown(editor, { key: "Enter" });

      const token = editor.querySelector<HTMLElement>("[data-ai-input-token]");
      expect(token).toHaveTextContent("Code Review");
      expect(onValueChange).toHaveBeenLastCalledWith("/code-review ");
      expect(onRichValueChange).toHaveBeenLastCalledWith(
        expect.objectContaining({
          plainText: "/code-review ",
          tokens: [
            expect.objectContaining({
              itemId: "code-review",
              menuId: "skills",
              plainText: "/code-review",
            }),
          ],
        })
      );
    }
  );

  it("renders the first rich Shift+Enter and clears its final deletion artifact", () => {
    const onRichValueChange = vi.fn();
    const onValueChange = vi.fn();
    render(
      <AiInput
        onRichValueChange={onRichValueChange}
        onValueChange={onValueChange}
        richText
        size="small"
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    typeIntoRichEditor(editor, "hello");

    fireEvent.keyDown(editor, { key: "Enter", shiftKey: true });

    const trailingBreak = editor.querySelector("[data-ai-input-trailing-break]");
    expect(editor.textContent).toBe("hello\n");
    expect(editor.childNodes).toHaveLength(2);
    expect(trailingBreak).toHaveAttribute("aria-hidden", "true");
    expect(editor.lastChild).toBe(trailingBreak);
    expect(onValueChange).toHaveBeenLastCalledWith("hello\n");
    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ plainText: "hello\n" })
    );

    for (let index = 1; index < 8; index += 1) {
      fireEvent.keyDown(editor, { key: "Enter", shiftKey: true });
    }

    const repeatedValue = `hello${"\n".repeat(8)}`;
    const selection = window.getSelection();
    expect(editor.textContent).toBe(repeatedValue);
    expect(editor.childNodes).toHaveLength(2);
    expect(editor.lastChild).toBe(trailingBreak);
    expect(selection?.isCollapsed).toBe(true);
    expect(selection?.anchorNode).toBe(editor.firstChild);
    expect(selection?.anchorOffset).toBe(repeatedValue.length);

    Object.defineProperty(editor, "scrollHeight", {
      configurable: true,
      value: 200,
    });
    editor.scrollTop = 0;
    setCaret(editor.firstChild!, "hello".length);
    fireEvent.keyDown(editor, { key: "Enter", shiftKey: true });
    expect(editor.scrollTop).toBe(0);

    editor.replaceChildren(document.createTextNode("\n"), trailingBreak!);
    fireEvent.input(editor, { inputType: "deleteContentBackward" });

    expect(editor).toBeEmptyDOMElement();
    expect(editor).toHaveAttribute("data-empty", "true");
    expect(onValueChange).toHaveBeenLastCalledWith("");
    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ plainText: "" })
    );
  });

  it("renders controlled rich values ending in a visible caret line", () => {
    render(<AiInput richValue={createPlainAiInputRichValue("Line\n\n")} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    expect(editor.textContent).toBe("Line\n\n");
    expect(editor.querySelectorAll("[data-ai-input-trailing-break]")).toHaveLength(1);
  });

  it.each(["default", "small"] as const)(
    "supports @plugin tokens, structured submit, and atomic deletion in the %s layout",
    (size) => {
      const onSubmit = vi.fn();
      const onRichSubmit = vi.fn();
      render(
        <AiInput
          menuRegistrations={richMenus}
          onRichSubmit={onRichSubmit}
          onSubmit={onSubmit}
          size={size}
        />
      );
      const editor = screen.getByRole("textbox", { name: "AI prompt" });

      typeIntoRichEditor(editor, "Ask @cod");
      fireEvent.keyDown(editor, { key: "Enter" });
      const token = editor.querySelector<HTMLElement>("[data-ai-input-token]");
      expect(token).toHaveTextContent("Codex");

      fireEvent.click(screen.getByRole("button", { name: "Send message" }));
      expect(onSubmit).toHaveBeenCalledWith("Ask @codex ");
      expect(onRichSubmit).toHaveBeenCalledWith(
        expect.objectContaining({
          plainText: "Ask @codex ",
          tokens: [expect.objectContaining({ itemId: "codex", menuId: "plugins" })],
        })
      );

      const trailingSpacer = token?.nextSibling as HTMLElement | null;
      expect(trailingSpacer).toHaveAttribute("data-ai-input-token-spacer");
      const spacerIndex = Array.from(editor.childNodes).indexOf(trailingSpacer!);
      setCaret(editor, spacerIndex + 1);
      fireEvent.keyDown(editor, { key: "Backspace" });
      expect(editor.querySelector("[data-ai-input-token]")).toBeNull();
    }
  );

  it("shows token details above transformed ancestors and deletes a clicked active token", () => {
    const onValueChange = vi.fn();
    const onRichValueChange = vi.fn();
    render(
      <TokenTooltipPortalFixture
        onRichValueChange={onRichValueChange}
        onValueChange={onValueChange}
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "Ask @cod");
    fireEvent.keyDown(editor, { key: "Enter" });
    const token = editor.querySelector<HTMLElement>("[data-ai-input-token]");
    expect(token).not.toBeNull();
    let tokenTop = 120;
    vi.spyOn(token!, "getBoundingClientRect").mockImplementation(() => ({
      x: 80,
      y: tokenTop,
      top: tokenTop,
      right: 160,
      bottom: tokenTop + 20,
      left: 80,
      width: 80,
      height: 20,
      toJSON: () => ({}),
    }));
    vi.spyOn(
      screen.getByRole("tooltip", { hidden: true }),
      "getBoundingClientRect"
    ).mockReturnValue({
      x: 0,
      y: 0,
      top: 0,
      right: 300,
      bottom: 57,
      left: 0,
      width: 300,
      height: 57,
      toJSON: () => ({}),
    });
    expect(token).not.toHaveClass("bg-brand-primary");
    expect(token).toHaveClass("rounded-full");
    expect(token).not.toHaveClass("mx-xxs");
    expect(token).toHaveAttribute("data-active", "false");
    expect(screen.queryByRole("button", { name: "Remove Codex" })).toBeNull();

    fireEvent.mouseOver(token!);
    const tooltip = screen.getByRole("tooltip");
    expect(tooltip).toHaveTextContent("Codex");
    expect(tooltip).toHaveTextContent("Write code");
    expect(tooltip).toHaveAttribute("data-animate", "true");
    expect(tooltip).toHaveAttribute("data-placement", "above");
    expect(tooltip).toHaveAttribute("data-state", "open");
    expect(tooltip.querySelector(".ai-input-rich-token-tooltip-text")).not.toBeNull();
    const portalHost = screen.getByTestId("token-tooltip-portal-host");
    expect(tooltip.parentElement?.parentElement).toBe(portalHost);
    expect(screen.getByTestId("transformed-token-ancestor")).not.toContainElement(
      tooltip
    );

    fireEvent.mouseOut(token!, { relatedTarget: editor });
    expect(screen.queryByRole("tooltip")).toBeNull();
    expect(screen.getByRole("tooltip", { hidden: true })).toHaveAttribute(
      "data-state",
      "closed"
    );

    tokenTop = 40;
    fireEvent.focus(token!);
    expect(screen.getByRole("tooltip")).toHaveAttribute("data-animate", "false");
    expect(screen.getByRole("tooltip")).toHaveAttribute("data-placement", "below");

    fireEvent.click(token!);
    expect(token).toHaveAttribute("data-active", "true");
    expect(token).toHaveAttribute("aria-pressed", "true");
    expect(token).toHaveClass(
      "data-[active=true]:bg-brand-primary",
      "focus-visible:bg-brand-primary"
    );
    expect(token).toHaveClass("text-markdown-text-link");
    expect(token).not.toHaveClass(
      "data-[active=true]:text-brand-secondary",
      "focus-visible:text-brand-secondary"
    );
    expect(token).not.toHaveClass("focus-visible:shadow-focus-gray");

    fireEvent.keyDown(token!, { key: "Delete" });
    expect(editor.querySelector("[data-ai-input-token]")).toBeNull();
    expect(onValueChange).toHaveBeenLastCalledWith("Ask ");
    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ plainText: "Ask ", tokens: [] })
    );
  });

  it("keeps the highlighted menu option through ArrowDown keyup before selection", () => {
    render(<AiInput menuRegistrations={navigationMenus} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "/");
    const options = screen.getAllByRole("option");
    expect(options[0]).toHaveAttribute("aria-selected", "true");

    fireEvent.keyDown(editor, { key: "ArrowDown" });
    expect(options[1]).toHaveAttribute("aria-selected", "true");

    fireEvent.keyUp(editor, { key: "ArrowDown" });
    expect(options[1]).toHaveAttribute("aria-selected", "true");

    fireEvent.keyDown(editor, { key: "Enter" });
    expect(editor.querySelector("[data-ai-input-token]")).toHaveAttribute(
      "data-item-id",
      "beta"
    );
  });

  it("serializes a long draft once per input and reuses it on keyup", () => {
    render(<AiInput menuRegistrations={navigationMenus} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const draft = `${"A long line of context.\n".repeat(200)}/a`;
    editor.textContent = draft;
    const text = editor.firstChild;
    if (!text) throw new Error("expected editor text node");
    setCaret(text, draft.length);

    const childNodesGetter = Object.getOwnPropertyDescriptor(
      Node.prototype,
      "childNodes"
    )?.get;
    if (!childNodesGetter) throw new Error("expected Node.childNodes getter");
    let editorRootReads = 0;
    vi.spyOn(Node.prototype, "childNodes", "get").mockImplementation(function (
      this: Node
    ) {
      if (this === editor) editorRootReads += 1;
      return childNodesGetter.call(this);
    });
    const clonedRanges = vi.spyOn(Range.prototype, "cloneContents");

    fireEvent.input(editor, { data: "a", inputType: "insertText" });

    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();
    expect(editorRootReads).toBe(1);
    expect(clonedRanges).not.toHaveBeenCalled();

    fireEvent.keyUp(editor, { key: "a" });
    expect(editorRootReads).toBe(1);
    expect(clonedRanges).not.toHaveBeenCalled();
  });

  it("refreshes an open menu when its registration items change without another editor event", () => {
    const onRichValueChange = vi.fn();
    const initialMenu: AiInputMenuRegistration = {
      id: "skills",
      trigger: "/",
      label: "Skills",
      groups: [{ id: "skills", items: [{ id: "alpha", label: "Alpha" }] }],
    };
    const latestMenu: AiInputMenuRegistration = {
      id: "skills",
      trigger: "/",
      label: "Skills",
      groups: [
        {
          id: "skills",
          items: [{ id: "beta", label: "Beta", data: { revision: 2 } }],
        },
      ],
    };
    const { rerender } = render(
      <AiInput
        menuRegistrations={[initialMenu]}
        onRichValueChange={onRichValueChange}
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    typeIntoRichEditor(editor, "/");
    expect(screen.getByRole("option", { name: "Alpha" })).toBeVisible();

    rerender(
      <AiInput menuRegistrations={[latestMenu]} onRichValueChange={onRichValueChange} />
    );

    expect(screen.queryByRole("option", { name: "Alpha" })).toBeNull();
    expect(screen.getByRole("option", { name: "Beta" })).toBeVisible();
    fireEvent.keyDown(editor, { key: "Enter" });
    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({
        tokens: [expect.objectContaining({ itemId: "beta", data: { revision: 2 } })],
      })
    );
  });

  it("keeps an empty loading menu from submitting its raw trigger query", () => {
    const onSubmit = vi.fn();
    const loadingMenu: AiInputMenuRegistration = {
      id: "mentions",
      trigger: "@",
      label: "Mentions",
      groups: [{ id: "tasks", items: [], status: "loading" }],
    };
    render(<AiInput menuRegistrations={[loadingMenu]} onSubmit={onSubmit} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "@fix");
    expect(screen.getByTestId("ai-input-menu-searching")).toHaveTextContent(
      "Searching..."
    );

    fireEvent.keyDown(editor, { key: "Enter" });
    fireEvent.keyDown(editor, { key: "Tab" });

    expect(onSubmit).not.toHaveBeenCalled();
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    expect(editor).toHaveTextContent("@fix");
  });

  it("keeps an escaped menu closed until the trigger or caret meaningfully changes", () => {
    render(<AiInput menuRegistrations={navigationMenus} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "/");
    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();

    fireEvent.keyDown(editor, { key: "Escape" });
    expect(screen.queryByRole("listbox", { name: "Skills" })).toBeNull();

    fireEvent.keyUp(editor, { key: "Escape" });
    expect(screen.queryByRole("listbox", { name: "Skills" })).toBeNull();

    fireEvent.keyDown(editor, { key: "Shift" });
    fireEvent.keyUp(editor, { key: "Shift" });
    expect(screen.queryByRole("listbox", { name: "Skills" })).toBeNull();

    const triggerText = editor.firstChild as Text | null;
    if (!triggerText) throw new Error("expected trigger text");
    triggerText.appendData("a");
    setCaret(triggerText, triggerText.length);
    fireEvent.input(editor, { data: "a", inputType: "insertText" });
    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();
  });

  it("submits the latest controlled rich tokens and metadata after rerender", () => {
    const onRichSubmit = vi.fn();
    const initialToken = richToken({
      data: { revision: 1 },
      instanceId: "controlled-token",
      itemId: "alpha",
      label: "Alpha",
      plainText: "/alpha",
    });
    const latestToken = richToken({
      data: { revision: 2 },
      instanceId: "controlled-token",
      itemId: "beta",
      label: "Beta",
      plainText: "/beta",
    });
    const initialValue = createAiInputRichValue([
      initialToken,
      { type: "text", text: " first" },
    ]);
    const latestValue = createAiInputRichValue([
      latestToken,
      { type: "text", text: " latest" },
    ]);
    const { rerender } = render(
      <AiInput onRichSubmit={onRichSubmit} richValue={initialValue} />
    );

    rerender(<AiInput onRichSubmit={onRichSubmit} richValue={latestValue} />);
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));

    expect(onRichSubmit).toHaveBeenCalledWith(latestValue);
  });

  it("clears a value-controlled rich editor after submit", () => {
    const ClearingHarness = () => {
      const [current, setCurrent] = useState("");
      return (
        <AiInput
          menuRegistrations={navigationMenus}
          onSubmit={() => setCurrent("")}
          onValueChange={setCurrent}
          value={current}
        />
      );
    };
    render(<ClearingHarness />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    typeIntoRichEditor(editor, "/");
    fireEvent.keyDown(editor, { key: "Enter" });
    expect(editor.querySelector("[data-ai-input-token]")).toHaveTextContent("Alpha");

    fireEvent.keyDown(editor, { key: "Enter" });

    expect(editor).toHaveTextContent(/^$/);
    expect(editor).toHaveAttribute("data-empty", "true");
  });

  it("reconciles a rejected controlled edit when rerendered with the same object", () => {
    const onRichSubmit = vi.fn();
    const value = createAiInputRichValue([
      richToken({ instanceId: "controlled-token" }),
      { type: "text", text: " draft" },
    ]);
    const { rerender } = render(
      <AiInput onRichSubmit={onRichSubmit} richValue={value} />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const draftText = Array.from(editor.childNodes).find(
      (node) => node.nodeType === Node.TEXT_NODE && node.textContent === "draft"
    ) as Text | undefined;
    if (!draftText) throw new Error("expected controlled draft text");
    draftText.appendData("!");
    setCaret(draftText, draftText.length);
    fireEvent.input(editor, { data: "!", inputType: "insertText" });

    rerender(<AiInput onRichSubmit={onRichSubmit} richValue={value} />);

    expect(editor).not.toHaveTextContent("!");
    expect(editor.lastChild).toHaveTextContent(/^draft$/);
    expect(editor.querySelector("[data-ai-input-token]")).toHaveTextContent("Alpha");

    fireEvent.click(screen.getByRole("button", { name: "Send message" }));
    expect(onRichSubmit).toHaveBeenCalledWith(value);
  });

  it("distinguishes controlled token fields that contain signature delimiters", () => {
    const first = createAiInputRichValue([
      richToken({
        description: "Gamma",
        instanceId: "delimiter-token",
        label: "Alpha:Beta",
      }),
    ]);
    const latest = createAiInputRichValue([
      richToken({
        description: "Beta:Gamma",
        instanceId: "delimiter-token",
        label: "Alpha",
      }),
    ]);
    const { rerender } = render(<AiInput richValue={first} />);

    rerender(<AiInput richValue={latest} />);

    expect(
      screen
        .getByRole("textbox", { name: "AI prompt" })
        .querySelector("[data-ai-input-token]")
    ).toHaveTextContent(/^Alpha$/);
  });

  it("does not activate or delete restored tokens or open menus while disabled", () => {
    const onRichValueChange = vi.fn();
    const onValueChange = vi.fn();
    const value = createAiInputRichValue([
      richToken({ instanceId: "disabled-token" }),
      { type: "text", text: " /" },
    ]);
    render(
      <AiInput
        disabled
        menuRegistrations={navigationMenus}
        onRichValueChange={onRichValueChange}
        onValueChange={onValueChange}
        richValue={value}
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const token = editor.querySelector<HTMLElement>("[data-ai-input-token]");
    if (!token) throw new Error("expected restored token");

    fireEvent.click(token);
    expect(token).toHaveAttribute("aria-pressed", "false");
    fireEvent.keyDown(token, { key: "Delete" });
    expect(editor.querySelector("[data-ai-input-token]")).toBe(token);

    const triggerText = Array.from(editor.childNodes).find(
      (node) => node.nodeType === Node.TEXT_NODE && node.textContent === "/"
    );
    if (!triggerText) throw new Error("expected restored trigger text");
    setCaret(triggerText, 1);
    fireEvent.keyUp(editor, { key: "/" });

    expect(screen.queryByRole("listbox", { name: "Skills" })).toBeNull();
    expect(onValueChange).not.toHaveBeenCalled();
    expect(onRichValueChange).not.toHaveBeenCalled();
  });

  it("inserts editable menu text without submitting or replacing surrounding draft", () => {
    const onSubmit = vi.fn();
    const onValueChange = vi.fn();
    render(
      <AiInput
        onSubmit={onSubmit}
        onValueChange={onValueChange}
        menuRegistrations={[
          {
            id: "commands",
            trigger: "/",
            label: "Commands",
            groups: [
              {
                id: "commands",
                items: [
                  {
                    id: "status",
                    label: "Status",
                    insertText: "<salix-command>status</salix-command>",
                  },
                ],
              },
            ],
          },
        ]}
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    typeIntoRichEditor(editor, "before /status after");
    setCaret(editor.firstChild!, "before /status".length);
    fireEvent.keyUp(editor, { key: "ArrowLeft" });
    fireEvent.input(editor, { inputType: "insertText", data: "s" });
    fireEvent.keyDown(editor, { key: "Enter" });
    expect(onValueChange).toHaveBeenLastCalledWith(
      "before <salix-command>status</salix-command> after"
    );
    expect(editor.querySelector("[data-ai-input-token]")).toBeNull();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("avoids restored token id collisions and deletes the selected occurrence", () => {
    const onRichValueChange = vi.fn();
    const value = createAiInputRichValue([
      richToken({
        data: { source: "restored" },
        instanceId: "skills-alpha-1",
        itemId: "alpha",
        label: "Restored Alpha",
        plainText: "/alpha",
      }),
      { type: "text", text: " /" },
    ]);
    const ControlledHarness = () => {
      const [current, setCurrent] = useState(value);
      return (
        <AiInput
          menuRegistrations={navigationMenus}
          onRichValueChange={(next) => {
            onRichValueChange(next);
            setCurrent(next);
          }}
          richValue={current}
        />
      );
    };
    render(<ControlledHarness />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const triggerText = Array.from(editor.childNodes).find(
      (node) => node.nodeType === Node.TEXT_NODE && node.textContent === "/"
    );
    if (!triggerText) throw new Error("expected restored trigger text");
    setCaret(triggerText, 1);
    fireEvent.input(editor, { data: "/", inputType: "insertText" });
    fireEvent.keyDown(editor, { key: "Enter" });

    const tokens = Array.from(
      editor.querySelectorAll<HTMLElement>("[data-ai-input-token]")
    );

    expect(tokens).toHaveLength(2);
    expect(tokens[0]).toHaveTextContent("Restored Alpha");
    expect(tokens[1]).toHaveTextContent("Alpha");
    expect(new Set(tokens.map((token) => token.dataset.aiInputToken)).size).toBe(2);

    fireEvent.click(tokens[1]!);
    fireEvent.keyDown(tokens[1]!, { key: "Delete" });

    const remainingTokens = Array.from(
      editor.querySelectorAll<HTMLElement>("[data-ai-input-token]")
    );
    expect(remainingTokens).toHaveLength(1);
    expect(remainingTokens[0]).toHaveTextContent("Restored Alpha");
    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({
        plainText: "/alpha ",
        tokens: [expect.objectContaining({ data: { source: "restored" } })],
      })
    );
  });

  it("preserves a newline adjacent to a deleted restored token", () => {
    const onRichValueChange = vi.fn();
    const value = createAiInputRichValue([
      richToken({ instanceId: "line-token" }),
      { type: "text", text: "\nNext line" },
    ]);
    render(<AiInput onRichValueChange={onRichValueChange} richValue={value} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const token = editor.querySelector<HTMLElement>("[data-ai-input-token]");
    if (!token) throw new Error("expected restored token");

    fireEvent.click(token);
    fireEvent.keyDown(token, { key: "Delete" });

    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ plainText: "\nNext line", tokens: [] })
    );
  });

  it("includes restored token plain text in the shouldOpen context", () => {
    const shouldOpen = vi.fn(() => true);
    const menu: AiInputMenuRegistration = {
      id: "plugins",
      trigger: "@",
      label: "Plugins",
      groups: [
        {
          id: "plugins",
          items: [{ id: "codex", label: "Codex" }],
        },
      ],
      shouldOpen,
    };
    const value = createAiInputRichValue([
      richToken({ instanceId: "context-token" }),
      { type: "text", text: " @" },
    ]);
    render(<AiInput menuRegistrations={[menu]} richValue={value} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const triggerText = Array.from(editor.childNodes).find(
      (node) => node.nodeType === Node.TEXT_NODE && node.textContent === "@"
    );
    if (!triggerText) throw new Error("expected restored trigger text");

    setCaret(triggerText, 1);
    fireEvent.keyUp(editor, { key: "@" });

    expect(shouldOpen).toHaveBeenLastCalledWith(
      expect.objectContaining({ plainText: "/alpha @" })
    );
  });

  it("uses metadata-only controlled richValue updates on the next edit", () => {
    const onRichValueChange = vi.fn();
    const initialToken = richToken({
      data: { revision: 1 },
      instanceId: "metadata-token",
    });
    const latestToken = richToken({
      data: { revision: 2 },
      instanceId: "metadata-token",
    });
    const initialValue = createAiInputRichValue([
      initialToken,
      { type: "text", text: " draft" },
    ]);
    const latestValue = createAiInputRichValue([
      latestToken,
      { type: "text", text: " draft" },
    ]);
    const { rerender } = render(
      <AiInput onRichValueChange={onRichValueChange} richValue={initialValue} />
    );

    rerender(<AiInput onRichValueChange={onRichValueChange} richValue={latestValue} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const draftText = Array.from(editor.childNodes).find(
      (node) => node.nodeType === Node.TEXT_NODE && node.textContent === "draft"
    ) as Text | undefined;
    if (!draftText) throw new Error("expected restored draft text");
    draftText.appendData("!");
    setCaret(draftText, draftText.length);
    fireEvent.input(editor, { data: "!", inputType: "insertText" });

    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({
        plainText: "/alpha draft!",
        tokens: [expect.objectContaining({ data: { revision: 2 } })],
      })
    );
  });

  it("inserts only plain text from rich content dropped into the editor", () => {
    const onRichValueChange = vi.fn();
    const onValueChange = vi.fn();
    const getData = vi.fn((format: string) =>
      format === "text/plain" ? "Dropped text" : "<strong>Dropped text</strong>"
    );
    render(
      <AiInput
        onRichValueChange={onRichValueChange}
        onValueChange={onValueChange}
        richText
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    setCaret(editor, 0);

    fireEvent.drop(editor, {
      dataTransfer: {
        getData,
        types: ["text/html", "text/plain"],
      },
    });

    expect(getData).toHaveBeenCalledWith("text/plain");
    expect(editor.querySelector("strong")).toBeNull();
    expect(onValueChange).toHaveBeenLastCalledWith("Dropped text");
    expect(onRichValueChange).toHaveBeenLastCalledWith(
      expect.objectContaining({ plainText: "Dropped text", tokens: [] })
    );
  });

  it("shows the drop overlay and disables actions while files are dragged over", () => {
    const onDropFiles = vi.fn();
    render(
      <AiInput
        onAccessPress={vi.fn()}
        onAttachPress={vi.fn()}
        onDropFiles={onDropFiles}
        onVoicePress={vi.fn()}
        showAccessButton
      />
    );
    const shell = getDropShell();
    const overlay = getDropOverlay();
    const textarea = screen.getByRole("textbox", { name: "AI prompt" });

    expect(textarea).toHaveAttribute("placeholder", "Do anything");
    expect(shell).not.toHaveAttribute("data-drop-active");
    expect(overlay).not.toHaveAttribute("data-drop-active");
    expect(overlay).toHaveTextContent("Drop anything here");
    expect(overlay).toHaveTextContent("Docs, images, videos and more");
    expect(screen.getByRole("button", { name: "Add attachment" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Full-access" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeEnabled();

    fireEvent.dragEnter(shell, { dataTransfer: createFilesDataTransfer() });

    expect(shell).toHaveAttribute("data-drop-active", "true");
    expect(overlay).toHaveAttribute("data-drop-active", "true");
    expect(shell.className).toMatch(/shadow-xs/);
    expect(shell.className).not.toMatch(/shadow-focus-brand/);
    expect(textarea).toHaveAttribute("placeholder", "Do anything");
    expect(screen.getByRole("button", { name: "Add attachment" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Full-access" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeDisabled();
  });

  it("keeps dropActive across nested dragenter/dragleave until the shell is left", () => {
    render(
      <AiInput
        onAccessPress={vi.fn()}
        onAttachPress={vi.fn()}
        onDropFiles={vi.fn()}
        onVoicePress={vi.fn()}
      />
    );
    const shell = getDropShell();
    const overlay = getDropOverlay();
    const child = screen.getByRole("textbox", { name: "AI prompt" });
    const transfer = createFilesDataTransfer();

    fireEvent.dragEnter(shell, { dataTransfer: transfer });
    expect(shell).toHaveAttribute("data-drop-active", "true");
    expect(overlay).toHaveAttribute("data-drop-active", "true");
    expect(child).toHaveAttribute("placeholder", "Do anything");

    fireEvent.dragEnter(child, { dataTransfer: transfer });
    fireEvent.dragLeave(child, { dataTransfer: transfer });
    expect(shell).toHaveAttribute("data-drop-active", "true");
    expect(overlay).toHaveAttribute("data-drop-active", "true");

    fireEvent.dragLeave(shell, { dataTransfer: transfer });
    expect(shell).not.toHaveAttribute("data-drop-active");
    expect(overlay).not.toHaveAttribute("data-drop-active");
    expect(child).toHaveAttribute("placeholder", "Do anything");
  });

  it("clears dropActive when dragleave omits file metadata", () => {
    render(<AiInput onDropFiles={vi.fn()} />);
    const shell = getDropShell();
    const overlay = getDropOverlay();

    fireEvent.dragEnter(shell, { dataTransfer: createFilesDataTransfer() });
    expect(shell).toHaveAttribute("data-drop-active", "true");

    fireEvent.dragLeave(shell, { dataTransfer: createEmptyDataTransfer() });
    expect(shell).not.toHaveAttribute("data-drop-active");
    expect(overlay).not.toHaveAttribute("data-drop-active");
  });

  it("calls onDropFiles with the DataTransfer and clears dropActive", () => {
    const onDropFiles = vi.fn();
    const transfer = createFilesDataTransfer([
      new File(["payload"], "note.txt", { type: "text/plain" }),
    ]);
    render(
      <AiInput
        onAccessPress={vi.fn()}
        onAttachPress={vi.fn()}
        onDropFiles={onDropFiles}
        onVoicePress={vi.fn()}
      />
    );
    const shell = getDropShell();
    const overlay = getDropOverlay();
    const textarea = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.dragEnter(shell, { dataTransfer: transfer });
    expect(shell).toHaveAttribute("data-drop-active", "true");
    expect(overlay).toHaveAttribute("data-drop-active", "true");
    expect(textarea).toHaveAttribute("placeholder", "Do anything");

    fireEvent.drop(shell, { dataTransfer: transfer });

    expect(onDropFiles).toHaveBeenCalledOnce();
    expect(onDropFiles.mock.calls[0]?.[0]).toMatchObject({
      types: expect.arrayContaining(["Files"]),
    });
    expect(shell).not.toHaveAttribute("data-drop-active");
    expect(overlay).not.toHaveAttribute("data-drop-active");
    expect(textarea).toHaveAttribute("placeholder", "Do anything");
  });

  it("does not activate the drop overlay for text-only drags", () => {
    render(
      <AiInput
        onAccessPress={vi.fn()}
        onAttachPress={vi.fn()}
        onDropFiles={vi.fn()}
        onVoicePress={vi.fn()}
      />
    );
    const shell = getDropShell();
    const overlay = getDropOverlay();
    const textarea = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.dragEnter(shell, {
      dataTransfer: {
        types: ["text/plain"],
        getData: () => "hello",
        files: [],
      },
    });

    expect(shell).not.toHaveAttribute("data-drop-active");
    expect(overlay).not.toHaveAttribute("data-drop-active");
    expect(textarea).toHaveAttribute("placeholder", "Do anything");
  });

  it.each([false, true])(
    "attaches context-menu clipboard files without changing text (rich=%s)",
    async (richText) => {
      const file = new File(["png"], "shot.png", { type: "image/png" });
      const readText = vi.fn(async () => "must not insert");
      const onPasteFiles = vi.fn();
      const onValueChange = vi.fn();
      const original = globalThis.DataTransfer;
      globalThis.DataTransfer = class {
        files: File[] = [];
        items = { add: (item: File) => this.files.push(item) };
      } as unknown as typeof DataTransfer;
      try {
        render(
          <AiInput
            defaultValue="keep draft"
            richText={richText}
            clipboard={{ readFiles: async () => [file], readText, writeText: vi.fn() }}
            onPasteFiles={onPasteFiles}
            onValueChange={onValueChange}
          />
        );
        const editor = screen.getByRole("textbox", { name: "AI prompt" });
        fireEvent.contextMenu(editor);
        await userEvent.click(screen.getByRole("menuitem", { name: "Paste" }));
        await waitFor(() => expect(onPasteFiles).toHaveBeenCalledOnce());
        expect(onPasteFiles.mock.calls[0]?.[0].files).toEqual([file]);
        expect(readText).not.toHaveBeenCalled();
        expect(onValueChange).not.toHaveBeenCalled();
      } finally {
        globalThis.DataTransfer = original;
      }
    }
  );

  it.each([false, true])(
    "keeps context-menu text paste when image reads are denied (rich=%s)",
    async (richText) => {
      const onPasteFiles = vi.fn();
      const onValueChange = vi.fn();
      render(
        <AiInput
          richText={richText}
          onPasteFiles={onPasteFiles}
          onValueChange={onValueChange}
          clipboard={{
            readFiles: async () => {
              throw new Error("Denied");
            },
            readText: async () => "plain text",
            writeText: vi.fn(),
          }}
        />
      );
      fireEvent.contextMenu(screen.getByRole("textbox", { name: "AI prompt" }));
      await userEvent.click(screen.getByRole("menuitem", { name: "Paste" }));
      await waitFor(() => expect(onValueChange).toHaveBeenCalledWith("plain text"));
      expect(onPasteFiles).not.toHaveBeenCalled();
    }
  );

  it("routes a paste carrying files to onPasteFiles instead of the prompt", () => {
    const onPasteFiles = vi.fn();
    const onValueChange = vi.fn();
    render(
      <AiInput onPasteFiles={onPasteFiles} onValueChange={onValueChange} richText />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    setCaret(editor, 0);

    fireEvent.paste(editor, {
      clipboardData: createFilesDataTransfer([
        new File(["payload"], "note.txt", { type: "text/plain" }),
      ]),
    });

    expect(onPasteFiles).toHaveBeenCalledOnce();
    expect(onPasteFiles.mock.calls[0]?.[0]).toMatchObject({
      types: expect.arrayContaining(["Files"]),
    });
    // The paste is consumed as an attach, so any text riding along with the
    // files stays out of the prompt.
    expect(onValueChange).not.toHaveBeenCalled();
    expect(editor).toHaveTextContent("");
  });

  it("leaves a text-only paste to the editor when onPasteFiles is set", () => {
    const onPasteFiles = vi.fn();
    const onValueChange = vi.fn();
    render(
      <AiInput onPasteFiles={onPasteFiles} onValueChange={onValueChange} richText />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    setCaret(editor, 0);

    fireEvent.paste(editor, {
      clipboardData: { ...createEmptyDataTransfer(), getData: () => "pasted text" },
    });

    expect(onPasteFiles).not.toHaveBeenCalled();
    expect(onValueChange).toHaveBeenCalledWith("pasted text");
  });

  it("lets a caller onPaste preempt file intake", () => {
    const onPaste = vi.fn((event: { preventDefault: () => void }) => {
      event.preventDefault();
    });
    const onPasteFiles = vi.fn();
    render(<AiInput onPaste={onPaste} onPasteFiles={onPasteFiles} richText />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.paste(editor, { clipboardData: createFilesDataTransfer() });

    expect(onPaste).toHaveBeenCalledOnce();
    expect(onPasteFiles).not.toHaveBeenCalled();
  });

  it("routes a paste carrying files to onPasteFiles in plain mode", () => {
    const onPasteFiles = vi.fn();
    const onValueChange = vi.fn();
    render(<AiInput onPasteFiles={onPasteFiles} onValueChange={onValueChange} />);
    const textarea = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.paste(textarea, { clipboardData: createFilesDataTransfer() });

    expect(onPasteFiles).toHaveBeenCalledOnce();
    expect(onValueChange).not.toHaveBeenCalled();
  });

  it("exposes menu state through aria-expanded", () => {
    render(<AiInput menuRegistrations={navigationMenus} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    expect(editor).toHaveAttribute("aria-expanded", "false");
    typeIntoRichEditor(editor, "/");
    expect(editor).toHaveAttribute("aria-expanded", "true");

    fireEvent.keyDown(editor, { key: "Escape" });
    fireEvent.keyUp(editor, { key: "Escape" });
    expect(editor).toHaveAttribute("aria-expanded", "false");
  });

  it("forwards inherited textarea attributes and caller events in rich mode", () => {
    const onBlur = vi.fn();
    const onCompositionEnd = vi.fn();
    const onCompositionStart = vi.fn();
    const onFocus = vi.fn();
    const onKeyDown = vi.fn();
    const onKeyUp = vi.fn();
    const onPaste = vi.fn();
    render(
      <AiInput
        aria-describedby="prompt-help"
        data-surface="conversation-composer"
        id="conversation-prompt"
        onBlur={onBlur}
        onCompositionEnd={onCompositionEnd}
        onCompositionStart={onCompositionStart}
        onFocus={onFocus}
        onKeyDown={onKeyDown}
        onKeyUp={onKeyUp}
        onPaste={onPaste}
        richText
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    expect(editor).toHaveAttribute("id", "conversation-prompt");
    expect(editor).toHaveAttribute("data-surface", "conversation-composer");
    expect(editor).toHaveAttribute("aria-describedby", "prompt-help");

    fireEvent.focus(editor);
    fireEvent.compositionStart(editor, { data: "中" });
    fireEvent.compositionEnd(editor, { data: "中" });
    fireEvent.keyDown(editor, { key: "ArrowLeft" });
    fireEvent.keyUp(editor, { key: "ArrowLeft" });
    setCaret(editor, 0);
    fireEvent.paste(editor, {
      clipboardData: { getData: () => "pasted text" },
    });
    fireEvent.blur(editor);

    expect(onFocus).toHaveBeenCalledOnce();
    expect(onCompositionStart).toHaveBeenCalledOnce();
    expect(onCompositionEnd).toHaveBeenCalledOnce();
    expect(onKeyDown).toHaveBeenCalledOnce();
    expect(onKeyUp).toHaveBeenCalledOnce();
    expect(onPaste).toHaveBeenCalledOnce();
    expect(onBlur).toHaveBeenCalledOnce();
  });

  it("types common element handlers honestly for both editor modes", () => {
    expectTypeOf<
      Parameters<NonNullable<AiInputProps["onKeyDown"]>>[0]["currentTarget"]
    >().toEqualTypeOf<EventTarget & HTMLElement>();
  });

  it("honors caller keydown cancellation in rich mode", () => {
    const onKeyDown = vi.fn((event: React.KeyboardEvent<HTMLElement>) => {
      event.preventDefault();
    });
    const onSubmit = vi.fn();
    render(
      <AiInput
        defaultValue="Do not submit"
        onKeyDown={onKeyDown}
        onSubmit={onSubmit}
        richText
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.keyDown(editor, { key: "Enter" });

    expect(onKeyDown).toHaveBeenCalledOnce();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("clears composition state even when the caller cancels compositionend", () => {
    const onCompositionEnd = vi.fn((event: React.CompositionEvent<HTMLElement>) => {
      event.preventDefault();
    });
    render(
      <AiInput
        menuRegistrations={navigationMenus}
        onCompositionEnd={onCompositionEnd}
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    editor.textContent = "/old";
    const initialTriggerText = editor.firstChild;
    if (!initialTriggerText) throw new Error("expected initial trigger text");
    setCaret(initialTriggerText, 4);
    fireEvent.input(editor, { data: "d", inputType: "insertText" });

    fireEvent.compositionStart(editor, { data: "/" });
    editor.textContent = "/";
    const composedTriggerText = editor.firstChild;
    if (!composedTriggerText) throw new Error("expected composed trigger text");
    setCaret(composedTriggerText, 1);
    fireEvent.input(editor, { data: "/", inputType: "insertCompositionText" });
    fireEvent.compositionEnd(editor, { data: "/" });
    fireEvent.keyUp(editor, { key: "/" });

    expect(onCompositionEnd).toHaveBeenCalledOnce();
    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();
  });

  it("keeps rich readOnly prompts immutable and focusable", () => {
    const onRichValueChange = vi.fn();
    const onRichSubmit = vi.fn();
    const value = createAiInputRichValue([
      richToken({ instanceId: "readonly-token" }),
      { type: "text", text: " draft" },
    ]);
    render(
      <AiInput
        onRichSubmit={onRichSubmit}
        onRichValueChange={onRichValueChange}
        readOnly
        richValue={value}
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const token = editor.querySelector<HTMLElement>("[data-ai-input-token]");
    if (!token) throw new Error("expected restored token");

    expect(editor).toHaveAttribute("contenteditable", "false");
    expect(editor).toHaveAttribute("aria-readonly", "true");
    expect(editor).toHaveAttribute("tabindex", "0");

    fireEvent.click(token);
    fireEvent.keyDown(token, { key: "Delete" });
    expect(editor.querySelector("[data-ai-input-token]")).toBe(token);
    expect(onRichValueChange).not.toHaveBeenCalled();

    fireEvent.keyDown(editor, { key: "Enter" });
    expect(onRichSubmit).toHaveBeenCalledWith(value);
  });

  it("enforces maxLength against the rich plain-text value", () => {
    const onRichValueChange = vi.fn();
    const onValueChange = vi.fn();
    render(
      <AiInput
        defaultValue="12345"
        maxLength={5}
        onRichValueChange={onRichValueChange}
        onValueChange={onValueChange}
        richText
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const text = editor.firstChild as Text | null;
    if (!text) throw new Error("expected initial rich text");
    text.appendData("6");
    setCaret(text, text.length);

    fireEvent.input(editor, { data: "6", inputType: "insertText" });

    expect(editor).toHaveTextContent(/^12345$/);
    expect(onValueChange).not.toHaveBeenCalledWith("123456");
    expect(onRichValueChange).not.toHaveBeenCalledWith(
      expect.objectContaining({ plainText: "123456" })
    );
  });

  it("preserves rich tokens when rolling back an over-limit paste", () => {
    const onRichValueChange = vi.fn();
    const onValueChange = vi.fn();
    render(
      <AiInput
        maxLength={7}
        menuRegistrations={navigationMenus}
        onRichValueChange={onRichValueChange}
        onValueChange={onValueChange}
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    typeIntoRichEditor(editor, "/");
    fireEvent.keyDown(editor, { key: "Enter" });
    expect(editor.querySelector("[data-ai-input-token]")).toHaveTextContent("Alpha");

    fireEvent.paste(editor, {
      clipboardData: { getData: () => "too long" },
    });

    expect(editor).toHaveTextContent(/^Alpha$/);
    expect(editor.querySelector("[data-ai-input-token]")).toHaveTextContent("Alpha");
    expect(onValueChange).not.toHaveBeenCalledWith("/alpha too long");
    expect(onRichValueChange).not.toHaveBeenCalledWith(
      expect.objectContaining({ plainText: "/alpha too long" })
    );
  });

  it("allows an initially over-limit rich value to be shortened", () => {
    const onValueChange = vi.fn();
    render(
      <AiInput
        defaultValue="1234567890"
        maxLength={5}
        onValueChange={onValueChange}
        richText
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const text = editor.firstChild as Text | null;
    if (!text) throw new Error("expected over-limit initial text");
    text.deleteData(text.length - 1, 1);
    setCaret(text, text.length);

    fireEvent.input(editor, { inputType: "deleteContentBackward" });

    expect(editor).toHaveTextContent(/^123456789$/);
    expect(onValueChange).toHaveBeenLastCalledWith("123456789");
  });

  it("opens the text-edit context menu at the pointer in rich mode", async () => {
    const user = userEvent.setup();
    render(<AiInput defaultValue="Hello world" richText />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const textNode = editor.firstChild;
    if (!textNode) throw new Error("expected editor text");
    setTextRange(textNode, 0, 5);

    vi.spyOn(editor, "getBoundingClientRect").mockReturnValue({
      x: 100,
      y: 200,
      top: 200,
      right: 500,
      bottom: 244,
      left: 100,
      width: 400,
      height: 44,
      toJSON: () => ({}),
    });

    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 220,
      clientY: 218,
    });
    fireEvent(editor, contextMenuEvent);

    expect(contextMenuEvent.defaultPrevented).toBe(true);
    expect(editor).toHaveAttribute("data-context-menu-open", "true");
    expect(screen.getByRole("menuitem", { name: "Copy" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Paste" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Cut" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Select All" })).toBeInTheDocument();
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-animation", "anchor");
    expect(getMenuPointerOffsets(editor, 220, 218)).toEqual({
      crossOffset: 18,
      offset: expect.any(Number),
    });

    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
    expect(editor).toHaveAttribute("data-context-menu-open", "false");
    expect(editor).toHaveFocus();
  });

  it("disables cut and copy when the rich selection is collapsed", () => {
    render(<AiInput defaultValue="Hello world" richText />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const textNode = editor.firstChild;
    if (!textNode) throw new Error("expected editor text");
    setCaret(textNode, 2);

    fireEvent.contextMenu(editor);

    expect(screen.getByRole("menuitem", { name: "Cut" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
    expect(screen.getByRole("menuitem", { name: "Copy" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
    expect(screen.getByRole("menuitem", { name: "Paste" })).not.toHaveAttribute(
      "aria-disabled",
      "true"
    );
  });

  it("cuts, copies, pastes, and selects all from the rich edit menu", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    const readText = vi.fn().mockResolvedValue("pasted");

    const onValueChange = vi.fn();
    render(
      <AiInput
        clipboard={{ readText, writeText }}
        defaultValue="Hello world"
        onValueChange={onValueChange}
        richText
      />
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const textNode = editor.firstChild;
    if (!textNode) throw new Error("expected editor text");
    setTextRange(textNode, 0, 5);

    fireEvent.contextMenu(editor);
    await user.click(screen.getByRole("menuitem", { name: "Copy" }));
    expect(writeText).toHaveBeenCalledWith("Hello");

    setTextRange(editor.firstChild as Text, 0, 5);
    fireEvent.contextMenu(editor);
    await user.click(screen.getByRole("menuitem", { name: "Cut" }));
    await waitFor(() => expect(onValueChange).toHaveBeenCalledWith(" world"));
    expect(writeText).toHaveBeenLastCalledWith("Hello");

    setCaret(editor.firstChild as Text, 0);
    fireEvent.contextMenu(editor);
    await user.click(screen.getByRole("menuitem", { name: "Paste" }));
    await waitFor(() =>
      expect(onValueChange).toHaveBeenCalledWith(expect.stringContaining("pasted"))
    );
    expect(readText).toHaveBeenCalled();

    fireEvent.contextMenu(editor);
    await user.click(screen.getByRole("menuitem", { name: "Select All" }));
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
    await new Promise<void>((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
    });
    const selection = window.getSelection();
    expect(selection?.isCollapsed).toBe(false);
    expect(selection?.toString()).toBe(editor.textContent);
  });

  it("does not open the custom edit menu when the rich editor is disabled", () => {
    render(<AiInput defaultValue="Hello" disabled richText />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
    });
    fireEvent(editor, contextMenuEvent);

    expect(contextMenuEvent.defaultPrevented).toBe(false);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(editor).toHaveAttribute("data-context-menu-open", "false");
  });

  it("opens the text-edit context menu for the textarea fallback", async () => {
    const user = userEvent.setup();
    render(<AiInput defaultValue="Plain prompt" />);
    const textarea = screen.getByRole("textbox", {
      name: "AI prompt",
    }) as HTMLTextAreaElement;
    textarea.focus();
    textarea.setSelectionRange(0, 5);

    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 40,
      clientY: 12,
    });
    fireEvent(textarea, contextMenuEvent);

    expect(contextMenuEvent.defaultPrevented).toBe(true);
    expect(textarea).toHaveAttribute("data-context-menu-open", "true");
    expect(screen.getByRole("menuitem", { name: "Cut" })).toBeInTheDocument();

    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
    expect(textarea).toHaveFocus();
  });

  it("keeps textarea context-menu Paste within maxLength", async () => {
    const user = userEvent.setup();
    const onValueChange = vi.fn();
    const readText = vi.fn(async () => "6789");
    render(
      <AiInput
        clipboard={{ readText, writeText: vi.fn() }}
        defaultValue="12345"
        maxLength={5}
        onValueChange={onValueChange}
      />
    );
    const textarea = screen.getByRole("textbox", {
      name: "AI prompt",
    }) as HTMLTextAreaElement;
    textarea.focus();
    textarea.setSelectionRange(3, 5);

    fireEvent.contextMenu(textarea);
    await user.click(screen.getByRole("menuitem", { name: "Paste" }));

    await waitFor(() => expect(onValueChange).toHaveBeenLastCalledWith("12367"));
    expect(textarea).toHaveValue("12367");
    expect(readText).toHaveBeenCalledOnce();
    await waitFor(() => {
      expect(textarea.selectionStart).toBe(5);
      expect(textarea.selectionEnd).toBe(5);
    });
  });
});

const richMenus: AiInputMenuRegistration[] = [
  {
    id: "skills",
    trigger: "/",
    label: "Skills",
    groups: [
      {
        id: "skills",
        items: [
          {
            id: "code-review",
            label: "Code Review",
            description: "Review pull requests",
          },
        ],
      },
    ],
  },
  {
    id: "plugins",
    trigger: "@",
    label: "Plugins",
    groups: [
      {
        id: "plugins",
        items: [{ id: "codex", label: "Codex", description: "Write code" }],
      },
    ],
  },
];

const navigationMenus: AiInputMenuRegistration[] = [
  {
    id: "skills",
    trigger: "/",
    label: "Skills",
    groups: [
      {
        id: "skills",
        items: [
          { id: "alpha", label: "Alpha" },
          { id: "beta", label: "Beta" },
        ],
      },
    ],
  },
];

function richToken(
  overrides: Partial<AiInputRichTokenSegment> = {}
): AiInputRichTokenSegment {
  return {
    type: "token",
    instanceId: "alpha-token",
    menuId: "skills",
    itemId: "alpha",
    trigger: "/",
    label: "Alpha",
    plainText: "/alpha",
    ...overrides,
  };
}

function createFilesDataTransfer(
  files: File[] = [new File(["x"], "a.txt", { type: "text/plain" })]
) {
  const items = files.map((file) => ({
    kind: "file" as const,
    type: file.type,
    getAsFile: () => file,
    webkitGetAsEntry: () => null,
  }));
  return {
    types: ["Files"],
    files,
    items,
    dropEffect: "none",
    effectAllowed: "all" as const,
    getData: () => "",
    setData: () => {},
    clearData: () => {},
    setDragImage: () => {},
  };
}

function createEmptyDataTransfer() {
  return {
    types: [],
    files: [],
    items: [],
    dropEffect: "none",
    effectAllowed: "all" as const,
    getData: () => "",
    setData: () => {},
    clearData: () => {},
    setDragImage: () => {},
  };
}

function getDropShell() {
  return screen.getByTestId("ai-input-shell");
}

function getDropOverlay() {
  return screen.getByTestId("ai-input-drop-overlay");
}

/** Lets the composer's next-frame measurement run. */
async function nextFrame() {
  await act(
    () =>
      new Promise<void>((resolve) => {
        requestAnimationFrame(() => resolve());
      })
  );
}

function typeIntoRichEditor(editor: HTMLElement, text: string) {
  editor.textContent = text;
  const textNode = editor.firstChild;
  if (!textNode) throw new Error("expected editor text node");
  setCaret(textNode, text.length);
  fireEvent.input(editor, { inputType: "insertText", data: text.at(-1) });
}

function setCaret(node: Node, offset: number) {
  const selection = window.getSelection();
  const range = document.createRange();
  range.setStart(node, offset);
  range.collapse(true);
  selection?.removeAllRanges();
  selection?.addRange(range);
}

function setTextRange(node: Node, start: number, end: number) {
  const selection = window.getSelection();
  const range = document.createRange();
  range.setStart(node, start);
  range.setEnd(node, end);
  selection?.removeAllRanges();
  selection?.addRange(range);
}

const browseMenus = (
  onGamma: () => void,
  files: { id: string; label: string; action?: () => void }[] = [
    { id: "a", label: "alpha.pdf" },
    { id: "b", label: "beta.png" },
    { id: "c", label: "gamma.txt", action: onGamma },
  ]
): AiInputMenuRegistration[] => [
  {
    id: "mentions",
    trigger: "@",
    label: "Mentions",
    maxItems: Number.POSITIVE_INFINITY,
    groups: [
      {
        id: "drive",
        label: "Drive",
        items: files,
        limit: 2,
        browse: {
          label: "View more",
          title: "Drive",
          searchPlaceholder: "Search files",
          emptyLabel: "No files",
          noResultsLabel: "No results found",
          groups: [{ id: "folder-a", label: "Folder A", items: files }],
        },
      },
    ],
  },
];

describe("AiInput browse panel", () => {
  it("steps into the browse panel with ArrowRight on View more, searches, and selects there", async () => {
    const onGamma = vi.fn();
    render(<AiInput menuRegistrations={browseMenus(onGamma)} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "@");
    const list = screen.getByRole("listbox", { name: "Mentions" });
    expect(within(list).getByRole("option", { name: "alpha.pdf" })).toBeVisible();
    expect(within(list).getByRole("option", { name: "beta.png" })).toBeVisible();
    expect(within(list).queryByRole("option", { name: "gamma.txt" })).toBeNull();
    const viewMore = within(list).getByRole("option", { name: "View more" });

    // ArrowRight on any other row leaves the caret alone.
    fireEvent.keyDown(editor, { key: "ArrowRight" });
    expect(screen.queryByRole("dialog", { name: "Drive" })).toBeNull();

    fireEvent.keyDown(editor, { key: "ArrowDown" });
    fireEvent.keyDown(editor, { key: "ArrowDown" });
    expect(viewMore).toHaveAttribute("aria-selected", "true");
    fireEvent.keyDown(editor, { key: "ArrowRight" });

    const panel = screen.getByRole("dialog", { name: "Drive" });
    const search = within(panel).getByRole("combobox", { name: "Drive" });
    await waitFor(() => expect(search).toHaveFocus());
    expect(within(panel).getByText("Folder A")).toBeVisible();
    expect(within(panel).getByRole("option", { name: "gamma.txt" })).toBeVisible();
    // The trigger text stays in the editor under the panel.
    expect(editor).toHaveTextContent("@");

    fireEvent.change(search, { target: { value: "gam" } });
    await waitFor(() =>
      expect(within(panel).queryByRole("option", { name: "alpha.pdf" })).toBeNull()
    );
    expect(within(panel).getByRole("option", { name: "gamma.txt" })).toHaveAttribute(
      "aria-selected",
      "true"
    );

    fireEvent.change(search, { target: { value: "zzz" } });
    await waitFor(() =>
      expect(screen.getByTestId("ai-input-menu-browse-no-results")).toHaveTextContent(
        "No results found"
      )
    );

    fireEvent.change(search, { target: { value: "" } });
    await waitFor(() =>
      expect(within(panel).getByRole("option", { name: "alpha.pdf" })).toBeVisible()
    );
    fireEvent.keyDown(search, { key: "ArrowUp" });
    expect(within(panel).getByRole("option", { name: "gamma.txt" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    fireEvent.keyDown(search, { key: "Enter" });

    // An action row runs after the trigger text is gone and the menu closed.
    expect(onGamma).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("dialog", { name: "Drive" })).toBeNull();
    expect(editor).toHaveTextContent("");
    expect(editor).toHaveFocus();
  });

  it("steps back to the list on Escape with the trigger and caret intact", async () => {
    render(<AiInput menuRegistrations={browseMenus(vi.fn())} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "@al");
    fireEvent.mouseDown(screen.getByRole("option", { name: "View more" }));
    const panel = screen.getByRole("dialog", { name: "Drive" });
    const search = within(panel).getByRole("combobox", { name: "Drive" });
    await waitFor(() => expect(search).toHaveFocus());
    // The query typed so far carries into the search.
    expect(search).toHaveValue("al");
    expect(within(panel).queryByRole("option", { name: "beta.png" })).toBeNull();

    fireEvent.keyDown(search, { key: "Escape" });
    const list = screen.getByRole("listbox", { name: "Mentions" });
    expect(within(list).getByRole("option", { name: "alpha.pdf" })).toBeVisible();
    expect(editor).toHaveFocus();
    expect(editor).toHaveTextContent("@al");
    const selection = window.getSelection();
    expect(selection?.isCollapsed).toBe(true);
    expect(selection?.anchorNode?.textContent).toBe("@al");
    expect(selection?.anchorOffset).toBe(3);

    // The second Escape closes the menu, as it always did.
    fireEvent.keyDown(editor, { key: "Escape" });
    expect(screen.queryByRole("listbox", { name: "Mentions" })).toBeNull();
  });

  it("steps back to the list from the back chevron", async () => {
    render(<AiInput menuRegistrations={browseMenus(vi.fn())} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "@");
    fireEvent.mouseDown(screen.getByRole("option", { name: "View more" }));
    const panel = screen.getByRole("dialog", { name: "Drive" });
    await waitFor(() =>
      expect(within(panel).getByRole("combobox", { name: "Drive" })).toHaveFocus()
    );

    fireEvent.click(within(panel).getByRole("button", { name: "Back" }));
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    expect(screen.queryByRole("dialog", { name: "Drive" })).toBeNull();
    expect(editor).toHaveFocus();
    expect(editor).toHaveTextContent("@");
  });

  it("closes the menu when focus leaves the browse panel for elsewhere", async () => {
    render(
      <>
        <AiInput menuRegistrations={browseMenus(vi.fn())} />
        <button type="button">Elsewhere</button>
      </>
    );
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "@");
    fireEvent.mouseDown(screen.getByRole("option", { name: "View more" }));
    const search = screen.getByRole("combobox", { name: "Drive" });
    await waitFor(() => expect(search).toHaveFocus());

    const elsewhere = screen.getByRole("button", { name: "Elsewhere" });
    act(() => elsewhere.focus());
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: "Drive" })).toBeNull()
    );
    expect(screen.queryByRole("listbox", { name: "Mentions" })).toBeNull();
  });

  it("centers No files for a source with nothing in it", async () => {
    render(<AiInput menuRegistrations={browseMenus(vi.fn(), [])} />);
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoRichEditor(editor, "@");
    fireEvent.mouseDown(screen.getByRole("option", { name: "View more" }));
    expect(screen.getByTestId("ai-input-menu-browse-empty")).toHaveTextContent(
      "No files"
    );
  });
});
