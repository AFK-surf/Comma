import userEvent from "@testing-library/user-event";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ChatPanelVideo } from "../ChatPanelMedia";
import {
  ChatPanelVideoPictureInPictureProvider,
  ChatPanelVideoSurfaceProvider,
} from "../ChatPanelVideoPictureInPicture";

const poster =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='32' height='32'/%3E";
const windowName = (title: string) => `Picture in picture: ${title}`;

/** Lets a test say when a player's frame is in view, the way the browser would. */
const observed = new Map<Element, IntersectionObserverCallback>();
class ControlledIntersectionObserver implements IntersectionObserver {
  readonly root = null;
  readonly rootMargin = "0px";
  readonly scrollMargin = "0px";
  readonly thresholds = [0];
  constructor(private callback: IntersectionObserverCallback) {}
  observe(target: Element) {
    observed.set(target, this.callback);
  }
  unobserve(target: Element) {
    observed.delete(target);
  }
  disconnect() {
    observed.clear();
  }
  takeRecords() {
    return [];
  }
}

const setInView = (figure: Element, isIntersecting: boolean) =>
  act(() => {
    const rect = figure.getBoundingClientRect();
    observed.get(figure)?.(
      [
        {
          boundingClientRect: rect,
          intersectionRatio: isIntersecting ? 1 : 0,
          intersectionRect: rect,
          isIntersecting,
          rootBounds: null,
          target: figure,
          time: performance.now(),
        },
      ],
      {} as IntersectionObserver
    );
  });

const renderVideo = (title: string) =>
  render(
    <ChatPanelVideoPictureInPictureProvider>
      <ChatPanelVideo
        alt={title}
        poster={poster}
        previewTitle={title}
        src={`${title}.mp4`}
      />
    </ChatPanelVideoPictureInPictureProvider>
  );

/** A retained surface, like Home, that stays mounted while another page shows. */
const RetainedSurface = ({
  reveal,
  revealPlayer,
  visible,
}: {
  reveal: () => void;
  revealPlayer: (player: HTMLElement) => void;
  visible: boolean;
}) => (
  <ChatPanelVideoPictureInPictureProvider>
    <ChatPanelVideoSurfaceProvider
      returnLabel="Jump to message"
      reveal={reveal}
      revealPlayer={revealPlayer}
      visible={visible}
    >
      <ChatPanelVideo
        alt="Home clip"
        poster={poster}
        previewTitle="Home clip"
        src="home.mp4"
      />
    </ChatPanelVideoSurfaceProvider>
  </ChatPanelVideoPictureInPictureProvider>
);

const startPlaying = async (title: string) => {
  const figure = screen.getByLabelText(title).closest("figure")!;
  await userEvent.click(within(figure).getByRole("button", { name: "Play video" }));
  await waitFor(() =>
    expect(within(figure).getByRole("button", { name: "Pause video" })).toBeVisible()
  );
  return figure;
};

beforeEach(() => {
  vi.stubGlobal("IntersectionObserver", ControlledIntersectionObserver);
  vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
  Element.prototype.scrollIntoView = vi.fn();
});

afterEach(() => {
  observed.clear();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  Reflect.deleteProperty(Element.prototype, "scrollIntoView");
});

describe("ChatPanelVideo picture in picture", () => {
  it("moves the playing video element into a window that stays until the reader ends it", async () => {
    renderVideo("Launch clip");
    const figure = await startPlaying("Launch clip");
    const video = screen.getByLabelText("Launch clip");

    setInView(figure, false);
    const floating = screen.getByRole("region", { name: windowName("Launch clip") });
    expect(floating).toContainElement(video);
    expect(figure).not.toContainElement(video);
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledOnce();

    // Scrolling back does not take the video out of the window.
    setInView(figure, true);
    expect(floating).toContainElement(video);
    expect(within(figure).getByText("Playing in picture in picture")).toBeVisible();

    await userEvent.click(within(figure).getByRole("button", { name: "Play here" }));
    expect(screen.queryByRole("region")).not.toBeInTheDocument();
    expect(figure).toContainElement(video);
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledOnce();
  });

  it("leaves a paused video in its frame and closes the window by pausing", async () => {
    const pause = vi
      .spyOn(HTMLMediaElement.prototype, "pause")
      .mockImplementation(() => undefined);
    renderVideo("Paused clip");
    const figure = screen.getByLabelText("Paused clip").closest("figure")!;

    setInView(figure, false);
    expect(screen.queryByRole("region")).not.toBeInTheDocument();

    setInView(figure, true);
    await startPlaying("Paused clip");
    setInView(figure, false);
    await userEvent.click(
      within(screen.getByRole("region", { name: windowName("Paused clip") })).getByRole(
        "button",
        { name: "Close" }
      )
    );

    expect(pause).toHaveBeenCalled();
    expect(screen.queryByRole("region")).not.toBeInTheDocument();
    expect(figure).toContainElement(screen.getByLabelText("Paused clip"));
    expect(within(figure).getByRole("button", { name: "Play video" })).toBeVisible();
  });

  it("jumps back through the surface, first putting a hidden surface on screen", async () => {
    const reveal = vi.fn();
    const revealPlayer = vi.fn();
    const { rerender } = render(
      <RetainedSurface reveal={reveal} revealPlayer={revealPlayer} visible />
    );
    const figure = await startPlaying("Home clip");

    // Another page shows while the surface stays mounted with its frame in view.
    rerender(
      <RetainedSurface reveal={reveal} revealPlayer={revealPlayer} visible={false} />
    );
    expect(screen.getByRole("region", { name: windowName("Home clip") })).toBeVisible();
    // Coming back by other means keeps the window; the reader decides.
    rerender(<RetainedSurface reveal={reveal} revealPlayer={revealPlayer} visible />);
    rerender(
      <RetainedSurface reveal={reveal} revealPlayer={revealPlayer} visible={false} />
    );
    await userEvent.click(
      within(screen.getByRole("region", { name: windowName("Home clip") })).getByRole(
        "button",
        { name: "Jump to message" }
      )
    );
    expect(reveal).toHaveBeenCalledOnce();
    expect(revealPlayer).not.toHaveBeenCalled();
    expect(screen.queryByRole("region")).not.toBeInTheDocument();
    expect(figure).toContainElement(screen.getByLabelText("Home clip"));

    rerender(<RetainedSurface reveal={reveal} revealPlayer={revealPlayer} visible />);
    await waitFor(() => expect(revealPlayer).toHaveBeenCalledWith(figure));
  });

  it("scrolls a player back into view and opens Full window from the window", async () => {
    renderVideo("Drive clip");
    const figure = await startPlaying("Drive clip");

    setInView(figure, false);
    await userEvent.click(
      within(screen.getByRole("region", { name: windowName("Drive clip") })).getByRole(
        "button",
        { name: "Back to video" }
      )
    );
    await waitFor(() => expect(figure.scrollIntoView).toHaveBeenCalled());
    // Still out of view while the scroll runs, yet brought back: no window.
    expect(screen.queryByRole("region")).not.toBeInTheDocument();

    // Seen in its frame, it floats again the next time it leaves the view.
    setInView(figure, true);
    setInView(figure, false);
    await userEvent.click(
      within(screen.getByRole("region", { name: windowName("Drive clip") })).getByRole(
        "button",
        { name: "Full window" }
      )
    );
    expect(await screen.findByRole("dialog", { name: "Drive clip" })).toBeVisible();
    expect(screen.queryByRole("region")).not.toBeInTheDocument();
  });

  it("shows one window at a time and pauses the video it sends home", async () => {
    const pause = vi
      .spyOn(HTMLMediaElement.prototype, "pause")
      .mockImplementation(() => undefined);
    render(
      <ChatPanelVideoPictureInPictureProvider>
        <ChatPanelVideo
          alt="First clip"
          poster={poster}
          previewTitle="First clip"
          src="a.mp4"
        />
        <ChatPanelVideo
          alt="Second clip"
          poster={poster}
          previewTitle="Second clip"
          src="b.mp4"
        />
      </ChatPanelVideoPictureInPictureProvider>
    );
    const first = await startPlaying("First clip");
    setInView(first, false);
    expect(
      screen.getByRole("region", { name: windowName("First clip") })
    ).toBeVisible();

    const second = await startPlaying("Second clip");
    setInView(second, false);

    expect(screen.getAllByRole("region")).toHaveLength(1);
    expect(
      screen.getByRole("region", { name: windowName("Second clip") })
    ).toBeVisible();
    expect(first).toContainElement(screen.getByLabelText("First clip"));
    expect(within(first).getByRole("button", { name: "Play video" })).toBeVisible();
    expect(pause).toHaveBeenCalled();
  });
});
