import { fireEvent, render, screen } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../../../../../api";
import {
  MediaMenuContext,
  type MediaMenuSource,
} from "../../../../file-preview/useMediaContextMenu";
import { MessageInlineVideo } from "../MessageInlineVideo";

afterEach(() => vi.restoreAllMocks());

it("resolves inline and full-window video menus from admitted bytes without fetching a blob URL", async () => {
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:null/original-video");
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  const fetch = vi
    .spyOn(globalThis, "fetch")
    .mockRejectedValue(new TypeError("CSP blocks blob:null"));
  const bytes = new Blob(["original video bytes"], { type: "video/mp4" });
  const fetchConversationAttachment = vi.fn(async () => bytes);
  const api = { fetchConversationAttachment } as unknown as CommaApiClient;
  const open = vi.fn();
  render(
    <MediaMenuContext.Provider value={open}>
      <MessageInlineVideo
        active
        api={api}
        mediaType="video/mp4"
        onUnavailable={vi.fn()}
        position={0}
        source={{
          groupId: "g",
          conversationId: "c",
          messageId: "m",
          attachmentIndex: 0,
          fileName: "original.mp4",
        }}
        testId="inline-video"
      />
    </MediaMenuContext.Provider>
  );
  const video = await screen.findByLabelText("original.mp4");
  fireEvent.contextMenu(video);
  expect(open).toHaveBeenCalledTimes(1);
  let source = open.mock.calls[0]![1] as MediaMenuSource;
  expect(source.fileName).toBe("original.mp4");
  expect(source.video).toBe(video);
  expect(await (await source.resolve()).text()).toBe("original video bytes");
  fireEvent.click(screen.getByRole("button", { name: "Full window" }));
  const fullVideo = await screen.findByLabelText("original.mp4", { selector: "video" });
  fireEvent.contextMenu(fullVideo);
  expect(open).toHaveBeenCalledTimes(2);
  source = open.mock.calls[1]![1] as MediaMenuSource;
  expect(source.video).toBe(fullVideo);
  expect(await (await source.resolve()).text()).toBe("original video bytes");
  expect(fetchConversationAttachment).toHaveBeenCalledTimes(1);
  expect(fetch).not.toHaveBeenCalled();
});
