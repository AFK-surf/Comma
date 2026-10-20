import { useState } from "react";
import { expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, within } from "@comma/test-utils/render";
import { AiInput } from "../composer/AiInput";
import {
  createAiInputRichValue,
  type AiInputMenuRegistration,
  type AiInputRichValue,
} from "../richText";

const mentionMenu = (
  onAddFiles: () => void,
  routinesLoading = false
): AiInputMenuRegistration => ({
  id: "mentions",
  trigger: "@",
  label: "Mentions",
  maxItems: Number.POSITIVE_INFINITY,
  groups: [
    {
      id: "add",
      label: "Add",
      items: [
        {
          id: "add-files-or-folders",
          label: "Add files or folders",
          keywords: ["upload", "attach"],
          action: onAddFiles,
        },
      ],
    },
    {
      id: "tasks",
      label: "Tasks",
      items: [
        {
          id: "task:cnv1_e2e",
          label: "Fix login flow",
          plainText: "[Fix login flow](comma:task/cnv1_e2e)",
        },
      ],
    },
    ...(routinesLoading
      ? [{ id: "routines", label: "Routines", status: "loading" as const, items: [] }]
      : []),
  ],
});

function RichPrompt({
  menus,
  onRichSubmit,
  onRichValue,
}: {
  menus: AiInputMenuRegistration[];
  onRichSubmit?: (value: AiInputRichValue) => void;
  onRichValue?: (value: AiInputRichValue) => void;
}) {
  const [value, setValue] = useState(() => createAiInputRichValue([]));
  return (
    <AiInput
      aria-label="Rich AI prompt"
      menuRegistrations={menus}
      {...(onRichSubmit ? { onRichSubmit } : {})}
      onRichValueChange={(next) => {
        setValue(next);
        onRichValue?.(next);
      }}
      richValue={value}
      sendLabel="Submit rich prompt"
      size="small"
    />
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

function AsyncPrompt({ menus }: { menus: AiInputMenuRegistration[] }) {
  const [value, setValue] = useState("review this");
  return (
    <AiInput
      aria-label="Async skills prompt"
      menuRegistrations={menus}
      onValueChange={setValue}
      richText
      value={value}
    />
  );
}

const editor = () => screen.getByRole("textbox", { name: "Rich AI prompt" });
const menu = () => screen.getByRole("listbox", { name: "Mentions" });

it("lists the @ panel's sections, runs the Add action, and clears the trigger", () => {
  const addFiles = vi.fn();
  let latest: AiInputRichValue | undefined;
  render(
    <RichPrompt
      menus={[mentionMenu(addFiles, true)]}
      onRichValue={(value) => (latest = value)}
    />
  );
  typeIntoRichEditor(editor(), "Use @");
  expect(within(menu()).getByText("Add")).toBeVisible();
  expect(within(menu()).getByText("Tasks")).toBeVisible();
  // The routines section is still indexing, so the panel keeps one shimmer row.
  expect(within(menu()).getByTestId("ai-input-menu-searching")).toHaveTextContent(
    "Searching..."
  );
  expect(
    within(menu()).getByRole("option", { name: "Add files or folders" })
  ).toHaveAttribute("aria-selected", "true");
  fireEvent.keyDown(editor(), { key: "Enter" });
  expect(screen.queryByRole("listbox", { name: "Mentions" })).toBeNull();
  expect(addFiles).toHaveBeenCalledOnce();
  expect(latest?.plainText).toBe("Use ");
});

it("shows No results and lets Enter submit the typed text", () => {
  const onRichSubmit = vi.fn();
  render(<RichPrompt menus={[mentionMenu(vi.fn())]} onRichSubmit={onRichSubmit} />);
  typeIntoRichEditor(editor(), "@zzzz");
  expect(within(menu()).getByTestId("ai-input-menu-no-results")).toHaveTextContent(
    "No results"
  );
  fireEvent.keyDown(editor(), { key: "Enter" });
  expect(onRichSubmit).toHaveBeenCalledOnce();
  expect(onRichSubmit.mock.calls[0]![0].plainText).toBe("@zzzz");
});

it("continues arrow-key navigation from the hovered mention", () => {
  render(<RichPrompt menus={[mentionMenu(vi.fn())]} />);
  typeIntoRichEditor(editor(), "@");
  const first = within(menu()).getByRole("option", { name: "Add files or folders" });
  const second = within(menu()).getByRole("option", { name: "Fix login flow" });
  fireEvent.pointerMove(second);
  fireEvent.mouseMove(second);
  expect(second).toHaveAttribute("aria-selected", "true");
  fireEvent.keyDown(editor(), { key: "ArrowUp" });
  expect(first).toHaveAttribute("aria-selected", "true");
  fireEvent.keyDown(editor(), { key: "ArrowDown" });
  expect(second).toHaveAttribute("aria-selected", "true");
});

it("inserts a Task mention token that submits the comma:task link", () => {
  const onRichSubmit = vi.fn();
  render(<RichPrompt menus={[mentionMenu(vi.fn())]} onRichSubmit={onRichSubmit} />);
  typeIntoRichEditor(editor(), "Check @fix");
  expect(
    within(menu()).getByRole("option", { name: "Fix login flow" })
  ).toHaveAttribute("aria-selected", "true");
  fireEvent.keyDown(editor(), { key: "Enter" });
  expect(screen.queryByRole("listbox", { name: "Mentions" })).toBeNull();
  expect(editor().querySelector("[data-ai-input-token]")).toHaveTextContent(
    "Fix login flow"
  );
  fireEvent.click(screen.getByRole("button", { name: "Submit rich prompt" }));
  const submitted = onRichSubmit.mock.calls[0]![0] as AiInputRichValue;
  expect(submitted.plainText).toBe("Check [Fix login flow](comma:task/cnv1_e2e) ");
  expect(submitted.tokens.map((token) => token.itemId)).toEqual(["task:cnv1_e2e"]);
});

it("keeps the focused editor and its caret when menus load", () => {
  const skills: AiInputMenuRegistration[] = [
    {
      id: "skills",
      trigger: "/",
      label: "Skills",
      groups: [{ id: "skills", items: [{ id: "alpha", label: "Alpha" }] }],
    },
  ];
  const view = render(<AsyncPrompt menus={[]} />);
  const before = screen.getByRole("textbox", { name: "Async skills prompt" });
  act(() => {
    before.focus();
    setCaret(before.firstChild!, 6);
  });
  view.rerender(<AsyncPrompt menus={skills} />);
  const after = screen.getByRole("textbox", { name: "Async skills prompt" });
  expect(after).toBe(before);
  expect(after).toHaveFocus();
  const selection = window.getSelection()!;
  expect(selection.anchorNode && after.contains(selection.anchorNode)).toBe(true);
  expect(selection.anchorOffset).toBe(6);
});

it("starts voice recording with the advertised Control+D shortcut", () => {
  const onVoicePress = vi.fn();
  render(<AiInput onVoicePress={onVoicePress} />);
  const prompt = screen.getByRole("textbox", { name: "AI prompt" });
  act(() => prompt.focus());
  fireEvent.keyDown(prompt, { ctrlKey: true, key: "d" });
  expect(onVoicePress).toHaveBeenCalledOnce();
  expect(
    document.querySelector('[data-slot="ai-input-voice-recording"]')
  ).toHaveFocus();
});

it("keeps voice keyboard actions inside the active recorder", async () => {
  const voice = {
    onVoicePress: vi.fn(),
    onVoiceCancel: vi.fn(),
    onVoiceConfirm: vi.fn(),
  };
  const onRichSubmit = vi.fn();
  render(
    <>
      <AiInput {...voice} />
      <RichPrompt menus={[]} onRichSubmit={onRichSubmit} />
    </>
  );
  fireEvent.click(screen.getAllByRole("button", { name: "Voice input" })[0]!);
  const recording = document.querySelector('[data-slot="ai-input-voice-recording"]');
  expect(recording).toHaveFocus();

  // Enter in another composer submits there and leaves the recorder alone.
  typeIntoRichEditor(editor(), "submit from another composer");
  fireEvent.keyDown(editor(), { key: "Enter" });
  expect(onRichSubmit).toHaveBeenCalledOnce();
  expect(onRichSubmit.mock.calls[0]![0].plainText).toBe("submit from another composer");
  expect(recording).toBeInTheDocument();
  expect(voice.onVoiceConfirm).not.toHaveBeenCalled();
  expect(voice.onVoiceCancel).not.toHaveBeenCalled();
});

it.each(["Google Inc.", "Apple Computer, Inc."])(
  "confirms an IME composition before an immediate submit (%s)",
  (vendor) => {
    vi.spyOn(navigator, "vendor", "get").mockReturnValue(vendor);
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"));
    try {
      const onRichSubmit = vi.fn();
      render(<RichPrompt menus={[]} onRichSubmit={onRichSubmit} />);
      typeIntoRichEditor(editor(), "你好");
      fireEvent.compositionStart(editor(), { data: "" });
      fireEvent.keyDown(editor(), { key: "Enter", keyCode: 229, isComposing: true });
      expect(onRichSubmit).not.toHaveBeenCalled();
      fireEvent.compositionEnd(editor(), { data: "你好" });
      fireEvent.keyDown(editor(), { key: "Enter", keyCode: 13 });
      if (vendor === "Apple Computer, Inc.") {
        // A markerless WebKit confirmation must not send; the next press sends.
        expect(onRichSubmit).not.toHaveBeenCalled();
        fireEvent.keyDown(editor(), { key: "Enter", keyCode: 13 });
      }
      expect(onRichSubmit).toHaveBeenCalledOnce();
      expect(onRichSubmit.mock.calls[0]![0].plainText).toBe("你好");
    } finally {
      vi.restoreAllMocks();
    }
  }
);

it("shows upload progress and retries a failed image tile", () => {
  const onRetry = vi.fn();
  render(
    <AiInput
      attachments={[
        { id: "loading", type: "image", name: "Uploading shot.png", state: "loading" },
        {
          id: "error",
          type: "image",
          name: "Broken shot.png",
          state: "error",
          onRetry,
        },
      ]}
      onAttachmentRemove={vi.fn()}
    />
  );
  const loading = document.querySelector(
    '[data-slot="image-attachment"] [data-state="loading"]'
  );
  expect(loading).toHaveTextContent("Uploading shot.png");
  const retry = screen.getByRole("button", { name: "Retry uploading Broken shot.png" });
  expect(retry).toHaveTextContent("Retry");
  fireEvent.click(retry);
  expect(onRetry).toHaveBeenCalledOnce();
});
