import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import type { CommaNativeBridge } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { ChatPanelImageGroup, toast } from "@comma/ui";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useMediaContextMenu, type MediaMenuSource } from "../useMediaContextMenu";
import { FilePreviewPanel } from "../FilePreviewPanel";

const png = new Blob(["original PNG"], { type: "image/png" });
const svg = new Blob(
  [
    '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="red"/></svg>',
  ],
  { type: "image/svg+xml" }
);
const sources: MediaMenuSource[] = [
  { fileName: "first.png", resolve: async () => png },
  { fileName: "second.svg", resolve: async () => svg },
];
function Group({
  attach,
  entries = sources,
}: {
  attach: (
    files: import("../../chat/model/conversationChannel").AttachmentUploadInput[]
  ) => unknown;
  entries?: MediaMenuSource[];
}) {
  const { open, menu } = useMediaContextMenu(attach);
  return (
    <>
      <ChatPanelImageGroup
        images={entries.map((source, index) => ({
          alt: source.fileName,
          src: `data:image/png;base64,${index}`,
          onContextMenu: (event) => open(event, source),
        }))}
      />
      {menu}
    </>
  );
}
async function choose(image: HTMLElement, action: string) {
  fireEvent.contextMenu(image, { clientX: 100, clientY: 100 });
  fireEvent.click(await screen.findByRole("menuitem", { name: action }));
}
afterEach(() => toast.dismiss());

describe("image context actions", () => {
  it("keeps the selected source actionable when its viewport scrolls during layout", async () => {
    const attach = vi.fn();
    render(
      <div data-testid="media-viewport">
        <Group attach={attach} />
      </div>
    );
    const viewport = screen.getByTestId("media-viewport");
    fireEvent.contextMenu(screen.getByRole("img", { name: "first.png" }));
    const menu = await screen.findByRole("menu", { name: "Image actions" });

    // Composer growth and full-window focus restoration can scroll the source
    // after the context menu opens, without another user dismissal gesture.
    fireEvent.scroll(viewport);
    expect(menu).toBeVisible();
    fireEvent.click(within(menu).getByRole("menuitem", { name: "Add to Context" }));
    await waitFor(() =>
      expect(attach).toHaveBeenCalledWith([
        { data: png, name: "first.png", size: png.size },
      ])
    );
  });

  it("dismisses the media menu with Escape", async () => {
    render(<Group attach={vi.fn()} />);
    fireEvent.contextMenu(screen.getByRole("img", { name: "first.png" }));
    const menu = await screen.findByRole("menu", { name: "Image actions" });
    fireEvent.keyDown(menu, { key: "Escape" });
    await waitFor(() =>
      expect(
        screen.queryByRole("menu", { name: "Image actions" })
      ).not.toBeInTheDocument()
    );
  });

  it("shows the icon-free menu and uploads the clicked original file after switching images", async () => {
    const attach = vi.fn();
    render(<Group attach={attach} />);
    fireEvent.contextMenu(screen.getByRole("img", { name: "first.png" }));
    const menu = await screen.findByRole("menu", { name: "Image actions" });
    expect(
      within(menu)
        .getAllByRole("menuitem")
        .map((item) => item.textContent)
    ).toEqual(["Add to Context", "Copy image", "Save image"]);
    expect(within(menu).getAllByRole("separator")).toHaveLength(1);
    expect(menu.querySelector("svg")).toBeNull();
    fireEvent.click(within(menu).getByRole("menuitem", { name: "Add to Context" }));
    await waitFor(() =>
      expect(attach).toHaveBeenLastCalledWith([
        { data: png, name: "first.png", size: png.size },
      ])
    );
    await choose(screen.getByRole("img", { name: "second.svg" }), "Add to Context");
    await waitFor(() =>
      expect(attach).toHaveBeenLastCalledWith([
        { data: svg, name: "second.svg", size: svg.size },
      ])
    );
  });

  it("keeps a per-image menu in the full-window filmstrip", async () => {
    const attach = vi.fn();
    render(<Group attach={attach} />);
    fireEvent.click(screen.getByRole("img", { name: "first.png" }));
    const dialog = await screen.findByRole("dialog");
    await choose(
      within(dialog).getByRole("img", { name: "first.png" }),
      "Add to Context"
    );
    await waitFor(() =>
      expect(attach).toHaveBeenLastCalledWith([
        { data: png, name: "first.png", size: png.size },
      ])
    );
    fireEvent.click(within(dialog).getByRole("button", { name: "Show next image" }));
    await choose(
      within(dialog).getByRole("img", { name: "second.svg" }),
      "Add to Context"
    );
    await waitFor(() =>
      expect(attach).toHaveBeenLastCalledWith([
        { data: svg, name: "second.svg", size: svg.size },
      ])
    );
  });

  it("copies through the desktop clipboard and reports success and failure with Toasts", async () => {
    const writeImage = vi.fn(async () => ({ status: "copied" as const }));
    installNativeBridgeMock({ platform: "electron", clipboard: { writeImage } });
    const success = vi.spyOn(toast, "success");
    const failure = vi.spyOn(toast, "error");
    render(<Group attach={vi.fn()} />);
    await choose(screen.getByRole("img", { name: "first.png" }), "Copy image");
    await waitFor(() =>
      expect(writeImage).toHaveBeenCalledWith({
        pngImage: new Uint8Array(new TextEncoder().encode("original PNG")),
      })
    );
    expect(success).toHaveBeenCalledWith("Image copied", expect.any(Object));
    writeImage.mockRejectedValueOnce(new Error("Clipboard denied"));
    await choose(screen.getByRole("img", { name: "first.png" }), "Copy image");
    await waitFor(() =>
      expect(failure).toHaveBeenCalledWith(
        "Couldn’t copy the image",
        expect.any(Object)
      )
    );
  });

  it("saves original SVG bytes from Preview and uploads them as an attachment", async () => {
    const saveDownload = vi.fn<CommaNativeBridge["files"]["saveDownload"]>(
      async () => ({
        status: "saved" as const,
        fileName: "drawing.svg",
        downloadRef: `dnl1_${"a".repeat(43)}`,
      })
    );
    installNativeBridgeMock({ platform: "electron", files: { saveDownload } });
    const success = vi.spyOn(toast, "success");
    const attach = vi.fn();
    render(
      <FilePreviewPanel
        blob={svg}
        fileName="drawing.svg"
        panelId="preview"
        testId="preview"
        download={{
          fileName: "drawing.svg",
          capability: { execute: async () => ({ status: "success" }) },
        }}
        onOpenBrowser={() => {}}
        onAttachFiles={attach}
      />
    );
    const image = await screen.findByRole("img", { name: "drawing.svg" });
    await choose(image, "Save image");
    await waitFor(() => expect(saveDownload).toHaveBeenCalled());
    expect(saveDownload.mock.calls[0]?.[0]).toMatchObject({
      fileName: "drawing.svg",
      content: new Uint8Array(await svg.arrayBuffer()),
    });
    expect(success).toHaveBeenCalled();
    await choose(image, "Add to Context");
    await waitFor(() =>
      expect(attach).toHaveBeenCalledWith([
        { data: svg, name: "drawing.svg", size: svg.size },
      ])
    );
  });

  it("does not attach a late result after its chat surface unmounts", async () => {
    let finish!: (blob: Blob) => void;
    const attach = vi.fn();
    const result = new Promise<Blob>((resolve) => {
      finish = resolve;
    });
    const view = render(
      <Group
        attach={attach}
        entries={[{ fileName: "late.png", resolve: () => result }]}
      />
    );
    await choose(screen.getByRole("img", { name: "late.png" }), "Add to Context");
    view.unmount();
    await act(async () => finish(png));
    expect(attach).not.toHaveBeenCalled();
  });
});

function videoPreview(blob: Blob, name: string, attach = vi.fn()) {
  return render(
    <FilePreviewPanel
      blob={blob}
      fileName={name}
      panelId="video-preview"
      testId="video-preview"
      download={{
        fileName: name,
        capability: { execute: async () => ({ status: "success" }) },
      }}
      onOpenBrowser={() => {}}
      onAttachFiles={attach}
    />
  );
}

describe("video context actions", () => {
  it.each([
    ["clip.mp4", "video/mp4"],
    ["clip.webm", "video/webm"],
    ["clip.mov", "video/quicktime"],
  ])(
    "uploads and copies the complete %s file through the saved-file owner",
    async (name, type) => {
      const blob = new Blob(["complete video bytes"], { type });
      const attach = vi.fn();
      const saveDownload = vi.fn<CommaNativeBridge["files"]["saveDownload"]>(
        async () => ({
          status: "saved",
          fileName: name,
          downloadRef: `dnl1_${"v".repeat(43)}`,
        })
      );
      const copyDownload = vi.fn<CommaNativeBridge["files"]["copyDownload"]>(
        async () => ({ status: "copied" })
      );
      installNativeBridgeMock({
        platform: "electron",
        os: "macos",
        files: { saveDownload, copyDownload },
      });
      const success = vi.spyOn(toast, "success");
      const view = videoPreview(blob, name, attach);
      const video = view.container.querySelector("video")!;
      await choose(video, "Add to Context");
      await waitFor(() =>
        expect(attach).toHaveBeenCalledWith([{ data: blob, name, size: blob.size }])
      );
      await choose(video, "Copy");
      await waitFor(() =>
        expect(copyDownload).toHaveBeenCalledWith({
          downloadRef: `dnl1_${"v".repeat(43)}`,
        })
      );
      expect(saveDownload).toHaveBeenCalledWith({
        fileName: name,
        content: new Uint8Array(await blob.arrayBuffer()),
      });
      expect(success).toHaveBeenCalledWith("Video copied", expect.any(Object));
    }
  );

  it("disables complete-file Copy on web and Copy Current Frame until a frame is decoded", async () => {
    installNativeBridgeMock({ platform: "web" });
    const view = videoPreview(new Blob(["video"], { type: "video/mp4" }), "clip.mp4");
    fireEvent.contextMenu(view.container.querySelector("video")!);
    const menu = await screen.findByRole("menu", { name: "Video actions" });
    expect(
      within(menu)
        .getAllByRole("menuitem")
        .map((item) => item.textContent)
    ).toEqual(["Add to Context", "Copy", "Copy Current Frame", "Save"]);
    expect(menu.querySelector("svg")).toBeNull();
    expect(within(menu).getByRole("menuitem", { name: "Copy" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
    expect(
      within(menu).getByRole("menuitem", { name: "Copy Current Frame" })
    ).toHaveAttribute("aria-disabled", "true");
    expect(within(menu).getByRole("menuitem", { name: "Save" })).not.toHaveAttribute(
      "aria-disabled",
      "true"
    );
  });

  it("captures the right-click frame once and copies it without reading the complete video", async () => {
    const writeImage = vi.fn<CommaNativeBridge["clipboard"]["writeImage"]>(
      async () => ({
        status: "copied",
      })
    );
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      clipboard: { writeImage },
    });
    const draw = vi.fn();
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
      drawImage: draw,
    } as unknown as CanvasRenderingContext2D);
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation((callback) =>
      callback(png)
    );
    const view = videoPreview(new Blob(["video"], { type: "video/mp4" }), "clip.mp4");
    const video = view.container.querySelector("video")!;
    Object.defineProperties(video, {
      readyState: { value: 2 },
      videoWidth: { value: 640 },
      videoHeight: { value: 360 },
    });
    video.currentTime = 1;
    fireEvent.contextMenu(video);
    expect(draw).toHaveBeenCalledExactlyOnceWith(video, 0, 0);
    video.currentTime = 2;
    fireEvent.click(
      await screen.findByRole("menuitem", { name: "Copy Current Frame" })
    );
    await waitFor(() =>
      expect(writeImage).toHaveBeenCalledWith({
        pngImage: new Uint8Array(new TextEncoder().encode("original PNG")),
      })
    );
    expect(draw).toHaveBeenCalledTimes(1);
  });
});
