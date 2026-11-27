import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { initializeCommaI18n } from "@comma/i18n";
import { cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import {
  ChatPanelFile,
  ChatPanelImageGroup,
  ChatPanelPreviewCard,
  type ChatPanelFileOpenInAction,
} from "@comma/ui/components/chat-panel";
import { FileTypeIcon } from "@comma/ui/components/file-type-icon";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { page } from "vitest/browser";
import { ChatImageGroupPlaceholder } from "../images/ChatImageGroupPlaceholder";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

afterEach(() => {
  cleanup();
  document.body.replaceChildren();
});

const openInAction: ChatPanelFileOpenInAction = {
  listApplications: vi.fn(async () => []),
  openApplication: vi.fn(async () => undefined),
};

describe("chat file card width", () => {
  it("keeps file cards at container-sm width in user, other-user, and assistant messages", async () => {
    await page.viewport(1024, 900);
    const core = createScriptedCore();
    const view = render(
      core.wrap(
        <div className="comma-chat-thread" style={{ width: 800 }}>
          <div className="comma-chat-column">
            <div className="comma-chat-turn">
              <article className="comma-chat-message-user comma-chat-message-other">
                <div className="comma-chat-assistant-source-label">CatsJuice</div>
                <div className="comma-chat-block-extras" data-placement="leading">
                  <div className="comma-chat-attachments">
                    <div className="comma-chat-file-card-column">
                      <ChatPanelFile
                        fileName="image.png"
                        mimeType="image/png"
                        onPreview={vi.fn()}
                        openIn={openInAction}
                        testId="other-user-file"
                      />
                    </div>
                  </div>
                </div>
                <div className="comma-chat-user-bubble-row">
                  <div className="comma-chat-user-bubble-slot">
                    <div className="comma-chat-user-bubble">oh 搁这呢</div>
                  </div>
                </div>
              </article>

              <article className="comma-chat-message-user">
                <div className="comma-chat-block-extras" data-placement="leading">
                  <div className="comma-chat-attachments">
                    <div className="comma-chat-file-card-column">
                      <ChatPanelFile
                        fileName="a.png"
                        mimeType="image/png"
                        onPreview={vi.fn()}
                        openIn={openInAction}
                        testId="own-user-file"
                      />
                    </div>
                  </div>
                </div>
              </article>

              <article className="comma-chat-message-assistant">
                <div className="comma-chat-assistant-response-body">
                  <div className="comma-chat-block-extras">
                    <div className="comma-chat-attachments">
                      <div className="comma-chat-file-card-column">
                        <ChatPanelFile
                          fileName="a.zip"
                          mimeType="application/zip"
                          openIn={openInAction}
                          testId="assistant-file"
                        />
                        <ChatPanelPreviewCard
                          icon={<FileTypeIcon className="size-3xl" fileName="a.md" />}
                          onOpen={vi.fn()}
                          openIn={openInAction}
                          subtitle="MD"
                          testId="assistant-preview-card"
                          title="a.md"
                        />
                      </div>
                    </div>
                  </div>
                </div>
              </article>
            </div>
          </div>
        </div>
      )
    );

    const otherFile = view.getByTestId("other-user-file").getBoundingClientRect();
    const ownFile = view.getByTestId("own-user-file").getBoundingClientRect();
    const assistantFile = view.getByTestId("assistant-file").getBoundingClientRect();
    const assistantPreview = view
      .getByTestId("assistant-preview-card")
      .getBoundingClientRect();

    expect(Math.round(otherFile.width)).toBe(480);
    expect(Math.round(ownFile.width)).toBe(480);
    expect(Math.round(assistantFile.width)).toBe(480);
    expect(Math.round(assistantPreview.width)).toBe(480);
  });

  it("narrows file cards cleanly inside narrow and side-chat columns without overflow", async () => {
    await page.viewport(500, 720);
    const core = createScriptedCore();
    const view = render(
      core.wrap(
        <div
          className="comma-chat-route"
          data-variant="side-chat"
          style={{ width: 340 }}
        >
          <div className="comma-chat-thread" style={{ width: 340 }}>
            <div className="comma-chat-column" data-testid="narrow-column">
              <div className="comma-chat-turn">
                <article className="comma-chat-message-user comma-chat-message-other">
                  <div className="comma-chat-block-extras" data-placement="leading">
                    <div className="comma-chat-attachments">
                      <div className="comma-chat-file-card-column">
                        <ChatPanelFile
                          fileName="very-long-attachment-filename-that-must-truncate-cleanly.png"
                          mimeType="image/png"
                          onPreview={vi.fn()}
                          openIn={openInAction}
                          testId="narrow-other-file"
                        />
                      </div>
                    </div>
                  </div>
                </article>

                <article className="comma-chat-message-assistant">
                  <div className="comma-chat-assistant-response-body">
                    <div className="comma-chat-block-extras">
                      <div className="comma-chat-attachments">
                        <div className="comma-chat-file-card-column">
                          <ChatPanelFile
                            fileName="image.png"
                            mimeType="image/png"
                            onPreview={vi.fn()}
                            openIn={openInAction}
                            testId="narrow-assistant-file"
                          />
                        </div>
                      </div>
                    </div>
                  </div>
                </article>
              </div>
            </div>
          </div>
        </div>
      )
    );

    const column = view.getByTestId("narrow-column").getBoundingClientRect();
    const narrowOther = view.getByTestId("narrow-other-file").getBoundingClientRect();
    const narrowAssistant = view
      .getByTestId("narrow-assistant-file")
      .getBoundingClientRect();

    expect(narrowOther.width).toBeGreaterThan(200);
    expect(narrowOther.width).toBeLessThan(480);
    expect(narrowOther.left).toBeGreaterThanOrEqual(column.left - 1);
    expect(narrowOther.right).toBeLessThanOrEqual(column.right + 1);

    expect(narrowAssistant.width).toBeGreaterThan(200);
    expect(narrowAssistant.width).toBeLessThan(480);
    expect(narrowAssistant.left).toBeGreaterThanOrEqual(column.left - 1);
    expect(narrowAssistant.right).toBeLessThanOrEqual(column.right + 1);
  });

  it("reserves 4:3 space for single-image placeholders and avoids content-visibility skipping on single-image cards", async () => {
    await page.viewport(1024, 900);
    const core = createScriptedCore();
    const pixel =
      "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='320' height='180'%3E%3Crect width='320' height='180' fill='%23ccc'/%3E%3C/svg%3E";
    const view = render(
      core.wrap(
        <div className="comma-chat-thread" style={{ width: 800 }}>
          <div className="comma-chat-column">
            <div className="comma-chat-turn">
              <article className="comma-chat-message-assistant">
                <div className="comma-chat-assistant-response-body">
                  <div className="comma-chat-block-extras">
                    <div className="comma-chat-attachments">
                      <ChatImageGroupPlaceholder
                        align="start"
                        count={1}
                        expanded={false}
                      />
                      <ChatPanelImageGroup
                        align="start"
                        images={[{ alt: "single", src: pixel }]}
                      />
                      <ChatPanelImageGroup
                        align="start"
                        images={[
                          { alt: "multi-1", src: pixel },
                          { alt: "multi-2", src: pixel },
                        ]}
                      />
                    </div>
                  </div>
                </div>
              </article>
            </div>
          </div>
        </div>
      )
    );

    const placeholderCard = view.container.querySelector<HTMLElement>(
      "[data-comma-image-group-placeholder] .chat-panel-image-group-card"
    )!;
    const placeholderRect = placeholderCard.getBoundingClientRect();
    expect(Math.round(placeholderRect.width)).toBe(320);
    expect(Math.round(placeholderRect.height)).toBe(240);

    const singleCard = view.container.querySelector<HTMLElement>(
      'figure.chat-panel-image-group[data-single="true"] .chat-panel-image-group-card'
    )!;
    expect(getComputedStyle(singleCard).contentVisibility).toBe("visible");

    const multiCard = view.container.querySelector<HTMLElement>(
      'figure.chat-panel-image-group:not([data-single="true"]) .chat-panel-image-group-card'
    )!;
    expect(getComputedStyle(multiCard).contentVisibility).toBe("auto");
  });
});
