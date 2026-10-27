import { chatAttachmentDownloadMaxBytes } from "@comma/chat-contract";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it, vi } from "vitest";
import {
  MediaMenuContext,
  type MediaMenuSource,
} from "../../../../file-preview/useMediaContextMenu";
import { MessageInlineVideo } from "../MessageInlineVideo";

afterEach(() => vi.restoreAllMocks());

const attachment = {
  groupId: "g",
  conversationId: "c",
  messageId: "m",
  attachmentIndex: 0,
  fileName: "original.mp4",
};
const fileSource = {
  source: "attachment",
  group: "g",
  conversation: "c",
  message: "m",
  index: 0,
};

it("plays a video from the stream the host opened, reading none of its bytes itself", async () => {
  const opened: unknown[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "fileStream"
        ? { status: "ready", url: "comma-file://stream/one" }
        : undefined,
    onSubscribe: (topic) => {
      if (topic.topic === "fileStream") opened.push(topic);
    },
  });
  render(
    core.wrap(
      <MessageInlineVideo
        active
        mediaType="video/mp4"
        onUnavailable={vi.fn()}
        position={0}
        source={{ ...attachment, size: 33_000_000 }}
        testId="inline-video"
      />
    )
  );

  const video = await screen.findByLabelText("original.mp4", { selector: "video" });
  expect(video.getAttribute("src")).toBe("comma-file://stream/one");
  expect(video.getAttribute("crossorigin")).toBe("anonymous");
  expect(opened).toEqual([
    { topic: "fileStream", source: JSON.stringify(fileSource), type: "video/mp4" },
  ]);
  expect(core.sentTo("files.read")).toEqual([]);
});

it("paints the file card when the host could not open the stream", async () => {
  const onUnavailable = vi.fn();
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "fileStream" ? { status: "failed", url: null } : undefined,
  });
  render(
    core.wrap(
      <MessageInlineVideo
        active
        mediaType="video/mp4"
        onUnavailable={onUnavailable}
        position={3}
        source={attachment}
        testId="inline-video"
      />
    )
  );
  await vi.waitFor(() => expect(onUnavailable).toHaveBeenCalledWith(3));
});

it("reads the bytes a part at a time where the host cannot stream, and resolves inline and full-window video menus from them without fetching a blob URL", async () => {
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:null/original-video");
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  const fetch = vi
    .spyOn(globalThis, "fetch")
    .mockRejectedValue(new TypeError("CSP blocks blob:null"));
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "fileStream" ? { status: "unsupported", url: null } : undefined,
    calls: (name) =>
      name === "files.readRange"
        ? {
            bytes: new TextEncoder().encode("original video bytes"),
            type: "application/octet-stream",
            size: 20,
          }
        : null,
  });
  const open = vi.fn();
  render(
    core.wrap(
      <MediaMenuContext.Provider value={open}>
        <MessageInlineVideo
          active
          mediaType="video/mp4"
          onUnavailable={vi.fn()}
          position={0}
          source={attachment}
          testId="inline-video"
        />
      </MediaMenuContext.Provider>
    )
  );
  const video = await screen.findByLabelText("original.mp4");
  fireEvent.contextMenu(video);
  expect(open).toHaveBeenCalledTimes(1);
  let source = open.mock.calls[0]![1] as MediaMenuSource;
  expect(source.fileName).toBe("original.mp4");
  expect(source.video).toBe(video);
  const first = await source.resolve();
  expect(await first.text()).toBe("original video bytes");
  // The decoder gets the type the attachment was admitted under, not the server's.
  expect(first.type).toBe("video/mp4");
  fireEvent.click(screen.getByRole("button", { name: "Full window" }));
  const fullVideo = await screen.findByLabelText("original.mp4", { selector: "video" });
  fireEvent.contextMenu(fullVideo);
  expect(open).toHaveBeenCalledTimes(2);
  source = open.mock.calls[1]![1] as MediaMenuSource;
  expect(source.video).toBe(fullVideo);
  expect(await (await source.resolve()).text()).toBe("original video bytes");
  expect(core.sentTo("files.readRange")).toEqual([
    { source: fileSource, offset: 0, length: chatAttachmentDownloadMaxBytes },
  ]);
  expect(fetch).not.toHaveBeenCalled();
});
