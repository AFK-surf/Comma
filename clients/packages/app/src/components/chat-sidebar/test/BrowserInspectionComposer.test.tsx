import { fireEvent, render, screen } from "@comma/test-utils/render";
import { browserInspectionComposerConsolePrefix } from "@comma/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommaWebClientSettingsProvider } from "../../commaClientSettings";
import { BrowserInspectionComposer } from "../BrowserInspectionComposer";

const renderComposer = () =>
  render(
    <CommaWebClientSettingsProvider>
      <BrowserInspectionComposer />
    </CommaWebClientSettingsProvider>
  );

describe("BrowserInspectionComposer", () => {
  afterEach(() => {
    sessionStorage.clear();
    delete document.documentElement.dataset.commaWindowRole;
    delete document.body.dataset.commaWindowRole;
    vi.restoreAllMocks();
  });

  it("restores a draft after renderer reload and resets it for a new inspection", () => {
    sessionStorage.setItem(
      "comma-browser-inspection-composer-draft",
      "Half-written prompt"
    );
    renderComposer();

    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(
      "Half-written prompt"
    );

    fireEvent(
      window,
      new CustomEvent("comma-browser-inspection-composer-activate", {
        detail: { resetDraft: false },
      })
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(
      "Half-written prompt"
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveFocus();

    fireEvent(
      window,
      new CustomEvent("comma-browser-inspection-composer-activate", {
        detail: { resetDraft: true },
      })
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent("");
    expect(
      sessionStorage.getItem("comma-browser-inspection-composer-draft")
    ).toBeNull();
  });

  it("reuses the chat Composer without exposing attachments", () => {
    const log = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const view = renderComposer();

    expect(view.container.querySelector(".comma-chat-composer")).not.toBeNull();
    expect(screen.queryByRole("button", { name: "Add attachment" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    expect(log).toHaveBeenCalledWith(
      `${browserInspectionComposerConsolePrefix}${JSON.stringify({ type: "cancel" })}`
    );
    fireEvent.keyDown(window, { key: "Escape" });
    expect(log).toHaveBeenLastCalledWith(
      `${browserInspectionComposerConsolePrefix}${JSON.stringify({ type: "cancel" })}`
    );

    const prompt = screen.getByRole("textbox", { name: "AI prompt" });
    fireEvent.input(prompt, {
      target: { textContent: "Explain this element" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));

    expect(log).toHaveBeenCalledWith(
      `${browserInspectionComposerConsolePrefix}${JSON.stringify({
        message: "Explain this element",
        type: "submit",
      })}`
    );
  });
});
