import userEvent from "@testing-library/user-event";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { useState } from "react";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ChatPanelAudio,
  ChatPanelFile,
  ChatPanelImage,
  ChatPanelVideo,
  downloadMediaSource,
} from "../ChatPanelMedia";
import type {
  ChatPanelMediaDownloadAction,
  ChatPanelMediaDownloadResult,
} from "../ChatPanelMediaDownload";
import { useMediaPlaybackController } from "../ChatPanelMediaPlayer";

const imageSource =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='32' height='32'/%3E";
const audioSource = "generated-audio.mp3";
const videoSource = "generated-video.mp4";
const originalClipboard = navigator.clipboard;

const createDownloadAction = (
  fileName: string,
  execute: (
    request: Parameters<ChatPanelMediaDownloadAction["capability"]["execute"]>[0]
  ) => ChatPanelMediaDownloadResult | Promise<ChatPanelMediaDownloadResult>,
  fileSize?: number | string
): ChatPanelMediaDownloadAction => ({
  capability: { execute },
  fileName,
  ...(fileSize === undefined ? {} : { fileSize }),
});

const MediaBindingHarness = () => {
  const [showFirstElement, setShowFirstElement] = useState(true);
  const controller = useMediaPlaybackController({ duration: 19 });

  return (
    <>
      {showFirstElement ? (
        // oxlint-disable-next-line jsx-a11y/media-has-caption -- Test media has no spoken content.
        <audio ref={controller.bindMediaElement} />
      ) : null}
      {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- Test media has no spoken content. */}
      <audio data-testid="active-media" ref={controller.bindMediaElement} />
      <button onClick={() => setShowFirstElement(false)} type="button">
        Remove stale media
      </button>
      <button onClick={() => controller.setCurrentTime(7)} type="button">
        Seek active media
      </button>
    </>
  );
};

const DetachedPlaybackHarness = () => {
  const controller = useMediaPlaybackController({ duration: 19 });

  return (
    <button onClick={controller.togglePlaying} type="button">
      {controller.isPlaying ? "Pause detached media" : "Play detached media"}
    </button>
  );
};

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: originalClipboard,
  });
});

describe("ChatPanel generated media", () => {
  it.each(["audio", "video"] as const)(
    "pauses and resumes %s playback while its progress control is dragged",
    async (kind) => {
      const user = userEvent.setup();
      const play = vi
        .spyOn(HTMLMediaElement.prototype, "play")
        .mockResolvedValue(undefined);
      const pause = vi
        .spyOn(HTMLMediaElement.prototype, "pause")
        .mockImplementation(() => undefined);
      const mediaLabel = kind === "audio" ? "Audio" : "Video";
      const { container } = render(
        kind === "audio" ? (
          <ChatPanelAudio src={audioSource} />
        ) : (
          <ChatPanelVideo alt="Generated clip" poster={imageSource} src={videoSource} />
        )
      );

      const media = container.querySelector(kind);
      expect(media).not.toBeNull();

      await user.click(screen.getByRole("button", { name: `Play ${kind}` }));
      await waitFor(() =>
        expect(
          screen.getByRole("button", { name: `Pause ${kind}` })
        ).toBeInTheDocument()
      );

      const progress = screen.getByRole("slider", {
        name: `${mediaLabel} playback position`,
      });
      fireEvent.pointerDown(progress, { button: 0, isPrimary: true, pointerId: 1 });

      expect(pause).toHaveBeenCalledOnce();
      expect(screen.getByRole("button", { name: `Play ${kind}` })).toBeInTheDocument();

      fireEvent.change(progress, { target: { value: "10" } });
      expect((media as HTMLMediaElement).currentTime).toBe(10);

      fireEvent.pointerUp(progress, { isPrimary: true, pointerId: 1 });

      await waitFor(() => expect(play).toHaveBeenCalledTimes(2));
      expect(screen.getByRole("button", { name: `Pause ${kind}` })).toBeInTheDocument();
    }
  );

  it("does not start paused audio when its progress control is dragged", () => {
    const play = vi
      .spyOn(HTMLMediaElement.prototype, "play")
      .mockResolvedValue(undefined);
    const pause = vi
      .spyOn(HTMLMediaElement.prototype, "pause")
      .mockImplementation(() => undefined);
    render(<ChatPanelAudio src={audioSource} />);

    const progress = screen.getByRole("slider", { name: "Audio playback position" });
    fireEvent.pointerDown(progress, { button: 0, isPrimary: true, pointerId: 1 });
    fireEvent.change(progress, { target: { value: "10" } });
    fireEvent.pointerUp(progress, { isPrimary: true, pointerId: 1 });

    expect(pause).not.toHaveBeenCalled();
    expect(play).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Play audio" })).toBeInTheDocument();
  });

  it("keeps pointer seeking precise while keyboard seeking uses bounded steps", () => {
    const { container } = render(<ChatPanelAudio duration={3600} src={audioSource} />);
    const audio = container.querySelector("audio");
    const progress = screen.getByRole("slider", {
      name: "Audio playback position",
    });
    expect(audio).not.toBeNull();
    expect(progress).toHaveAttribute("step", "any");

    fireEvent.change(progress, { target: { value: "120.125" } });
    expect(audio!.currentTime).toBe(120.125);

    fireEvent.keyDown(progress, { key: "ArrowRight" });
    expect(audio!.currentTime).toBe(125.125);
    fireEvent.keyDown(progress, { key: "ArrowUp" });
    expect(audio!.currentTime).toBe(130.125);
    fireEvent.keyDown(progress, { key: "ArrowLeft" });
    expect(audio!.currentTime).toBe(125.125);
    fireEvent.keyDown(progress, { key: "ArrowDown" });
    expect(audio!.currentTime).toBe(120.125);

    fireEvent.change(progress, { target: { value: "3598" } });
    fireEvent.keyDown(progress, { key: "ArrowRight" });
    expect(audio!.currentTime).toBe(3600);
    fireEvent.change(progress, { target: { value: "2" } });
    fireEvent.keyDown(progress, { key: "ArrowLeft" });
    expect(audio!.currentTime).toBe(0);
  });

  it("shares interactive playback controls with animated state feedback", async () => {
    const user = userEvent.setup();
    vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
    render(<ChatPanelAudio src={audioSource} />);

    const playButton = screen.getByRole("button", { name: "Play audio" });
    expect(playButton.querySelector(".t-icon-swap")).toHaveAttribute("data-state", "a");

    await user.click(playButton);

    const pauseButton = screen.getByRole("button", { name: "Pause audio" });
    expect(pauseButton.querySelector(".t-icon-swap")).toHaveAttribute(
      "data-state",
      "b"
    );

    const volumeButton = screen.getByRole("button", { name: "Volume 100%" });
    const volumeIcon = volumeButton.querySelector(".chat-panel-media-volume-icon");
    const speakerPath = volumeIcon?.querySelector(
      ".chat-panel-media-volume-base > path:nth-of-type(3)"
    );
    const stateLayers = volumeIcon?.querySelectorAll(
      ":scope .chat-panel-media-volume-state"
    );
    const stateGlyphs = Array.from(
      volumeIcon?.querySelectorAll(".chat-panel-media-volume-state-glyph") ?? []
    );
    const statePathValues = stateGlyphs.map((glyph) =>
      Array.from(glyph.querySelectorAll("path"), (path) => path.getAttribute("d"))
    );
    expect(
      volumeIcon?.querySelectorAll(":scope > .chat-panel-media-volume-base")
    ).toHaveLength(1);
    expect(stateLayers).toHaveLength(3);
    expect(stateGlyphs).toHaveLength(3);
    expect(volumeIcon).toHaveAttribute("data-state", "loud");
    expect(speakerPath).toHaveAttribute("d");
    await user.click(volumeButton);
    expect(
      screen.getByRole("dialog", { name: "Audio volume controls" })
    ).toBeInTheDocument();
    const volumeSlider = screen.getByRole("slider", { name: "Audio volume" });
    expect(volumeSlider).toHaveValue("1");
    expect(volumeButton).toHaveAttribute("aria-expanded", "true");

    await user.click(volumeButton);
    expect(
      screen.getByRole("button", { name: "Muted. Change volume" })
    ).toBeInTheDocument();
    expect(
      screen
        .getByRole("button", { name: "Muted. Change volume" })
        .querySelector(".chat-panel-media-volume-icon")
    ).toHaveAttribute("data-state", "off");
    expect(
      screen
        .getByRole("button", { name: "Muted. Change volume" })
        .querySelector(".chat-panel-media-volume-base > path:nth-of-type(3)")
    ).toBe(speakerPath);
    expect(
      Array.from(
        volumeIcon?.querySelectorAll(".chat-panel-media-volume-state-glyph") ?? []
      )
    ).toEqual(stateGlyphs);

    fireEvent.change(volumeSlider, { target: { value: "0.42" } });
    expect(screen.getByRole("button", { name: "Volume 42%" })).toBeInTheDocument();
    expect(volumeIcon).toHaveAttribute("data-state", "half");
    expect(volumeSlider).toHaveValue("0.42");

    fireEvent.change(volumeSlider, { target: { value: "0.2" } });
    expect(volumeIcon).toHaveAttribute("data-level", "1");
    expect(volumeIcon).toHaveAttribute("data-state", "half");
    fireEvent.change(volumeSlider, { target: { value: "0.5" } });
    await waitFor(() => expect(volumeIcon).toHaveAttribute("data-level", "2"));
    expect(volumeIcon).toHaveAttribute("data-state", "half");
    fireEvent.change(volumeSlider, { target: { value: "1" } });
    expect(volumeIcon).toHaveAttribute("data-state", "loud");
    expect(
      volumeIcon?.querySelector(".chat-panel-media-volume-base > path:nth-of-type(3)")
    ).toBe(speakerPath);
    expect(
      stateGlyphs.map((glyph) =>
        Array.from(glyph.querySelectorAll("path"), (path) => path.getAttribute("d"))
      )
    ).toEqual(statePathValues);
    expect(
      Array.from(
        volumeIcon?.querySelectorAll(".chat-panel-media-volume-state-glyph") ?? []
      )
    ).toEqual(stateGlyphs);

    fireEvent.change(screen.getByRole("slider", { name: "Audio playback position" }), {
      target: { value: "10" },
    });
    expect(screen.getByText("00:10")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Playback speed 1x" }));
    expect(screen.getByRole("menuitemradio", { name: "1x" })).toHaveAttribute(
      "aria-checked",
      "true"
    );
    await user.click(screen.getByRole("menuitemradio", { name: "1.5x" }));

    const speedButton = screen.getByRole("button", {
      name: "Playback speed 1.5x",
    });
    expect(speedButton).toBeInTheDocument();
    expect(
      speedButton.querySelector(".chat-panel-media-speed-value")
    ).toHaveTextContent("1.5x");
  });

  it("derives the file type from MIME metadata and the extension", () => {
    const { rerender } = render(
      <ChatPanelFile
        fileName="research-notes"
        fileSize={2 * 1024 * 1024}
        mimeType="application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      />
    );

    expect(screen.getByText("DOCX · 2MB")).toBeInTheDocument();
    const fileSurface = screen.getByText("research-notes").closest(".chat-panel-file");
    expect(fileSurface).not.toBeNull();
    expect(fileSurface?.querySelector(".chat-panel-file-icon")).toBeInTheDocument();
    expect(fileSurface?.querySelector('[data-slot="file-icon-surface"]')).toBeNull();

    rerender(
      <ChatPanelFile fileName="quarterly-report.pdf" mimeType="application/pdf" />
    );
    expect(screen.getByText("PDF")).toBeInTheDocument();
    expect(screen.queryByText(/PDF ·/)).not.toBeInTheDocument();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();

    rerender(<ChatPanelFile fileName="cover.final.png" fileSize="840KB" />);
    expect(screen.getByText("PNG · 840KB")).toBeInTheDocument();
  });

  it("uses the code-block icon swap after an image copy succeeds", async () => {
    const user = userEvent.setup();
    const imageBlob = new Blob(["generated image"], { type: "image/png" });
    const clipboardItem = { types: ["image/png"] };
    const clipboardItemConstructor = vi.fn(function ClipboardItemMock() {
      return clipboardItem;
    });
    const fetchImage = vi.fn().mockResolvedValue({
      blob: () => Promise.resolve(imageBlob),
      ok: true,
    });
    const write = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("ClipboardItem", clipboardItemConstructor);
    vi.stubGlobal("fetch", fetchImage);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { write },
    });

    render(<ChatPanelImage alt="Generated cover" src={imageSource} />);

    const copyButton = screen.getByRole("button", { name: "Copy image" });
    expect(copyButton.querySelector(".t-icon-swap")).toHaveAttribute("data-state", "a");

    await user.click(copyButton);

    await waitFor(() => expect(fetchImage).toHaveBeenCalledWith(imageSource));
    expect(clipboardItemConstructor).toHaveBeenCalledWith({
      "image/png": imageBlob,
    });
    expect(write).toHaveBeenCalledWith([clipboardItem]);
    const copiedButton = screen.getByRole("button", { name: "Image copied" });
    expect(copiedButton.querySelector(".t-icon-swap")).toHaveAttribute(
      "data-state",
      "b"
    );
  });

  it("shares the accessible fullscreen preview between image and video", async () => {
    const user = userEvent.setup();
    render(
      <>
        <ChatPanelImage alt="Generated cover" src={imageSource} />
        <ChatPanelVideo alt="Generated clip" poster={imageSource} src={videoSource} />
      </>
    );

    const imageTrigger = screen.getByRole("button", {
      name: "Preview generated image",
    });
    await user.click(imageTrigger);
    expect(
      screen.getByRole("dialog", { name: "Generated image preview" })
    ).toBeInTheDocument();

    const previewBackdrop = document.querySelector(".chat-panel-media-preview-modal");
    expect(previewBackdrop).not.toBeNull();
    fireEvent.pointerDown(previewBackdrop!);
    await waitFor(() =>
      expect(
        screen.queryByRole("dialog", { name: "Generated image preview" })
      ).not.toBeInTheDocument()
    );
    expect(imageTrigger).toHaveFocus();

    await user.click(screen.getByRole("button", { name: "Full window" }));
    expect(
      screen.getByRole("dialog", { name: "Generated video preview" })
    ).toBeInTheDocument();
    expect(
      screen.getByRole("slider", { name: "Video playback position" })
    ).toBeInTheDocument();
  });

  it("uses display metadata to preserve video proportions across inline and preview", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <ChatPanelVideo alt="Portrait clip" poster={imageSource} src={videoSource} />
    );

    const inlineVideo = screen.getByLabelText("Portrait clip") as HTMLVideoElement;
    Object.defineProperties(inlineVideo, {
      videoHeight: { configurable: true, value: 1920 },
      videoWidth: { configurable: true, value: 1080 },
    });
    fireEvent.loadedMetadata(inlineVideo);

    const inlineFigure = container.querySelector<HTMLElement>(".chat-panel-video");
    expect(
      inlineFigure?.style.getPropertyValue("--chat-panel-video-aspect-ratio")
    ).toBe("0.5625");

    await user.click(screen.getByRole("button", { name: "Full window" }));
    const previewStage = screen
      .getByRole("dialog", { name: "Generated video preview" })
      .querySelector<HTMLElement>(".chat-panel-media-preview-stage");
    expect(
      previewStage?.style.getPropertyValue("--chat-panel-video-aspect-ratio")
    ).toBe("0.5625");
  });

  it("keeps the active media binding when a stale preview instance exits", async () => {
    const user = userEvent.setup();
    render(<MediaBindingHarness />);

    await user.click(screen.getByRole("button", { name: "Remove stale media" }));
    await user.click(screen.getByRole("button", { name: "Seek active media" }));

    expect((screen.getByTestId("active-media") as HTMLMediaElement).currentTime).toBe(
      7
    );
  });

  it("exposes the browser download adapter without invoking it from media components", async () => {
    const mediaBlob = new Blob(["generated audio"], { type: "audio/mpeg" });
    const fetchMedia = vi.fn().mockResolvedValue({
      blob: () => Promise.resolve(mediaBlob),
      ok: true,
      status: 200,
    });
    const createObjectUrl = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:generated-audio");
    const revokeObjectUrl = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => undefined);
    const clickAnchor = vi
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(() => undefined);
    vi.stubGlobal("fetch", fetchMedia);

    await downloadMediaSource({
      fileName: "generated-audio.mp3",
      source: audioSource,
    });

    await waitFor(() => expect(fetchMedia).toHaveBeenCalledWith(audioSource));
    expect(createObjectUrl).toHaveBeenCalledWith(mediaBlob);
    expect(clickAnchor).toHaveBeenCalledOnce();
    const anchor = clickAnchor.mock.instances[0] as HTMLAnchorElement;
    expect(anchor.download).toBe("generated-audio.mp3");
    expect(anchor.href).toBe("blob:generated-audio");
    expect(anchor.isConnected).toBe(false);
    await waitFor(() =>
      expect(revokeObjectUrl).toHaveBeenCalledWith("blob:generated-audio")
    );
  });

  it("only renders download controls when each media caller provides a capability", () => {
    const fetchMedia = vi.fn();
    vi.stubGlobal("fetch", fetchMedia);
    const { rerender } = render(
      <>
        <ChatPanelAudio src={audioSource} />
        <ChatPanelImage alt="Generated cover" src={imageSource} />
        <ChatPanelVideo alt="Generated clip" poster={imageSource} src={videoSource} />
      </>
    );

    expect(
      screen.queryByRole("button", { name: "Download audio" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Download image" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Download video" })
    ).not.toBeInTheDocument();
    expect(fetchMedia).not.toHaveBeenCalled();

    const execute = vi.fn().mockResolvedValue({ status: "success" });
    rerender(
      <>
        <ChatPanelAudio
          download={createDownloadAction("generated-audio.mp3", execute)}
          src={audioSource}
        />
        <ChatPanelImage
          alt="Generated cover"
          download={createDownloadAction("generated-image.png", execute)}
          src={imageSource}
        />
        <ChatPanelVideo
          alt="Generated clip"
          download={createDownloadAction("generated-video.mp4", execute)}
          poster={imageSource}
          src={videoSource}
        />
      </>
    );

    expect(screen.getByRole("button", { name: "Download audio" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Download image" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Download video" })).toBeInTheDocument();
    expect(fetchMedia).not.toHaveBeenCalled();
  });

  it("shares pending, retryable failure, retry, and success feedback across media", async () => {
    const user = userEvent.setup();
    let resolveFirstRequest!: (result: ChatPanelMediaDownloadResult) => void;
    const firstRequest = new Promise<ChatPanelMediaDownloadResult>((resolve) => {
      resolveFirstRequest = resolve;
    });
    const execute = vi
      .fn()
      .mockReturnValueOnce(firstRequest)
      .mockResolvedValueOnce({ status: "success" });
    const fetchMedia = vi.fn();
    vi.stubGlobal("fetch", fetchMedia);
    render(
      <ChatPanelAudio
        download={createDownloadAction("signed-audio.mp3", execute)}
        src="https://media.example.test/signed-audio.mp3"
      />
    );

    const downloadButton = screen.getByRole("button", { name: "Download audio" });
    downloadButton.focus();
    await user.keyboard("{Enter}");

    const pendingButton = screen.getByRole("button", {
      name: "Downloading audio",
    });
    expect(pendingButton).toHaveFocus();
    expect(pendingButton).not.toBeDisabled();
    expect(pendingButton).toHaveAttribute("aria-disabled", "true");
    expect(pendingButton).toHaveAttribute("aria-busy", "true");
    expect(pendingButton).not.toHaveAttribute("title");
    expect(screen.getByText("Downloading audio…")).toBeVisible();
    await user.keyboard("{Enter}");
    expect(execute).toHaveBeenCalledOnce();

    resolveFirstRequest({
      code: "network",
      retryable: true,
      status: "error",
    });

    expect(
      await screen.findByText("Could not download audio. Try again.")
    ).toBeVisible();
    const retryButton = screen.getByRole("button", {
      name: "Download audio failed. Try again",
    });
    expect(retryButton).toHaveFocus();
    expect(retryButton).not.toHaveAttribute("aria-disabled");
    expect(retryButton).not.toHaveAttribute("title");
    expect(retryButton).toHaveAttribute("data-download-state", "error");
    expect(retryButton.parentElement).toHaveAttribute("data-error-code", "network");
    expect(screen.getByText("Could not download audio. Try again.")).toHaveAttribute(
      "aria-live",
      "polite"
    );

    await user.keyboard("{Enter}");

    await waitFor(() =>
      expect(execute).toHaveBeenNthCalledWith(2, {
        fileName: "signed-audio.mp3",
        kind: "audio",
        source: "https://media.example.test/signed-audio.mp3",
      })
    );
    expect(await screen.findByText("Audio downloaded.")).toBeVisible();
    expect(
      screen.getByRole("button", { name: "Downloaded audio" })
    ).not.toHaveAttribute("title");
    expect(fetchMedia).not.toHaveBeenCalled();
  });

  it.each([
    {
      actionName: "Download audio",
      fileName: "generated-audio.mp3",
      kind: "audio",
      renderMedia: (download: ChatPanelMediaDownloadAction) => (
        <ChatPanelAudio download={download} src={audioSource} />
      ),
      source: audioSource,
    },
    {
      actionName: "Download image",
      fileName: "generated-image.png",
      kind: "image",
      renderMedia: (download: ChatPanelMediaDownloadAction) => (
        <ChatPanelImage alt="Generated cover" download={download} src={imageSource} />
      ),
      source: imageSource,
    },
    {
      actionName: "Download video",
      fileName: "generated-video.mp4",
      kind: "video",
      renderMedia: (download: ChatPanelMediaDownloadAction) => (
        <ChatPanelVideo
          alt="Generated clip"
          download={download}
          poster={imageSource}
          src={videoSource}
        />
      ),
      source: videoSource,
    },
  ])(
    "passes the typed $kind request to the shared app-owned capability",
    async ({ actionName, fileName, kind, renderMedia, source }) => {
      const user = userEvent.setup();
      const execute = vi.fn().mockResolvedValue({
        code: "unsupported",
        retryable: false,
        status: "error",
      });
      const fetchMedia = vi.fn();
      vi.stubGlobal("fetch", fetchMedia);
      render(renderMedia(createDownloadAction(fileName, execute)));

      await user.click(screen.getByRole("button", { name: actionName }));

      await waitFor(() =>
        expect(execute).toHaveBeenCalledWith({
          fileName,
          kind,
          source,
        })
      );
      const failedButton = screen.getByRole("button", {
        name: `${actionName} failed`,
      });
      expect(failedButton).toBeDisabled();
      expect(failedButton).not.toHaveAttribute("title");
      expect(screen.getByText(`Could not download ${kind}.`)).toBeVisible();
      expect(fetchMedia).not.toHaveBeenCalled();
    }
  );

  it("turns thrown capability failures into retryable visible feedback", async () => {
    const user = userEvent.setup();
    const execute = vi.fn().mockRejectedValue(new Error("native bridge unavailable"));
    render(
      <ChatPanelImage
        alt="Generated cover"
        download={createDownloadAction("generated-image.png", execute)}
        src={imageSource}
      />
    );

    await user.click(screen.getByRole("button", { name: "Download image" }));

    expect(
      await screen.findByText("Could not download image. Try again.")
    ).toBeVisible();
    expect(
      screen.getByRole("button", {
        name: "Download image failed. Try again",
      })
    ).toBeEnabled();
  });

  it("keeps download feedback when an inline capability object is recreated", async () => {
    const user = userEvent.setup();
    const execute = vi.fn().mockResolvedValue({
      code: "network",
      retryable: true,
      status: "error",
    });
    const renderAudio = () => (
      <ChatPanelAudio
        download={{
          capability: { execute },
          fileName: "generated-audio.mp3",
        }}
        src={audioSource}
      />
    );
    const { rerender } = render(renderAudio());

    await user.click(screen.getByRole("button", { name: "Download audio" }));
    expect(
      await screen.findByText("Could not download audio. Try again.")
    ).toBeVisible();

    rerender(renderAudio());

    expect(screen.getByText("Could not download audio. Try again.")).toBeVisible();
    expect(
      screen.getByRole("button", {
        name: "Download audio failed. Try again",
      })
    ).toBeEnabled();
  });

  it("resets a terminal failure when the capability executor changes", async () => {
    const user = userEvent.setup();
    const firstExecute = vi.fn().mockResolvedValue({
      code: "unsupported",
      retryable: false,
      status: "error",
    });
    const nextExecute = vi.fn().mockResolvedValue({ status: "success" });
    const renderAudio = (
      execute: ChatPanelMediaDownloadAction["capability"]["execute"]
    ) => (
      <ChatPanelAudio
        download={createDownloadAction("generated-audio.mp3", execute)}
        src={audioSource}
      />
    );
    const { rerender } = render(renderAudio(firstExecute));

    await user.click(screen.getByRole("button", { name: "Download audio" }));
    expect(
      await screen.findByRole("button", { name: "Download audio failed" })
    ).toBeDisabled();

    rerender(renderAudio(nextExecute));

    const recoveredButton = screen.getByRole("button", { name: "Download audio" });
    expect(recoveredButton).toBeEnabled();
    await user.click(recoveredButton);

    await waitFor(() => expect(nextExecute).toHaveBeenCalledOnce());
    expect(await screen.findByText("Audio downloaded.")).toBeVisible();
  });

  it("ignores a stale download result after the media source changes", async () => {
    const user = userEvent.setup();
    vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => undefined);
    let resolveRequest!: (result: ChatPanelMediaDownloadResult) => void;
    const execute = vi.fn(
      () =>
        new Promise<ChatPanelMediaDownloadResult>((resolve) => {
          resolveRequest = resolve;
        })
    );
    const download = createDownloadAction("generated-audio.mp3", execute);
    const { rerender } = render(
      <ChatPanelAudio download={download} src="generated-audio-v1.mp3" />
    );

    await user.click(screen.getByRole("button", { name: "Download audio" }));
    expect(screen.getByText("Downloading audio…")).toBeVisible();

    rerender(<ChatPanelAudio download={download} src="generated-audio-v2.mp3" />);
    resolveRequest({
      code: "network",
      retryable: true,
      status: "error",
    });

    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Download audio" })).toBeInTheDocument()
    );
    expect(
      screen.queryByText("Could not download audio. Try again.")
    ).not.toBeInTheDocument();
  });

  it("does not simulate playback without a bound media element", async () => {
    const user = userEvent.setup();
    render(<DetachedPlaybackHarness />);

    await user.click(screen.getByRole("button", { name: "Play detached media" }));

    expect(
      screen.getByRole("button", { name: "Play detached media" })
    ).toBeInTheDocument();
  });

  it("returns to the paused state when the current play request rejects", async () => {
    const user = userEvent.setup();
    let rejectPlay!: (reason?: unknown) => void;
    const playRequest = new Promise<void>((_resolve, reject) => {
      rejectPlay = reject;
    });
    vi.spyOn(HTMLMediaElement.prototype, "play").mockReturnValue(playRequest);
    render(<ChatPanelAudio src={audioSource} />);

    await user.click(screen.getByRole("button", { name: "Play audio" }));
    expect(screen.getByRole("button", { name: "Pause audio" })).toBeInTheDocument();

    await act(async () => {
      rejectPlay(new DOMException("Playback was denied.", "NotAllowedError"));
      await playRequest.catch(() => undefined);
    });

    expect(screen.getByRole("button", { name: "Play audio" })).toBeInTheDocument();
  });

  it("retries a transiently aborted play request without dropping playback intent", async () => {
    const user = userEvent.setup();
    let rejectFirstPlay!: (reason?: unknown) => void;
    const firstPlayRequest = new Promise<void>((_resolve, reject) => {
      rejectFirstPlay = reject;
    });
    const play = vi
      .spyOn(HTMLMediaElement.prototype, "play")
      .mockReturnValueOnce(firstPlayRequest)
      .mockResolvedValueOnce(undefined);
    const { container } = render(<ChatPanelAudio src={audioSource} />);
    const audio = container.querySelector("audio");
    expect(audio).not.toBeNull();

    await user.click(screen.getByRole("button", { name: "Play audio" }));
    fireEvent.pause(audio!);

    await act(async () => {
      rejectFirstPlay(
        new DOMException("Playback was temporarily interrupted.", "AbortError")
      );
      await firstPlayRequest.catch(() => undefined);
    });

    await waitFor(() => expect(play).toHaveBeenCalledTimes(2));
    expect(screen.getByRole("button", { name: "Pause audio" })).toBeInTheDocument();
  });

  it("stops retrying after the transient play retry budget is exhausted", async () => {
    const user = userEvent.setup();
    const playRequests: Array<{
      promise: Promise<void>;
      reject: (reason?: unknown) => void;
    }> = [];
    const play = vi.spyOn(HTMLMediaElement.prototype, "play").mockImplementation(() => {
      let rejectPlay!: (reason?: unknown) => void;
      const promise = new Promise<void>((_resolve, reject) => {
        rejectPlay = reject;
      });
      playRequests.push({ promise, reject: rejectPlay });
      return promise;
    });
    const { container } = render(<ChatPanelAudio src={audioSource} />);
    const audio = container.querySelector("audio");
    expect(audio).not.toBeNull();

    await user.click(screen.getByRole("button", { name: "Play audio" }));

    for (let attempt = 0; attempt < 3; attempt += 1) {
      fireEvent.play(audio!);
      fireEvent.pause(audio!);
      const request = playRequests[attempt];
      expect(request).toBeDefined();
      await act(async () => {
        request!.reject(
          new DOMException("Playback was temporarily interrupted.", "AbortError")
        );
        await request!.promise.catch(() => undefined);
      });
      if (attempt < 2) {
        await waitFor(() => expect(play).toHaveBeenCalledTimes(attempt + 2));
      }
    }

    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Play audio" })).toBeInTheDocument()
    );
    expect(play).toHaveBeenCalledTimes(3);
  });

  it("cancels an in-flight play request instead of starting a second one", async () => {
    const user = userEvent.setup();
    let resolvePlay!: () => void;
    const playRequest = new Promise<void>((resolve) => {
      resolvePlay = resolve;
    });
    const play = vi
      .spyOn(HTMLMediaElement.prototype, "play")
      .mockReturnValue(playRequest);
    const pause = vi
      .spyOn(HTMLMediaElement.prototype, "pause")
      .mockImplementation(() => undefined);
    const { container } = render(<ChatPanelAudio src={audioSource} />);
    const audio = container.querySelector("audio");
    expect(audio).not.toBeNull();

    await user.click(screen.getByRole("button", { name: "Play audio" }));
    await user.click(screen.getByRole("button", { name: "Pause audio" }));

    expect(play).toHaveBeenCalledOnce();
    expect(pause).toHaveBeenCalledOnce();
    expect(screen.getByRole("button", { name: "Play audio" })).toBeInTheDocument();

    await act(async () => {
      resolvePlay();
      await playRequest;
    });
    fireEvent.play(audio!);

    expect(pause.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(screen.getByRole("button", { name: "Play audio" })).toBeInTheDocument();
  });

  it("resets playback intent, time, and speed when the source changes in place", async () => {
    const user = userEvent.setup();
    vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
    const pause = vi
      .spyOn(HTMLMediaElement.prototype, "pause")
      .mockImplementation(() => undefined);
    const { container, rerender } = render(
      <ChatPanelAudio src="generated-audio-a.mp3" />
    );
    const audio = container.querySelector("audio");
    expect(audio).not.toBeNull();

    await user.click(screen.getByRole("button", { name: "Play audio" }));
    await user.click(screen.getByRole("button", { name: "Playback speed 1x" }));
    await user.click(screen.getByRole("menuitemradio", { name: "2x" }));
    fireEvent.change(screen.getByRole("slider", { name: "Audio playback position" }), {
      target: { value: "7" },
    });

    expect(screen.getByRole("button", { name: "Pause audio" })).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Playback speed 2x" })
    ).toBeInTheDocument();

    rerender(<ChatPanelAudio src="generated-audio-b.mp3" />);

    expect(container.querySelector("audio")).toBe(audio);
    expect(screen.getByRole("button", { name: "Play audio" })).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Playback speed 1x" })
    ).toBeInTheDocument();
    expect(screen.getAllByText("00:00").length).toBeGreaterThan(0);
    expect(audio!.currentTime).toBe(0);
    expect(audio!.playbackRate).toBe(1);
    expect(pause).toHaveBeenCalled();

    fireEvent.loadedMetadata(audio!);
    audio!.playbackRate = 1.25;
    fireEvent.rateChange(audio!);
    expect(
      screen.getByRole("button", { name: "Playback speed 1.25x" })
    ).toBeInTheDocument();

    fireEvent.emptied(audio!);
    expect(
      screen.getByRole("button", { name: "Playback speed 1x" })
    ).toBeInTheDocument();
  });

  it("keeps a successful preview handoff playing when the stale play rejects", async () => {
    const user = userEvent.setup();
    let rejectStalePlay!: (reason?: unknown) => void;
    let resolvePreviewPlay!: () => void;
    const stalePlay = new Promise<void>((_resolve, reject) => {
      rejectStalePlay = reject;
    });
    const previewPlay = new Promise<void>((resolve) => {
      resolvePreviewPlay = resolve;
    });
    const play = vi
      .spyOn(HTMLMediaElement.prototype, "play")
      .mockImplementationOnce(() => stalePlay)
      .mockImplementationOnce(() => previewPlay);
    const pause = vi
      .spyOn(HTMLMediaElement.prototype, "pause")
      .mockImplementation(() => undefined);

    render(
      <ChatPanelVideo
        alt="Generated clip"
        defaultPlaying
        poster={imageSource}
        src={videoSource}
      />
    );

    const inlineVideo = screen.getByLabelText("Generated clip") as HTMLVideoElement;
    Object.defineProperty(inlineVideo, "paused", {
      configurable: true,
      value: false,
    });
    inlineVideo.currentTime = 6;
    fireEvent.timeUpdate(inlineVideo);

    await user.click(screen.getByRole("button", { name: "Full window" }));

    const dialog = screen.getByRole("dialog", {
      name: "Generated video preview",
    });
    const previewVideo = dialog.querySelector("video");
    expect(previewVideo).not.toBeNull();
    expect(previewVideo!.currentTime).toBe(6);
    expect(play).toHaveBeenCalledTimes(2);
    expect(pause.mock.instances).toContain(inlineVideo);

    await act(async () => {
      resolvePreviewPlay();
      fireEvent.play(previewVideo!);
      rejectStalePlay(new DOMException("The old play was interrupted.", "AbortError"));
      await Promise.allSettled([stalePlay, previewPlay]);
    });

    expect(
      dialog.querySelector('button[aria-label="Pause video"]')
    ).toBeInTheDocument();
  });

  it("shows hover-only control tooltips with shortcuts and download size", async () => {
    const user = userEvent.setup();
    render(
      <ChatPanelAudio
        download={createDownloadAction(
          "generated-audio.mp3",
          () => ({ status: "success" }),
          2 * 1024 * 1024
        )}
        src={audioSource}
      />
    );

    setInteractionModality("pointer");
    await user.hover(screen.getByRole("button", { name: "Play audio" }));
    expect(await screen.findByRole("tooltip", { name: /Play/ })).toHaveTextContent(
      "Play"
    );
    expect(screen.getByLabelText("Keyboard shortcut: Space")).toBeInTheDocument();

    await user.unhover(screen.getByRole("button", { name: "Play audio" }));
    await user.hover(screen.getByRole("button", { name: "Volume 100%" }));
    expect(await screen.findByRole("tooltip", { name: /Mute/ })).toHaveTextContent(
      "Mute"
    );
    expect(screen.getByLabelText("Keyboard shortcut: M")).toBeInTheDocument();

    await user.unhover(screen.getByRole("button", { name: "Volume 100%" }));
    await user.hover(screen.getByRole("button", { name: "Playback speed 1x" }));
    expect(
      await screen.findByRole("tooltip", { name: /Playback speed/ })
    ).toHaveTextContent("Playback speed");
    expect(screen.getByLabelText("Keyboard shortcut: < >")).toBeInTheDocument();

    await user.unhover(screen.getByRole("button", { name: "Playback speed 1x" }));
    await user.hover(screen.getByRole("button", { name: "Download audio" }));
    expect(await screen.findByRole("tooltip", { name: /Download/ })).toHaveTextContent(
      "Download"
    );
    expect(screen.getByRole("tooltip")).toHaveTextContent("2MB");
  });

  it("toggles playback from Space without opening a tooltip", async () => {
    const user = userEvent.setup();
    vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
    vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => undefined);
    render(<ChatPanelAudio src={audioSource} />);

    const playButton = screen.getByRole("button", { name: "Play audio" });
    playButton.focus();
    await user.keyboard(" ");

    expect(screen.getByRole("button", { name: "Pause audio" })).toBeInTheDocument();
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("mutes from M without opening the volume popover or a tooltip", async () => {
    const user = userEvent.setup();
    render(<ChatPanelAudio src={audioSource} />);

    screen.getByRole("button", { name: "Play audio" }).focus();
    await user.keyboard("m");

    expect(
      screen.getByRole("button", { name: "Muted. Change volume" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("steps playback speed from < and > without opening the menu or a tooltip", async () => {
    const user = userEvent.setup();
    render(<ChatPanelAudio src={audioSource} />);

    screen.getByRole("button", { name: "Play audio" }).focus();
    await user.keyboard(">");
    expect(
      screen.getByRole("button", { name: "Playback speed 1.25x" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("menu")).toBeNull();
    expect(screen.queryByRole("tooltip")).toBeNull();

    await user.keyboard("<");
    expect(
      screen.getByRole("button", { name: "Playback speed 1x" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("plays from Space on the progress slider without opening a tooltip", async () => {
    const user = userEvent.setup();
    vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
    render(<ChatPanelAudio src={audioSource} />);

    screen.getByRole("slider", { name: "Audio playback position" }).focus();
    await user.keyboard(" ");

    expect(screen.getByRole("button", { name: "Pause audio" })).toBeInTheDocument();
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it.each([
    {
      expectedShortcut: "⌘ Click",
      modifier: { metaKey: true },
      platform: "MacIntel",
      wrongModifier: { ctrlKey: true },
    },
    {
      expectedShortcut: "Ctrl Click",
      modifier: { ctrlKey: true },
      platform: "Win32",
      wrongModifier: { metaKey: true },
    },
    {
      expectedShortcut: "Ctrl Click",
      modifier: { ctrlKey: true },
      platform: "Linux x86_64",
      wrongModifier: { metaKey: true },
    },
  ])(
    "uses the platform modifier for Full window on $platform",
    async ({ expectedShortcut, modifier, platform, wrongModifier }) => {
      vi.spyOn(window.navigator, "platform", "get").mockReturnValue(platform);
      const user = userEvent.setup();
      render(
        <ChatPanelVideo alt="Generated clip" poster={imageSource} src={videoSource} />
      );

      setInteractionModality("pointer");
      await user.hover(screen.getByRole("button", { name: "Full window" }));
      expect(
        await screen.findByRole("tooltip", { name: /Full window/ })
      ).toHaveTextContent("Full window");
      expect(
        screen.getByLabelText(`Keyboard shortcut: ${expectedShortcut}`)
      ).toBeInTheDocument();

      const video = screen.getByLabelText("Generated clip");
      fireEvent.click(video, wrongModifier);
      expect(screen.queryByRole("dialog")).toBeNull();

      fireEvent.click(video, modifier);
      expect(
        screen.getByRole("dialog", { name: "Generated video preview" })
      ).toBeInTheDocument();
    }
  );

  it("shows the Full window tooltip on the video expand control", async () => {
    vi.spyOn(window.navigator, "platform", "get").mockReturnValue("MacIntel");
    const user = userEvent.setup();
    render(
      <ChatPanelVideo alt="Generated clip" poster={imageSource} src={videoSource} />
    );

    setInteractionModality("pointer");
    await user.hover(screen.getByRole("button", { name: "Full window" }));

    expect(
      await screen.findByRole("tooltip", { name: /Full window/ })
    ).toHaveTextContent("Full window");
    expect(screen.getByLabelText("Keyboard shortcut: ⌘ Click")).toBeInTheDocument();
  });

  it("does not show the Full window tooltip when hovering the video surface", async () => {
    const user = userEvent.setup();
    render(
      <ChatPanelVideo alt="Generated clip" poster={imageSource} src={videoSource} />
    );

    setInteractionModality("pointer");
    await user.hover(screen.getByLabelText("Generated clip"));

    expect(screen.queryByRole("tooltip")).toBeNull();
  });
});
