import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { act, cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { userEvent } from "vitest/browser";
import {
  DraftSelectionsProvider,
  useConversationDraftSelections,
  type ChatDraftSelection,
} from "../../chat/composer/draftSelections";
import {
  ChatSidebarProvider,
  screenPageId,
  useChatSidebar,
  useRegisterChatSidebarHost,
  type ChatSidebarContextValue,
  type ChatSidebarScreenPage,
} from "../../chat-sidebar/ChatSidebarContext";
import { DeviceScreenPanel } from "../DeviceScreenPanel";
import { openMeshScreenStream } from "../meshScreenStream";
import type { ScreenStreamSource } from "../ScreenStreamStage";
import { fakeDeviceCapabilities, fakePhone } from "./fakeScreenDevice";

// Ask Comma holds the screen's frame to be inspected. A selection on it (an area, or the whole screen) and what the
// person writes about it go to the composer of the chat beside the screen, where they wait as an attachment.

const chat = vi.hoisted(() => ({
  /** The chat cannot be reached: what asks of it fails. */
  fail: false,
  toasts: [] as string[],
  /** Called as the panel says something (a toast). */
  onToast: () => undefined as void,
}));
vi.mock("@comma/ui/components/toast", async (actual) => {
  const real = await actual<typeof import("@comma/ui/components/toast")>();
  const said = (_: unknown, options?: { testId?: string }) => {
    chat.toasts.push(options?.testId ?? "");
    chat.onToast();
    return "";
  };
  return { ...real, toast: { ...real.toast, error: said, warning: said } };
});

vi.mock("../meshScreenStream", () => ({ openMeshScreenStream: vi.fn() }));
vi.mock("../useDeviceScreenSource", () => ({ useDeviceScreenSource: () => source }));
vi.mock("@tanstack/react-router", async (actual) => ({
  ...(await actual<typeof import("@tanstack/react-router")>()),
  useNavigate: () => () => Promise.resolve(),
}));
vi.mock("../../chat/ChatProvider", async (actual) => {
  const registry = {
    beginAttempt: () => ({
      signal: new AbortController().signal,
      isCurrent: () => true,
      release: () => undefined,
      run: <T,>(operation: (signal: AbortSignal) => T) =>
        chat.fail
          ? Promise.reject(new Error("Chat is unavailable."))
          : Promise.resolve(operation(new AbortController().signal)),
    }),
    getHomeConversationTarget: () => undefined,
  };
  return {
    ...(await actual<typeof import("../../chat/ChatProvider")>()),
    useOptionalChatRegistry: () => registry,
  };
});

let source: ScreenStreamSource;
const macSource: ScreenStreamSource = {
  key: "workspace\nmac\nsim",
  view: { open: () => new Promise(() => undefined), send: () => undefined },
};

// A Mac's whole display: the panel's toolbar is the same on every screen.
const target: Omit<ChatSidebarScreenPage, "id"> = {
  workspaceId: "workspace",
  device: "mac",
  apps: [],
  target: "display",
};
const page: ChatSidebarScreenPage = { ...target, id: screenPageId(target) };
const host = { workspaceId: "workspace", groupId: "group", conversationId: "chat" };

/** What waits in each chat's composer, as the panel staged it. */
const staged: Record<string, readonly ChatDraftSelection[]> = {};

// (a view's stream is kept a while after its panel goes: each test has its own)
let sources = 0;
beforeEach(() => {
  source = { ...macSource, key: `workspace\nmac\nsim${++sources}` };
});

afterEach(() => {
  cleanup();
  chat.fail = false;
  chat.toasts.length = 0;
  chat.onToast = () => undefined;
  for (const conversation of Object.keys(staged)) delete staged[conversation];
});

/** The conversation route the panel shows beside: it registers its chat as the sidebar's host. */
function Sidebar({ onSidebar }: { onSidebar(sidebar: ChatSidebarContextValue): void }) {
  useRegisterChatSidebarHost(host);
  onSidebar(useChatSidebar());
  return null;
}

/** A chat's composer, as far as these tests look: what is staged for its next message. */
function Staged({ conversation }: { conversation: string }) {
  const { items } = useConversationDraftSelections(conversation);
  staged[conversation] = items;
  return <output data-conversation={conversation} data-staged={items.length} />;
}

/** The chat session round the panel: its sidebar, and the composers of the chat beside it and of another. */
function Chats({
  onSidebar,
  children,
}: {
  onSidebar(sidebar: ChatSidebarContextValue): void;
  children: ReactNode;
}) {
  return (
    <ChatSidebarProvider>
      <DraftSelectionsProvider>
        <Sidebar onSidebar={onSidebar} />
        <Staged conversation="chat" />
        <Staged conversation="other-chat" />
        {children}
      </DraftSelectionsProvider>
    </ChatSidebarProvider>
  );
}

/** The panel on its page, beside the chat; `size`: the room it has. */
function panel(size?: { width: number; height: number }) {
  let sidebar: ChatSidebarContextValue | undefined;
  const core = createScriptedCore({ values: () => undefined });
  const view = render(
    core.wrap(
      <Chats onSidebar={(value) => (sidebar = value)}>
        {size ? (
          <div style={{ display: "flex", ...size }}>
            <DeviceScreenPanel active page={page} />
          </div>
        ) : (
          <DeviceScreenPanel active page={page} />
        )}
      </Chats>
    )
  );
  act(() => sidebar!.openScreen(host, target));
  return { view, sidebar: () => sidebar! };
}

/** A stream of `canvas` for every view the panel opens, live at once. What is sent to the screen is kept in `sent`. */
function streaming(canvas: HTMLCanvasElement, sent: unknown[] = []) {
  const media = canvas.captureStream(0);
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    queueMicrotask(() => {
      peer.onStream(media);
      peer.onState("live");
    });
    return { send: (input) => sent.push(input), close: () => undefined };
  });
  return sent;
}

/** A canvas of one colour. */
function filled(width: number, height: number, color = "#0000ff") {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const draw = canvas.getContext("2d")!;
  draw.fillStyle = color;
  draw.fillRect(0, 0, width, height);
  return canvas;
}

/** Until the panel's video knows its frame's size (media events do not bubble: caught on their way down). */
const shown = () =>
  new Promise<void>((resolve) => {
    if ((document.querySelector("video")?.videoWidth ?? 0) > 0) return resolve();
    document.addEventListener("loadedmetadata", () => resolve(), {
      capture: true,
      once: true,
    });
  });

/** Until the page shows it: the page changing is what is waited on, with no deadline of its own. */
async function untilPage(what: () => boolean) {
  while (!what())
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document.body, {
        attributes: true,
        childList: true,
        subtree: true,
        characterData: true,
      });
    });
}

const held = () =>
  document.querySelector<HTMLElement>('[data-testid="remote-screen-mark"]');
const surface = () =>
  held()!.querySelector('[data-testid="remote-screen-mark-surface"]') as SVGSVGElement;
const composer = () =>
  held()?.querySelector<HTMLElement>('[data-testid="remote-screen-mark-composer"]') ??
  null;

/**
 * Writes `text` in the composer by what is selected on the held frame, and confirms it. With nothing selected yet,
 * the whole screen is, by a press on the frame: the composer shows only once something is.
 */
async function askAbout(text: string) {
  if (!composer()) await userEvent.click(surface() as unknown as HTMLElement);
  await userEvent.type(held()!.querySelector<HTMLElement>('[role="textbox"]')!, text);
  await userEvent.click(
    held()!.querySelector<HTMLElement>("button[data-submit-state]")!
  );
}

/** A promise settled by the next call of `set`'s callback. */
function next(set: (callback: () => void) => void) {
  return new Promise<void>((resolve) => set(resolve));
}

/** A staged selection's picture, as an image file. */
const pictureOf = (selection: ChatDraftSelection) =>
  new Blob([selection.picture!.bytes as Uint8Array<ArrayBuffer>], {
    type: selection.picture!.type,
  });

/** The picture's pixel at (x, y), as RGBA. */
async function pixel(png: Blob, x: number, y: number) {
  const bitmap = await createImageBitmap(png);
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
  const context = canvas.getContext("2d")!;
  context.drawImage(bitmap, 0, 0);
  return {
    width: bitmap.width,
    height: bitmap.height,
    rgba: [...context.getImageData(x, y, 1, 1).data],
  };
}

/** A drag on the frame's surface from one place of the frame to another, in the frame's own pixels. */
function dragOnFrame(from: { x: number; y: number }, to: { x: number; y: number }) {
  const on = surface();
  const matrix = on.getScreenCTM()!;
  const client = (at: { x: number; y: number }) => ({
    clientX: matrix.a * at.x + matrix.e,
    clientY: matrix.d * at.y + matrix.f,
  });
  const fire = (type: string, at: { x: number; y: number }) =>
    on.dispatchEvent(
      new PointerEvent(type, {
        ...client(at),
        bubbles: true,
        button: 0,
        pointerId: 7,
        isPrimary: true,
      })
    );
  act(() => {
    fire("pointerdown", from);
    fire("pointermove", to);
    fire("pointerup", to);
  });
}

/** Where the stream lays a picture of this size: its shape, as large as its video takes, in the video's middle. */
function pictureShown(width: number, height: number) {
  const playing = document.querySelector("video")!.getBoundingClientRect();
  const scale = Math.min(playing.width / width, playing.height / height);
  return {
    left: playing.left + (playing.width - width * scale) / 2,
    top: playing.top + (playing.height - height * scale) / 2,
    width: width * scale,
    height: height * scale,
  };
}

/** Whether the held frame lies on `live`, to a twentieth of a pixel. */
function heldOver(live: ReturnType<typeof pictureShown>) {
  const frame = surface().getBoundingClientRect();
  return (["left", "top", "width", "height"] as const).every(
    (side) => Math.abs(frame[side] - live[side]) < 0.05
  );
}

it("puts the whole screen and what is asked about it into the composer of the chat beside it, the frame at its own size, naming the screen", async () => {
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    return { send: () => undefined, close: () => undefined };
  });
  const { view } = panel({ width: 240, height: 360 });
  const ask = view.getByRole("button", { name: "Ask Comma" });
  // Nothing shows yet: there is nothing to ask about.
  expect(ask).toBeDisabled();

  // A 400×200 frame, red on its left half: the panel shows it smaller than it is.
  const canvas = filled(400, 200);
  const draw = canvas.getContext("2d")!;
  draw.fillStyle = "#ff0000";
  draw.fillRect(0, 0, 200, 200);
  act(() => {
    opened[0]!.onStream(canvas.captureStream(0));
    opened[0]!.onState("live");
  });
  await shown();

  await userEvent.click(ask);
  await askAbout("What is wrong here?");
  await untilPage(() => staged.chat?.length === 1);
  const [selection] = staged.chat!;
  expect(selection).toMatchObject({
    note: "What is wrong here?",
    about: { kind: "screen", device: "mac", screen: "display" },
    picture: { type: "image/png" },
  });
  expect(selection!.thumbnail).toMatch(/^data:image\/png;base64,/u);
  const picture = pictureOf(selection!);
  const left = await pixel(picture, 50, 100);
  const right = await pixel(picture, 350, 100);
  expect([left.width, left.height]).toEqual([400, 200]);
  expect(left.rgba).toEqual([255, 0, 0, 255]);
  expect(right.rgba).toEqual([0, 0, 255, 255]);
  // It waits in the chat's composer; the frame stays held for the next selection, with nothing selected.
  expect(held()).not.toBeNull();
  expect(composer()).toBeNull();
  expect(ask).toHaveAttribute("aria-pressed", "true");
});

it.each([
  // A 2:1 frame in the stage; a phone's own shape in its body.
  ["a Mac's display", undefined, [400, 200]],
  ["a device in its body", fakeDeviceCapabilities(fakePhone), [390, 840]],
] as const)(
  "on %s, holds the frame where the stream showed it, so that nothing moves",
  async (_, capabilities, [width, height]) => {
    if (capabilities) source = { ...source, capabilities };
    streaming(filled(width, height, "#000000"));
    const { view } = panel({ width: 400, height: 600 });
    await shown();
    const before = pictureShown(width, height);
    await userEvent.click(view.getByRole("button", { name: "Ask Comma" }));
    // The held frame lies on the picture, wherever the stage has it (a device's body takes a moment to settle on
    // its picture's shape, and the frame follows it).
    await untilPage(() => heldOver(pictureShown(width, height)));
    // On a plain stage that is where the picture was as Ask Comma was pressed: nothing moved.
    if (!capabilities) expect(heldOver(before)).toBe(true);
  }
);

it("keeps a device standing as it was while its frame is held: its body round the frame, which shows on its screen and says nothing of the stream", async () => {
  source = { ...source, capabilities: fakeDeviceCapabilities(fakePhone) };
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  const media = filled(390, 840, "#000000").captureStream(0);
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    queueMicrotask(() => {
      peer.onStream(media);
      peer.onState("live");
    });
    return { send: () => undefined, close: () => undefined };
  });
  const { view } = panel({ width: 400, height: 600 });
  await shown();
  const device = view.getByTestId("remote-screen-device");
  await userEvent.click(view.getByRole("button", { name: "Ask Comma" }));
  // The body stays, and nothing is drawn over it: what the selection is laid on is clear.
  expect(device).toBeVisible();
  expect(getComputedStyle(held()!).backgroundColor).toBe("rgba(0, 0, 0, 0)");
  // The frame shows on the device's screen, over the stream, where its case and corners cut it as they cut the stream.
  const frame = view.getByTestId("remote-screen-held");
  expect(device.contains(frame)).toBe(true);
  expect(frame.querySelector("canvas")).toBeVisible();
  const [on, live] = [
    frame.getBoundingClientRect(),
    document.querySelector("video")!.getBoundingClientRect(),
  ];
  expect([on.left, on.top, on.width, on.height]).toEqual([
    live.left,
    live.top,
    live.width,
    live.height,
  ]);
  // The stream fails under the held frame: the stage does not say so over it, where Retry could not be pressed.
  act(() => opened.at(-1)!.onState("failed"));
  expect(view.queryByRole("alert")).toBeNull();
  // Put away, the stage shows its stream again, and how that stands.
  await userEvent.keyboard("{Escape}");
  expect(view.queryByTestId("remote-screen-held")).toBeNull();
  expect(view.getByRole("alert")).toBeVisible();
});

it("says the chat is unavailable when it cannot take the selection", async () => {
  streaming(filled(300, 150, "#000000"));
  chat.fail = true;
  const { view } = panel();
  await shown();
  const said = next((done) => (chat.onToast = done));
  await userEvent.click(view.getByRole("button", { name: "Ask Comma" }));
  await askAbout("What is wrong here?");
  await said;
  expect(chat.toasts).toEqual(["comma-remote-screen-ask-comma-failed"]);
  expect(staged.chat).toEqual([]);
});

it("puts the selection into the chat it was made beside, though another chat shows before its picture is encoded", async () => {
  streaming(filled(300, 150, "#000000"));
  const { view, sidebar } = panel();
  await shown();

  // The picture's encoding is held until another chat has taken the sidebar.
  const original = HTMLCanvasElement.prototype.toBlob;
  let finish!: () => void;
  const encoding = next((started) =>
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation(function (
      this: HTMLCanvasElement,
      callback,
      type,
      quality
    ) {
      original.call(
        this,
        (blob) => {
          finish = () => callback(blob);
          started();
        },
        type,
        quality
      );
    })
  );
  await userEvent.click(view.getByRole("button", { name: "Ask Comma" }));
  await askAbout("What is wrong here?");
  await encoding;
  act(() => {
    sidebar().registerHost({ ...host, conversationId: "other-chat" });
  });
  expect(sidebar().getActiveHost()?.conversationId).toBe("other-chat");
  finish();
  await untilPage(() => staged.chat?.length === 1);
  vi.restoreAllMocks();
  expect(staged["other-chat"]).toEqual([]);
});

it.each([
  ["a Mac's display", undefined, [400, 200]],
  ["an Android device", fakeDeviceCapabilities(fakePhone), [390, 840]],
] as const)(
  "on %s, an area dragged on the frame goes as its own picture, cut from the frame, and a press as the whole screen; no input reaches the screen",
  async (_, capabilities, [width, height]) => {
    if (capabilities) source = { ...source, capabilities };
    vi.spyOn(Element.prototype, "setPointerCapture").mockImplementation(
      () => undefined
    );
    // A blue frame, larger than it shows.
    const sent = streaming(filled(width, height));
    const { view } = panel({ width: 240, height: 360 });
    await shown();
    const before = sent.length;
    await userEvent.click(view.getByRole("button", { name: "Ask Comma" }));
    const box = {
      left: width / 4,
      right: (width * 3) / 4,
      top: height / 5,
      bottom: (height * 4) / 5,
    };
    // Nothing is selected yet: no composer shows.
    expect(composer()).toBeNull();
    // A slip of the pointer, long one way and short the other, selects nothing.
    dragOnFrame({ x: 10, y: 10 }, { x: 200, y: 11 });
    expect(composer()).toBeNull();
    dragOnFrame({ x: box.left, y: box.top }, { x: box.right, y: box.bottom });
    await askAbout("Why is this cut off?");
    await untilPage(() => staged.chat?.length === 1);
    // A press selects the whole screen.
    dragOnFrame({ x: 10, y: 10 }, { x: 11, y: 11 });
    await askAbout("And all of it?");
    await untilPage(() => staged.chat?.length === 2);
    vi.restoreAllMocks();
    expect(sent.length).toBe(before);

    const [area, whole] = staged.chat!;
    expect(area).toMatchObject({ note: "Why is this cut off?" });
    // The area, cut from the frame in its own pixels (the frame shows smaller than it is), with no line on it.
    const corner = await pixel(pictureOf(area!), 0, 0);
    // (whole pixels round the box: one more than the box's own where an edge falls inside a pixel)
    expect(corner.width - (box.right - box.left)).toBeGreaterThanOrEqual(0);
    expect(corner.width - (box.right - box.left)).toBeLessThanOrEqual(1);
    expect(corner.height - (box.bottom - box.top)).toBeGreaterThanOrEqual(0);
    expect(corner.height - (box.bottom - box.top)).toBeLessThanOrEqual(1);
    expect(corner.rgba).toEqual([0, 0, 255, 255]);
    expect(whole).toMatchObject({ note: "And all of it?" });
    const middle = await pixel(pictureOf(whole!), width / 2, height / 2);
    expect([middle.width, middle.height]).toEqual([width, height]);
    expect(middle.rgba).toEqual([0, 0, 255, 255]);
  }
);

it("shows the composer by the selection and only then, with nothing but its field; Cancel or Escape lets the selection go, and Escape or Ask Comma again puts the frame away", async () => {
  vi.spyOn(Element.prototype, "setPointerCapture").mockImplementation(() => undefined);
  streaming(filled(300, 150, "#000000"));
  const { view } = panel({ width: 400, height: 600 });
  await shown();
  const liveToolbar = view.getByRole("button", { name: "Ask Comma" });
  const liveVideo = document.querySelector("video");
  await userEvent.click(liveToolbar);
  // The toolbar stays, its button held down.
  expect(liveToolbar).toBeVisible();
  expect(liveToolbar).toHaveAttribute("aria-pressed", "true");
  // Nothing is selected: no composer, and a line says how to select.
  expect(composer()).toBeNull();
  expect(
    view.getByText("Drag to select an area, or click to select the whole screen.")
  ).toBeVisible();

  // An area: the composer shows under it, with its field and no attachment.
  dragOnFrame({ x: 40, y: 30 }, { x: 200, y: 60 });
  const selected = () =>
    held()!.querySelector('[data-testid="remote-screen-mark-selected"]');
  const box = selected()!.getBoundingClientRect();
  await untilPage(() => composer()?.style.visibility === "");
  const by = composer()!.getBoundingClientRect();
  expect(by.top).toBeGreaterThan(box.bottom);
  expect(by.top - box.bottom).toBeLessThan(16);
  const field = composer()!.querySelector<HTMLElement>('[role="textbox"]')!;
  expect(composer()!.querySelector('[data-slot$="-attachment"]')).toBeNull();
  // What is typed next is about the selection: the field has the keys with no press on it.
  await userEvent.keyboard("Why?");
  expect(field).toHaveTextContent("Why?");
  // The composer's Cancel lets the selection go, and the composer with it; the frame stays held.
  await userEvent.click(view.getByRole("button", { name: "Cancel" }));
  expect(selected()).toBeNull();
  expect(composer()).toBeNull();
  expect(held()).not.toBeNull();
  expect(liveToolbar).toHaveAttribute("aria-pressed", "true");
  // So does Escape; with nothing selected, Escape puts the frame away.
  dragOnFrame({ x: 40, y: 30 }, { x: 200, y: 60 });
  await userEvent.keyboard("{Escape}");
  expect(composer()).toBeNull();
  expect(held()).not.toBeNull();
  await userEvent.keyboard("{Escape}");
  expect(held()).toBeNull();
  expect(liveToolbar).toHaveAttribute("aria-pressed", "false");
  // Ask Comma pressed again puts it away too.
  await userEvent.click(liveToolbar);
  expect(held()).not.toBeNull();
  await userEvent.click(liveToolbar);
  vi.restoreAllMocks();
  expect(held()).toBeNull();
  expect(document.querySelector("video")).toBe(liveVideo);
  expect(staged.chat).toEqual([]);
});

it.each([
  ["a Mac's display", undefined],
  ["a device", fakeDeviceCapabilities(fakePhone)],
] as const)(
  "on %s in Control, nothing typed or tabbed to while the frame is held reaches the screen, and Control is kept",
  async (_, capabilities) => {
    if (capabilities) source = { ...source, capabilities };
    const sent = streaming(filled(300, 150, "#000000"));
    const { view } = panel({ width: 240, height: 360 });
    await shown();
    const control = view.getByRole("button", { name: "Control" });
    await userEvent.click(control);
    expect(control).toHaveAttribute("aria-pressed", "true");
    await shown();

    await userEvent.click(view.getByRole("button", { name: "Ask Comma" }));
    const keys = view.getByLabelText(
      "Typing to the screen"
    ) as unknown as HTMLTextAreaElement;
    const before = sent.length;
    // Back from the frame's dialog, through all that is under it.
    const reached = new Set<Element | null>();
    for (let tab = 0; tab < 20; tab += 1) {
      await userEvent.keyboard("{Shift>}{Tab}{/Shift}");
      reached.add(document.activeElement);
      await userEvent.keyboard("x");
    }
    expect(reached.has(keys)).toBe(false);
    expect(sent.slice(before)).toEqual([]);

    await userEvent.click(view.getByRole("button", { name: "Ask Comma" }));
    expect(held()).toBeNull();
    expect(view.getByRole("button", { name: "Control" })).toHaveAttribute(
      "aria-pressed",
      "true"
    );
    // Put away, the screen is driven as before.
    await userEvent.click(document.querySelector("video")!);
    expect(sent.length).toBeGreaterThan(before);
  }
);
