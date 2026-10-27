import { advance } from "@comma/test-utils/fake-clock";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
/* eslint-disable unicorn/require-post-message-target-origin -- TestPort models MessagePort, which has no target origin. */
import {
  act,
  fireEvent,
  render as baseRender,
  screen,
  waitFor,
} from "@comma/test-utils/render";
import type { ChatMessagePart } from "@comma/chat-contract";
import type { ChatMessage } from "@comma/core/chat";
import { messageMarkdown } from "@comma/core/markdown";
import type { ReactElement, ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  DynamicUiWidget,
  DynamicUiDraftContext,
  DynamicUiLinkContext,
  DynamicUiLinkMenuContext,
} from "../DynamicUiWidget";
import { messageMarkdownElements } from "../../thread/inline/MessageInlineElements";
import { AssistantResponseRow } from "../../thread/rows/assistant/AssistantResponseRow";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { CommaUiThemeProvider } from "../../../commaUiTheme";

const identity = vi.hoisted(() => ({ userId: "alice" }));
vi.mock("../../../../nativePlatformActions", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../../../nativePlatformActions")>()),
  supportsDynamicUiWidgets: () => true,
}));
vi.mock("../../../../session/react", () => ({
  useSessionHostController: () => ({ apiBaseUrl: "https://comma.test", lifecycle: {} }),
  useSessionLifecycleSnapshot: () => ({ principal: { userId: identity.userId } }),
}));

class TestPort extends EventTarget {
  peer?: TestPort;
  postMessage(data: unknown) {
    this.peer?.dispatchEvent(new MessageEvent("message", { data }));
  }
  start() {}
  close() {}
}
class TestChannel {
  port1 = new TestPort();
  port2 = new TestPort();
  constructor() {
    this.port1.peer = this.port2;
    this.port2.peer = this.port1;
  }
}

const part = {
  kind: "dynamic-ui" as const,
  uiRef: "weather",
  contentId: "blob-one",
  version: 1,
  summary: "Singapore: 27 °C",
  conversationId: "home",
  messageId: "message-one",
  originTaskId: "task-one",
  attachmentIndex: 0,
};
const replyMessage: ChatMessage = {
  attachments: [],
  blocksKey: undefined,
  clientRequestId: undefined,
  createdAt: 1,
  createdBy: undefined,
  delivery: "sent",
  error: undefined,
  messageId: "message-one",
  parts: [],
  refs: [],
  role: "assistant",
  source: "server",
  status: "completed",
  text: "Current weather",
};
// The widget's own requests are the core's (packages/core/test/dynamic-ui.test.ts); here the core says what it read.
const widgetUi = { version: 1, html: "<p>Weather</p>", script: "", data: {} };
let widgetValue: (topic: Record<string, unknown>) => unknown;
/** Each widget read the window asked the core for. */
const widgetReads: Record<string, unknown>[] = [];
let widgetCore: ReturnType<typeof createScriptedCore>;
function render(ui: ReactElement, options: Parameters<typeof baseRender>[1] = {}) {
  return baseRender(ui, {
    wrapper: ({ children }: { children: ReactNode }) => widgetCore.wrap(children),
    ...options,
  });
}
function cardStateUpdates(port: TestPort) {
  const updates: unknown[] = [];
  port.addEventListener("message", (event) => {
    const data = (event as MessageEvent).data as { type: string };
    if (data.type === "card-state") updates.push(data);
  });
  return updates;
}
async function connect(frame: HTMLIFrameElement) {
  let port: TestPort | undefined;
  let initial: { state: unknown; cardState?: unknown; timeZone?: unknown } | undefined;
  vi.spyOn(frame.contentWindow!, "postMessage").mockImplementation(((
    data: { type: string; state: unknown; cardState?: unknown; timeZone?: unknown },
    _target: string,
    ports: TestPort[]
  ) => {
    if (data.type !== "comma-ui:init") return;
    initial = data;
    port = ports[0];
  }) as typeof window.postMessage);
  await waitFor(() => {
    act(() =>
      window.dispatchEvent(
        new MessageEvent("message", {
          source: frame.contentWindow,
          data: { type: "comma-ui:ready" },
        })
      )
    );
    expect(port).toBeDefined();
  });
  act(() => port!.postMessage({ type: "ready" }));
  return { port: port!, initial: initial! };
}

/** Each observer's callback by its root margin, the band ("480px 0px") or the view ("0px"), and its target. */
const intersections = new Map<string, Map<Element, (visible: boolean) => void>>();
/** Whether a widget is in view as soon as it is observed: reading ahead is tested out of view. */
let inViewAtObserve = true;
/** The root each widget observer measures its band from, in the order they were made. */
const observerRoots: (Element | Document | null | undefined)[] = [];
/** The reader scrolls the widget across an observer's edge. */
function cross(margin: string, target: Element, visible: boolean) {
  act(() => intersections.get(margin)!.get(target)!(visible));
}
const band = (target: Element, visible: boolean) => cross("480px 0px", target, visible);
const inView = (target: Element, visible: boolean) => cross("0px", target, visible);

/** What the core keeps of each widget's saved state, by its key (`dynamicUiState`). */
const savedStates = new Map<string, { state: string | null; cards: string | null }>();
/** Another window saves for the widget with this key: the core tells every surface. */
function savedElsewhere(key: string, kind: "state" | "cards", value: unknown) {
  savedStates.set(key, {
    ...(savedStates.get(key) ?? { state: null, cards: null }),
    [kind]: JSON.stringify(value),
  });
  act(() => widgetCore.changed("dynamicUiState"));
}
/** The keys a window saved under, in order. */
const savedKeys = () =>
  widgetCore.sentTo("dynamicUiState.save").map((p) => (p as { key: string }).key);

beforeEach(() => {
  widgetValue = () => ({ status: "ready", ui: widgetUi });
  widgetReads.length = 0;
  savedStates.clear();
  widgetCore = createScriptedCore({
    values: (topic) =>
      topic.topic === "dynamicUi"
        ? widgetValue(topic)
        : topic.topic === "dynamicUiState"
          ? (savedStates.get(String(topic.key)) ?? { state: null, cards: null })
          : undefined,
    calls: (name, params) => {
      if (name === "dynamicUiState.save") {
        const { key, kind, text } = params as {
          key: string;
          kind: "state" | "cards";
          text: string;
        };
        savedStates.set(key, {
          ...(savedStates.get(key) ?? { state: null, cards: null }),
          [kind]: text,
        });
        queueMicrotask(() => widgetCore.changed("dynamicUiState"));
      }
      return null;
    },
    onSubscribe: (topic) => {
      if (topic.topic === "dynamicUi") widgetReads.push(topic);
    },
  });
  intersections.clear();
  observerRoots.length = 0;
  inViewAtObserve = true;
  identity.userId = "alice";
  vi.stubGlobal("MessageChannel", TestChannel);
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      constructor(
        private callback: IntersectionObserverCallback,
        private options?: IntersectionObserverInit
      ) {
        observerRoots.push(options?.root);
      }
      observe(target: Element) {
        const margin = this.options?.rootMargin ?? "0px";
        let targets = intersections.get(margin);
        if (!targets) intersections.set(margin, (targets = new Map()));
        targets.set(target, (visible) =>
          this.callback(
            [{ isIntersecting: visible, target } as IntersectionObserverEntry],
            this as unknown as IntersectionObserver
          )
        );
        this.callback(
          [{ isIntersecting: inViewAtObserve, target } as IntersectionObserverEntry],
          this as unknown as IntersectionObserver
        );
      }
      disconnect() {}
    }
  );
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

/** A message of `parts` as the core sends it, drawn as its Markdown renderer draws it. */
function compileMessageMarkdown(
  parts: ChatMessagePart[],
  context: Parameters<typeof messageMarkdownElements>[1]
) {
  return messageMarkdownElements(
    {
      attachments: [],
      blocksKey: undefined,
      clientRequestId: undefined,
      createdAt: 1,
      createdBy: undefined,
      delivery: "sent",
      error: undefined,
      markdown: messageMarkdown(parts) as ChatMessage["markdown"],
      messageId: "m",
      parts,
      refs: [],
      role: "assistant",
      source: "server",
      status: "completed",
      text: "",
    },
    context
  )!;
}

describe("DynamicUiWidget host boundary", () => {
  it("updates application theme and custom palette without remounting the widget", async () => {
    const widget = (theme: "Light mode" | "Dark mode", background: string) => (
      <CommaUiThemeProvider theme={theme}>
        <div style={{ "--color-bg-primary": background } as React.CSSProperties}>
          <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
        </div>
      </CommaUiThemeProvider>
    );
    const { container, rerender } = render(widget("Light mode", "#f7eee2"));
    await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
    const frame = container.querySelector("iframe")!;
    const { port } = await connect(frame);
    const updates: { type: string; theme?: { scheme: string } }[] = [];
    port.addEventListener("message", (event) =>
      updates.push((event as MessageEvent).data)
    );
    rerender(widget("Dark mode", "#242738"));
    await waitFor(() =>
      expect(
        updates.some((m) => m.type === "theme" && m.theme?.scheme === "dark")
      ).toBe(true)
    );
    expect(container.querySelector("iframe")).toBe(frame);
    updates.length = 0;
    rerender(widget("Dark mode", "#352432"));
    await waitFor(() => expect(updates.some((m) => m.type === "theme")).toBe(true));
    expect(container.querySelector("iframe")).toBe(frame);
    expect(widgetReads).toHaveLength(1);
  });

  it("does not read or resend widget themes when scrolling changes ancestor metrics", async () => {
    const { container } = render(
      <div data-testid="scroll-parent">
        <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
      </div>
    );
    await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
    const { port } = await connect(container.querySelector("iframe")!);
    const updates: unknown[] = [];
    port.addEventListener("message", (event) =>
      updates.push((event as MessageEvent).data)
    );
    const computed = vi.spyOn(window, "getComputedStyle");
    const parent = screen.getByTestId("scroll-parent");
    await act(async () => {
      for (let index = 0; index < 20; index++) {
        parent.style.setProperty("--scroll-area-edge-mask-start", index + "px");
        parent.style.setProperty("--scroll-area-viewport-height", 600 + index + "px");
        await Promise.resolve();
      }
    });
    await advance(50);
    expect(computed).not.toHaveBeenCalled();
    expect(updates).toEqual([]);
  });

  it("keeps proposals inert until the user adds them to the composer", async () => {
    const draft = vi.fn();
    const compiled = compileMessageMarkdown(
      [{ kind: "markdown", text: "Current weather" }, part],
      { live: true, groupId: "group", workspaceId: "workspace" }
    );
    const { container } = render(
      <DynamicUiDraftContext.Provider value={draft}>
        <MarkdownStream
          {...compiled}
          streamId="ui-host-integration"
          blockPresentation="bubbles"
          final
        />
      </DynamicUiDraftContext.Provider>
    );
    await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
    expect(container.querySelector("iframe")!.closest("p")).toBeNull();
    expect(
      container.querySelector("iframe")!.closest(".markdown-stream-bubble")
    ).toBeNull();
    const { port } = await connect(container.querySelector("iframe")!);
    act(() => port.postMessage({ type: "request", value: "Refresh weather" }));
    expect(draft).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: /Add to/i }));
    expect(draft).toHaveBeenCalledOnce();
    expect(draft).toHaveBeenCalledWith(
      expect.stringContaining("comma:task/task-one"),
      "message-one"
    );
    expect(screen.queryByRole("button", { name: /Add to/i })).toBeNull();
  });

  // Web e2e runs without widgets, so the `data-widget` mark that styles.css widens
  // the row by stands in here for the measured width.
  it("widens its reply row while the row holds it", async () => {
    const reply = (parts: ChatMessage["parts"]) => (
      <AssistantResponseRow
        bubbleTail={false}
        chainState={undefined}
        groupId="group"
        message={{
          ...replyMessage,
          parts,
          // The core's parse of the reply.
          markdown: messageMarkdown(parts ?? []) as ChatMessage["markdown"],
        }}
        referenceMode="static"
        showActions={false}
        streamId="widget-row"
        workspaceId="workspace"
      />
    );
    const text = { kind: "markdown" as const, text: "Current weather" };
    const second = { ...part, contentId: "blob-two", attachmentIndex: 1 };
    const view = render(reply([text, part, second]));
    await waitFor(() =>
      expect(screen.getAllByTestId("dynamic-ui-widget")).toHaveLength(2)
    );
    const row = view.container.querySelector("article")!;
    const body = row.querySelector(".comma-chat-assistant-response-body");
    expect(row).toHaveAttribute("data-widget", "true");
    expect(body).toHaveAttribute("data-widget", "true");
    view.rerender(reply([text, part]));
    expect(screen.getAllByTestId("dynamic-ui-widget")).toHaveLength(1);
    expect(row).toHaveAttribute("data-widget", "true");
    view.rerender(reply([text]));
    expect(screen.queryByTestId("dynamic-ui-widget")).toBeNull();
    expect(row).not.toHaveAttribute("data-widget");
    expect(body).not.toHaveAttribute("data-widget");
  });

  it("grows and shrinks with content without a nested viewport", async () => {
    const view = render(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const frame = view.container.querySelector("iframe")!;
    const { port } = await connect(frame);
    for (const height of [900, 1800, 240]) {
      act(() => port.postMessage({ type: "height", value: height }));
      expect(frame.style.height).toBe(`${height}px`);
      expect(frame.parentElement).toBe(screen.getByTestId("dynamic-ui-widget"));
    }
  });

  it("relays widget wheel input through chat capture and preserves offscreen height", async () => {
    const capture = vi.fn();
    const view = render(
      <div onWheelCapture={capture}>
        <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
      </div>
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const frame = view.container.querySelector("iframe")!;
    const { port } = await connect(frame);
    act(() => port.postMessage({ type: "height", value: 900 }));
    act(() =>
      port.postMessage({ type: "wheel", deltaX: 0, deltaY: -120, deltaMode: 0 })
    );
    expect(capture).toHaveBeenCalledOnce();
    expect(capture.mock.calls[0]![0].deltaY).toBe(-120);
    act(() =>
      port.postMessage({ type: "wheel", deltaX: 0, deltaY: NaN, deltaMode: 0 })
    );
    expect(capture).toHaveBeenCalledOnce();
    const widget = screen.getByTestId("dynamic-ui-widget");
    band(widget, false);
    act(() => vi.advanceTimersByTime(500));
    expect(view.container.querySelector("iframe")).toBe(frame);
    band(widget, true);
    act(() => vi.advanceTimersByTime(1500));
    expect(view.container.querySelector("iframe")).toBe(frame);
    band(widget, false);
    act(() => vi.advanceTimersByTime(1500));
    expect(view.container.querySelector("iframe")).toBeNull();
    expect(widget.style.minHeight).toBe("900px");
    band(widget, true);
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    expect(view.container.querySelector("iframe")!.style.height).toBe("900px");
    expect(widgetReads).toHaveLength(1);
  });

  it("reads the widget as soon as its message mounts, before the reader nears it", async () => {
    inViewAtObserve = false;
    const view = render(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    const widget = screen.getByTestId("dynamic-ui-widget");
    await waitFor(() => expect(widgetReads).toHaveLength(1));
    expect(view.container.querySelector("iframe")).toBeNull();
    expect(screen.queryByText(part.summary)).toBeNull();
    band(widget, true);
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    expect(widgetReads).toHaveLength(1);
  });

  it("holds an empty slot, not the text answer, while the core reads the widget", async () => {
    const slow = { ...part, contentId: "blob-slow", messageId: "message-slow" };
    let read = false;
    widgetValue = () =>
      read ? { status: "ready", ui: widgetUi } : { status: "loading" };
    const view = render(
      <DynamicUiWidget part={slow} live groupId="group" workspaceId="workspace" />
    );
    const widget = screen.getByTestId("dynamic-ui-widget");
    await waitFor(() => expect(widgetReads).toHaveLength(1));
    expect(view.container.querySelector("iframe")).toBeNull();
    expect(screen.queryByText(slow.summary)).toBeNull();
    expect(widget.style.minHeight).toBe("160px");
    read = true;
    act(() => widgetCore.changed("dynamicUi"));
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    expect(view.container.querySelector("iframe")!.style.height).toBe("160px");
  });

  it("shows the text answer in view when the read takes over a second", async () => {
    const late = { ...part, contentId: "blob-late", messageId: "message-late" };
    let read = false;
    widgetValue = () =>
      read ? { status: "ready", ui: widgetUi } : { status: "loading" };
    const view = render(
      <DynamicUiWidget part={late} live groupId="group" workspaceId="workspace" />
    );
    const widget = screen.getByTestId("dynamic-ui-widget");
    await waitFor(() => expect(widgetReads).toHaveLength(1));
    act(() => vi.advanceTimersByTime(999));
    expect(screen.queryByText(late.summary)).toBeNull();
    act(() => vi.advanceTimersByTime(1));
    expect(screen.getByText(late.summary)).toBeTruthy();
    expect(widget.style.minHeight).toBe("160px");
    read = true;
    act(() => widgetCore.changed("dynamicUi"));
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    expect(screen.queryByText(late.summary)).toBeNull();
  });

  it("keeps a slow read out of view an empty slot", async () => {
    inViewAtObserve = false;
    const away = { ...part, contentId: "blob-away", messageId: "message-away" };
    widgetValue = () => ({ status: "loading" });
    render(
      <DynamicUiWidget part={away} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(widgetReads).toHaveLength(1));
    act(() => vi.advanceTimersByTime(5000));
    expect(screen.queryByText(away.summary)).toBeNull();
  });

  it("starts a widget it showed before at its last height, slot and frame alike", async () => {
    const seen = { ...part, contentId: "blob-seen", messageId: "message-seen" };
    const view = render(
      <DynamicUiWidget part={seen} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const { port } = await connect(view.container.querySelector("iframe")!);
    act(() => port.postMessage({ type: "height", value: 900 }));
    view.unmount();

    inViewAtObserve = false;
    const next = render(
      <DynamicUiWidget part={seen} live groupId="group" workspaceId="workspace" />
    );
    const widget = screen.getByTestId("dynamic-ui-widget");
    expect(next.container.querySelector("iframe")).toBeNull();
    expect(screen.queryByText(seen.summary)).toBeNull();
    expect(widget.style.minHeight).toBe("900px");
    band(widget, true);
    await waitFor(() => expect(next.container.querySelector("iframe")).not.toBeNull());
    expect(next.container.querySelector("iframe")!.style.height).toBe("900px");
  });

  it("measures its band from the chat scrollport, not the window", async () => {
    const view = render(
      <div data-slot="scroll-area-viewport">
        <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
      </div>
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const root = view.container.querySelector('[data-slot="scroll-area-viewport"]');
    expect(observerRoots).toEqual([root, root]);
  });

  /** Four widgets of their own identity, so no other test's remembered height or frame is theirs. */
  const pool = (name: string) =>
    ["a", "b", "c", "d"].map((id) => ({
      ...part,
      contentId: `blob-${name}-${id}`,
      messageId: `message-${name}-${id}`,
    }));
  const renderPool = (name: string) => {
    render(
      <>
        {pool(name).map((one) => (
          <DynamicUiWidget
            key={one.messageId}
            part={one}
            live
            groupId="group"
            workspaceId="workspace"
          />
        ))}
      </>
    );
    const widgets = screen.getAllByTestId("dynamic-ui-widget");
    return {
      widgets,
      frames: () => widgets.map((widget) => widget.querySelector("iframe") !== null),
    };
  };

  it("gives a fourth frame the place of a widget out of view, never one in view", async () => {
    inViewAtObserve = false;
    const { widgets, frames } = renderPool("pool");
    // The first is in view; the others are in the band below it.
    band(widgets[0]!, true);
    inView(widgets[0]!, true);
    band(widgets[1]!, true);
    band(widgets[2]!, true);
    await waitFor(() => expect(frames()).toEqual([true, true, true, false]));
    band(widgets[3]!, true);
    await waitFor(() => expect(frames()).toEqual([true, false, true, true]));
    // The widget that gave its place holds an empty slot: nothing to read, nothing to click.
    expect(widgets[1]!.querySelector("p")).toBeNull();
    expect(screen.queryByRole("button", { name: /reload/i })).toBeNull();
    // In view again, it runs again, taking the place of the oldest widget out of view.
    inView(widgets[1]!, true);
    await waitFor(() => expect(frames()).toEqual([true, true, false, true]));
  });

  it("lets a fourth frame in view take the oldest place, which Reload takes back", async () => {
    inViewAtObserve = false;
    const { widgets, frames } = renderPool("shown");
    for (const widget of widgets.slice(0, 3)) {
      band(widget, true);
      inView(widget, true);
    }
    await waitFor(() => expect(frames()).toEqual([true, true, true, false]));
    // A fourth out of view waits for its turn, as an empty slot, without booting a frame.
    const booted = vi.fn();
    const watch = new MutationObserver((records) => {
      if (
        records.some((record) =>
          [...record.addedNodes].some((n) => n.nodeName === "IFRAME")
        )
      )
        booted();
    });
    watch.observe(widgets[3]!, { childList: true });
    band(widgets[3]!, true);
    await waitFor(() => expect(frames()).toEqual([true, true, true, false]));
    await Promise.resolve();
    expect(booted).not.toHaveBeenCalled();
    watch.disconnect();
    expect(screen.queryByRole("button", { name: /reload/i })).toBeNull();
    // In view, it takes the oldest place; that widget says so, and Reload runs it again.
    inView(widgets[3]!, true);
    await waitFor(() => expect(frames()).toEqual([false, true, true, true]));
    expect(widgets[0]!).toHaveTextContent(part.summary);
    fireEvent.click(screen.getByRole("button", { name: /reload/i }));
    await waitFor(() => expect(frames()).toEqual([true, false, true, true]));
  });

  it("shows the text answer on a static surface and reads nothing", () => {
    const view = render(
      <DynamicUiWidget
        part={part}
        live={false}
        groupId="group"
        workspaceId="workspace"
      />
    );
    expect(screen.getByText(part.summary)).toBeTruthy();
    expect(view.container.querySelector("iframe")).toBeNull();
    expect(screen.getByTestId("dynamic-ui-widget").style.minHeight).toBe("");
    expect(widgetReads).toHaveLength(0);
  });

  it("preserves the iframe and its live channel across window visibility changes", async () => {
    const view = render(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const frame = view.container.querySelector("iframe")!;
    const { port } = await connect(frame);
    const commands: unknown[] = [];
    port.addEventListener("message", (event) =>
      commands.push((event as MessageEvent).data)
    );
    const visibility = vi.spyOn(document, "visibilityState", "get");
    for (let index = 0; index < 3; index++) {
      visibility.mockReturnValue("hidden");
      act(() => document.dispatchEvent(new Event("visibilitychange")));
      act(() => vi.advanceTimersByTime(10_000));
      expect(view.container.querySelector("iframe")).toBe(frame);
      visibility.mockReturnValue("visible");
      act(() => document.dispatchEvent(new Event("visibilitychange")));
      expect(view.container.querySelector("iframe")).toBe(frame);
    }
    act(() => port.postMessage({ type: "height", value: 420 }));
    expect(frame.style.height).toBe("420px");
    expect(commands).not.toContainEqual({ type: "stop" });
    expect(widgetReads).toHaveLength(1);
  });

  it("shares version state across copies, while isolating accounts and new versions", async () => {
    const view = render(
      <>
        <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
        <DynamicUiWidget
          part={{ ...part, conversationId: "task-one", messageId: "task-card" }}
          live
          groupId="group"
          workspaceId="workspace"
        />
      </>
    );
    await waitFor(() =>
      expect(view.container.querySelectorAll("iframe")).toHaveLength(2)
    );
    const [one, two] = await Promise.all(
      Array.from(view.container.querySelectorAll("iframe"), connect)
    );
    const updates: unknown[] = [];
    two!.port.addEventListener("message", (event) =>
      updates.push((event as MessageEvent).data)
    );
    act(() => one!.port.postMessage({ type: "save", value: { filter: "tomorrow" } }));
    await waitFor(() =>
      expect(updates).toContainEqual({ type: "state", value: { filter: "tomorrow" } })
    );
    // Another window saved for the same version.
    savedElsewhere(savedKeys()[0]!, "state", { filter: "all" });
    await waitFor(() =>
      expect(updates).toContainEqual({ type: "state", value: { filter: "all" } })
    );
    savedElsewhere(savedKeys()[0]!, "state", { filter: "tomorrow" });
    view.unmount();
    const next = render(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(next.container.querySelector("iframe")).not.toBeNull());
    expect(
      (await connect(next.container.querySelector("iframe")!)).initial.state
    ).toEqual({ filter: "tomorrow" });
    identity.userId = "bob";
    next.rerender(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(next.container.querySelector("iframe")).not.toBeNull());
    expect(
      (await connect(next.container.querySelector("iframe")!)).initial.state
    ).toEqual({});
    next.rerender(
      <DynamicUiWidget
        part={{ ...part, contentId: "blob-two" }}
        live
        groupId="group"
        workspaceId="workspace"
      />
    );
    await waitFor(() => expect(next.container.querySelector("iframe")).not.toBeNull());
    expect(
      (await connect(next.container.querySelector("iframe")!)).initial.state
    ).toEqual({});
  });

  describe("load failures", () => {
    const failed = { status: "failed", kind: "load", reason: "upstream_unavailable" };
    const mountFailing = async () => {
      // Each read fails until the test lets it load.
      let loads = false;
      widgetValue = () => (loads ? { status: "ready", ui: widgetUi } : failed);
      const view = render(
        <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
      );
      await waitFor(() => expect(screen.getByRole("alert")).toBeTruthy());
      return {
        frame: () => view.container.querySelector("iframe"),
        load: () => (loads = true),
      };
    };

    it("explains a widget that cannot load and asks the core to read it again on Retry", async () => {
      const { frame, load } = await mountFailing();
      const alert = screen.getByRole("alert");
      expect(alert).toHaveTextContent("Couldn’t load this widget");
      expect(alert).toHaveTextContent("Check your connection, then try again.");
      expect(screen.queryByText(/upstream_unavailable/)).toBeNull();
      expect(screen.getByText(part.summary)).toBeTruthy();

      load();
      fireEvent.click(screen.getByRole("button", { name: "Retry" }));
      await waitFor(() => expect(frame()).not.toBeNull());
      expect(screen.queryByRole("alert")).toBeNull();
      expect(widgetReads.map((topic) => topic.read)).toEqual(["0", "1"]);
    });

    it("reloads a failed widget when the connection comes back", async () => {
      const { frame, load } = await mountFailing();
      load();
      act(() => window.dispatchEvent(new Event("online")));
      await waitFor(() => expect(frame()).not.toBeNull());
      expect(screen.queryByRole("alert")).toBeNull();
    });
  });

  it("tells the reader the text answer stands when the runtime cannot show the widget", async () => {
    const { container } = render(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
    const { port } = await connect(container.querySelector("iframe")!);

    act(() =>
      port.postMessage({ type: "error", reason: "UI tree exceeds its node budget" })
    );

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("Couldn’t display this widget");
    expect(alert).toHaveTextContent("The answer above is unaffected.");
    expect(screen.queryByText(/node budget/)).toBeNull();
    expect(screen.getByText(part.summary)).toBeTruthy();
    expect(screen.getByRole("button", { name: "Retry" })).toBeTruthy();
  });

  it("shares card progress with other open copies without echoing it back", async () => {
    const view = render(
      <>
        <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
        <DynamicUiWidget
          part={{ ...part, conversationId: "task-one", messageId: "task-card" }}
          live
          groupId="group"
          workspaceId="workspace"
        />
      </>
    );
    await waitFor(() =>
      expect(view.container.querySelectorAll("iframe")).toHaveLength(2)
    );
    const [one, two] = await Promise.all(
      Array.from(view.container.querySelectorAll("iframe"), connect)
    );
    const toOne = cardStateUpdates(one!.port);
    const toTwo = cardStateUpdates(two!.port);
    act(() =>
      one!.port.postMessage({ type: "card-state", value: { card: ["notes"] } })
    );
    await waitFor(() =>
      expect(toTwo).toEqual([{ type: "card-state", value: { card: ["notes"] } }])
    );
    expect(toOne).toEqual([]);

    // Another window saved progress for the same version.
    savedElsewhere(savedKeys()[0]!, "cards", { card: ["notes", "rollout"] });
    await waitFor(() =>
      expect(toOne).toEqual([
        { type: "card-state", value: { card: ["notes", "rollout"] } },
      ])
    );
  });

  it("keeps card progress apart from widget state, per account and version", async () => {
    const mount = (contentId = part.contentId) => (
      <DynamicUiWidget
        part={{ ...part, contentId }}
        live
        groupId="group"
        workspaceId="workspace"
      />
    );
    const reopen = async (view: ReturnType<typeof render>) => {
      await waitFor(() =>
        expect(view.container.querySelector("iframe")).not.toBeNull()
      );
      return (await connect(view.container.querySelector("iframe")!)).initial;
    };
    const view = render(mount());
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const { port } = await connect(view.container.querySelector("iframe")!);
    act(() => port.postMessage({ type: "card-state", value: { card: ["notes"] } }));
    await waitFor(() => expect(savedKeys()).toHaveLength(1));
    view.unmount();

    const next = render(mount());
    expect(await reopen(next)).toMatchObject({
      state: {},
      cardState: { card: ["notes"] },
    });
    identity.userId = "bob";
    next.rerender(mount());
    expect((await reopen(next)).cardState).toEqual({});
    identity.userId = "alice";
    next.rerender(mount("blob-two"));
    expect((await reopen(next)).cardState).toEqual({});
  });

  it("answers known logos and explicitly settles unknown brands", async () => {
    const view = render(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const { port } = await connect(view.container.querySelector("iframe")!);
    const replies: { type: string; icons?: Record<string, string> }[] = [];
    port.addEventListener("message", (event) =>
      replies.push((event as MessageEvent).data)
    );
    act(() =>
      port.postMessage({ type: "brand-icons", names: ["linear", "not-a-brand", 7] })
    );

    await waitFor(() =>
      expect(replies.find((reply) => reply.type === "brand-icons")).toBeDefined()
    );
    const { icons } = replies.find((reply) => reply.type === "brand-icons")!;
    expect(Object.keys(icons!)).toEqual(["linear", "not-a-brand"]);
    expect(icons!["not-a-brand"]).toBe("");
    expect(icons!.linear).toMatch(/^<svg/);
  });

  it("rejects forged window initialization and falls back for unknown protocols", async () => {
    const view = render(
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const post = vi.spyOn(
      view.container.querySelector("iframe")!.contentWindow!,
      "postMessage"
    );
    act(() =>
      window.dispatchEvent(
        new MessageEvent("message", {
          source: window,
          data: { type: "comma-ui:ready" },
        })
      )
    );
    expect(post).not.toHaveBeenCalled();
    view.rerender(
      <DynamicUiWidget
        part={{ ...part, version: 99 }}
        live
        groupId="group"
        workspaceId="workspace"
      />
    );
    expect(view.container.querySelector("iframe")).toBeNull();
    expect(screen.getByText(part.summary)).toBeTruthy();
  });
});

it("routes valid widget links to the host sidebar callback and rejects unsafe URLs", async () => {
  const open = vi.fn();
  const { container } = render(
    <DynamicUiLinkContext.Provider value={open}>
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    </DynamicUiLinkContext.Provider>
  );
  await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
  const { port } = await connect(container.querySelector("iframe")!);
  act(() => {
    port.postMessage({ type: "open-link", url: "javascript:alert(1)" });
    port.postMessage({ type: "open-link", url: "https://user:secret@example.test/" });
    port.postMessage({ type: "open-link", url: "https://example.test/train" });
  });
  expect(open).toHaveBeenCalledExactlyOnceWith("https://example.test/train");
});

it("opens the host link menu at the frame's viewport position for safe links", async () => {
  const openMenu = vi.fn();
  const { container } = render(
    <DynamicUiLinkMenuContext.Provider value={openMenu}>
      <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
    </DynamicUiLinkMenuContext.Provider>
  );
  await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
  const iframe = container.querySelector("iframe")!;
  vi.spyOn(iframe, "getBoundingClientRect").mockReturnValue(
    DOMRect.fromRect({ x: 100, y: 200, width: 400, height: 300 })
  );
  const { port } = await connect(iframe);
  act(() => {
    port.postMessage({ type: "link-menu", url: "javascript:alert(1)", x: 1, y: 1 });
    port.postMessage({
      type: "link-menu",
      url: "https://example.test/pr",
      x: "1",
      y: 1,
    });
    port.postMessage({
      type: "link-menu",
      url: "https://example.test/pr",
      x: 12,
      y: 34,
    });
  });
  expect(openMenu).toHaveBeenCalledExactlyOnceWith(
    "https://example.test/pr",
    112,
    234,
    iframe
  );
});

it("previews a hovered widget link over its box and closes when the pointer leaves", async () => {
  const href = "https://github.com/AFK-surf/Comma/pull/2427";
  // The core has no preview of the link: the card is the generic one.
  const asked: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "linkPreview"
        ? { status: "missing" }
        : topic.topic === "dynamicUi"
          ? { status: "ready", ui: widgetUi }
          : topic.topic === "dynamicUiState"
            ? { state: null, cards: null }
            : undefined,
    onSubscribe: (topic) => {
      if (topic.topic === "linkPreview") asked.push(topic);
    },
  });
  const { container } = render(
    <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />,
    { wrapper: ({ children }) => core.wrap(children) }
  );
  await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
  const iframe = container.querySelector("iframe")!;
  for (const [name, value] of Object.entries({
    offsetLeft: 8,
    offsetTop: 16,
    offsetWidth: 300,
    offsetHeight: 200,
  }))
    Object.defineProperty(iframe, name, { configurable: true, value });
  const { port } = await connect(iframe);
  const box = { x: 12, y: 34, width: 900, height: 40 };
  act(() => {
    port.postMessage({ type: "link-hover", url: "javascript:alert(1)", ...box });
    port.postMessage({
      type: "link-hover",
      url: "https://user:secret@x.test/",
      ...box,
    });
    port.postMessage({ type: "link-hover", url: href, ...box, x: "12" });
  });
  expect(screen.queryByTestId("dynamic-ui-link-anchor")).toBeNull();

  act(() =>
    port.postMessage({ type: "link-hover", url: href, label: "支付回跳后刷新", ...box })
  );
  // The frame's offset places the box in the widget; only the part inside the frame counts.
  expect(screen.getByTestId("dynamic-ui-link-anchor").style).toMatchObject({
    left: "20px",
    top: "50px",
    width: "288px",
    height: "40px",
  });
  const card = await screen.findByRole("tooltip");
  expect(card).toHaveTextContent("支付回跳后刷新");
  await waitFor(() =>
    expect(card).toHaveTextContent("GitHub · github.com/AFK-surf/Comma/pull/2427")
  );
  expect(asked).toEqual([
    { topic: "linkPreview", workspace: "workspace", href, source: "" },
  ]);

  act(() => port.postMessage({ type: "link-hover", url: null }));
  await waitFor(() => expect(screen.queryByRole("tooltip")).toBeNull());
});

it("drops a widget link preview when its runtime stops, so a retry starts clean", async () => {
  const { container } = render(
    <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
  );
  await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
  const { port } = await connect(container.querySelector("iframe")!);
  act(() =>
    port.postMessage({
      type: "link-hover",
      url: "https://example.test/pr",
      label: "PR #2300",
      x: 0,
      y: 0,
      width: 10,
      height: 10,
    })
  );
  await screen.findByRole("tooltip");

  act(() => port.postMessage({ type: "error", reason: "UI failed" }));
  await waitFor(() => expect(screen.queryByRole("tooltip")).toBeNull());
  expect(screen.queryByTestId("dynamic-ui-link-anchor")).toBeNull();

  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
  await advance(300);
  expect(screen.queryByTestId("dynamic-ui-link-anchor")).toBeNull();
  expect(screen.queryByRole("tooltip")).toBeNull();
});

it("tells card templates the viewer's time zone", async () => {
  const { container } = render(
    <DynamicUiWidget part={part} live groupId="group" workspaceId="workspace" />
  );
  await waitFor(() => expect(container.querySelector("iframe")).not.toBeNull());
  const { initial } = await connect(container.querySelector("iframe")!);
  expect(initial.timeZone).toBe(Intl.DateTimeFormat().resolvedOptions().timeZone);
});
