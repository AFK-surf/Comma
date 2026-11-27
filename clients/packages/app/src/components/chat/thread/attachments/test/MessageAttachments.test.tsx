import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { describe, expect, it, vi } from "vitest";
import type { ChatAttachment } from "@comma/core/chat";
import type { CallFn } from "@comma/core-client";
import type { CommaNativeBridge } from "@comma/native-bridge";
import { LocalFilePreviews } from "../../../channel/LocalFilePreviews";
import { ThreadFileSourceContext } from "../../threadContexts";
import { readAttachmentImage } from "../images/readAttachmentImage";
import { MessageAttachments } from "../MessageAttachments";

const previewUrl =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==";

const makeImageAttachments = (count: number): ChatAttachment[] =>
  Array.from({ length: count }, (_, index) => ({
    blockType: "image",
    fileName: `gen-${index + 1}.png`,
    localFileRef: `lfi1_${String(index).repeat(43).slice(0, 43)}`,
    mimeType: "image/png",
    size: 67,
  }));

describe("MessageAttachments", () => {
  it.each([1, 2, 3, 4, 6])(
    "renders %i agent images through ChatPanelImageGroup with start alignment",
    async (count) => {
      const core = createScriptedCore();
      const preview = vi.fn(async () => ({ url: previewUrl, release: vi.fn() }));
      const { container } = render(
        core.wrap(
          <MessageAttachments
            attachments={makeImageAttachments(count)}
            messageId={`msg_agent_${count}`}
            onPreviewLocalFile={preview}
            section="all"
          />
        )
      );

      await screen.findByRole("img", { name: "gen-1.png" });
      const group = container.querySelector(".chat-panel-image-group");
      expect(group).not.toBeNull();
      expect(group).toHaveAttribute("data-align", "start");

      const cards = container.querySelectorAll(".chat-panel-image-group-card");
      expect(cards).toHaveLength(count);
      if (count === 1) {
        expect(group).toHaveAttribute("data-single", "true");
        expect(screen.getByRole("button", { name: "Copy image" })).toBeInTheDocument();
      } else if (count <= 3) {
        expect(group).not.toHaveAttribute("data-single");
        expect(screen.queryByRole("button", { name: /images/i })).toBeNull();
      } else {
        expect(screen.getByRole("button", { name: `${count} Images` })).toHaveAttribute(
          "aria-expanded",
          "false"
        );
      }
    }
  );

  it("keeps agent 4-image attachment order in one start-aligned deck and flips front card on Next", async () => {
    const user = userEvent.setup();
    const core = createScriptedCore();
    const preview = vi.fn(async () => ({ url: previewUrl, release: vi.fn() }));
    const { container } = render(
      core.wrap(
        <MessageAttachments
          attachments={makeImageAttachments(4)}
          messageId="msg_agent_4_order"
          onPreviewLocalFile={preview}
          section="all"
        />
      )
    );

    await screen.findByRole("img", { name: "gen-1.png" });
    const group = container.querySelector(
      '.chat-panel-image-group[data-align="start"]'
    );
    expect(group).not.toBeNull();
    const cards = [
      ...group!.querySelectorAll<HTMLButtonElement>(".chat-panel-image-group-card"),
    ];
    expect(cards).toHaveLength(4);
    expect(cards.map((card) => card.dataset.stackPos)).toEqual([
      "0",
      "r1",
      "r2",
      "hidden-right",
    ]);
    expect(cards[0]?.querySelector("img")).toHaveAttribute("alt", "gen-1.png");
    expect(cards[1]?.querySelector("img")).toHaveAttribute("alt", "gen-2.png");
    expect(cards[2]?.querySelector("img")).toHaveAttribute("alt", "gen-3.png");
    expect(cards[3]?.querySelector("img")).toBeNull();

    await user.click(screen.getByRole("button", { name: "Show next image" }));
    expect(cards.map((card) => card.dataset.stackPos)).toEqual(["l1", "0", "r1", "r2"]);
    expect(cards[1]?.querySelector("img")).toHaveAttribute("alt", "gen-2.png");
    expect(cards[0]?.querySelector("img")).toHaveAttribute("alt", "gen-1.png");
  });

  it("keeps user image groups end-aligned", async () => {
    const core = createScriptedCore();
    const preview = vi.fn(async () => ({ url: previewUrl, release: vi.fn() }));
    const { container } = render(
      core.wrap(
        <MessageAttachments
          attachments={makeImageAttachments(4)}
          messageId="msg_user_4"
          onPreviewLocalFile={preview}
          section="images"
        />
      )
    );

    await screen.findByRole("img", { name: "gen-1.png" });
    const group = container.querySelector(".chat-panel-image-group");
    expect(group).toHaveAttribute("data-align", "end");
    expect(screen.getByRole("button", { name: "4 Images" })).toBeInTheDocument();
  });

  it("renders collaborative task uploaded images inline through LocalFilePreviews instead of falling back to a file card", async () => {
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:collab-inline-preview");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    const png = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13]);
    const core = createScriptedCore({
      calls: (name) => (name === "chat.readGroupImage" ? png : null),
    });
    const bridge = {
      localFiles: {
        preview: vi.fn(async () => ({ status: "unavailable" as const })),
      },
    } as unknown as CommaNativeBridge;
    const previews = new LocalFilePreviews(core.client, bridge, {
      conversationId: "cnv1_collab",
      groupId: "grp_1",
      session: {
        audience: "app",
        authorityInstanceId: "auth_1",
        generation: 1,
        sessionId: "sess_1",
      },
    });
    previews.ensure();

    const taskPath = "/task/cnv1_collab/uploads/AAAAAAAAAAAAAAAAAAAAAA-image.png";
    const { container, unmount } = render(
      core.wrap(
        <ThreadFileSourceContext.Provider
          value={{ conversationId: "cnv1_collab", groupId: "grp_1" }}
        >
          <MessageAttachments
            attachments={[
              {
                blockType: "image",
                fileName: "image.png",
                mimeType: "image/png",
                size: png.byteLength,
                workspacePath: taskPath,
              },
            ]}
            messageId="msg_collab_inline"
            onPreviewLocalFile={(ref) => previews.acquire(ref)}
            section="images"
          />
        </ThreadFileSourceContext.Provider>
      )
    );

    const img = await screen.findByRole("img", { name: "image.png" });
    expect(img).toHaveAttribute("src", "blob:collab-inline-preview");
    expect(container.querySelector(".chat-panel-file")).toBeNull();
    expect(core.sentTo("chat.readGroupImage")).toMatchObject([
      {
        conversationId: "cnv1_collab",
        groupId: "grp_1",
        path: taskPath,
        source: "group-file",
      },
    ]);

    unmount();
    previews.dispose();
    createObjectURL.mockRestore();
    revokeObjectURL.mockRestore();
  });

  it("passes task conversationId when reading a task folder image via readAttachmentImage", async () => {
    const core = createScriptedCore({
      calls: (name) =>
        name === "files.read"
          ? { bytes: Uint8Array.from([137, 80, 78, 71]), type: "image/png" }
          : null,
    });
    const call = ((name, params, signal) =>
      core.client.call(name, params, undefined, signal)) as CallFn;
    const blob = await readAttachmentImage({
      attachment: {
        blockType: "image",
        fileName: "plot.png",
        mimeType: "image/png",
        workspacePath: "/task/charts/plot.png",
      },
      call,
      messageId: "msg_1",
      previewUrl: "blob:unused",
      sourceContext: { conversationId: "cnv1_collab", groupId: "grp_1" },
    });
    expect(blob.type).toBe("image/png");
    expect(core.sentTo("files.read")).toEqual([
      {
        source: "group-file",
        group: "grp_1",
        path: "/task/charts/plot.png",
        task: "cnv1_collab",
      },
    ]);
  });
});
