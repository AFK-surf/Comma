/* eslint-disable unicorn/require-post-message-target-origin -- TestPort models MessagePort, which has no target origin. */
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CommaApiError, type CommaApiClient } from "../../../../api";
import {
  DynamicUiWidget,
  DynamicUiDraftContext,
  DynamicUiLinkContext,
} from "../DynamicUiWidget";
import { compileMessageMarkdown } from "../../thread/inline/MessageInlineElements";
import { MarkdownStream } from "@comma/ui";
import { CommaUiThemeProvider } from "../../../commaUiTheme";

const identity = vi.hoisted(() => ({ userId: "alice" }));
vi.mock("../../../../runtime-chat/nativePlatformActions", () => ({
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
function apiClient() {
  return {
    fetchConversationAttachment: vi.fn(async () => ({
      size: 100,
      text: async () =>
        JSON.stringify({ version: 1, html: "<p>Weather</p>", script: "", data: {} }),
    })),
  } as unknown as CommaApiClient;
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
  let initial: { state: unknown; cardState?: unknown } | undefined;
  vi.spyOn(frame.contentWindow!, "postMessage").mockImplementation(((
    data: { type: string; state: unknown; cardState?: unknown },
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

const gateway = () => new CommaApiError(502, "upstream_unavailable");
const visibilityObservers = new Map<Element, (visible: boolean) => void>();

beforeEach(() => {
  visibilityObservers.clear();
  identity.userId = "alice";
  localStorage.clear();
  vi.stubGlobal("MessageChannel", TestChannel);
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      constructor(private callback: IntersectionObserverCallback) {}
      observe(target: Element) {
        visibilityObservers.set(target, (visible) =>
          this.callback(
            [{ isIntersecting: visible, target } as IntersectionObserverEntry],
            this as unknown as IntersectionObserver
          )
        );
        this.callback(
          [{ isIntersecting: true, target } as IntersectionObserverEntry],
          this as unknown as IntersectionObserver
        );
      }
      disconnect() {}
    }
  );
});
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("DynamicUiWidget host boundary", () => {
  it("updates application theme and custom palette without remounting the widget", async () => {
    const api = apiClient();
    const widget = (theme: "Light mode" | "Dark mode", background: string) => (
      <CommaUiThemeProvider theme={theme}>
        <div style={{ "--color-bg-primary": background } as React.CSSProperties}>
          <DynamicUiWidget
            part={part}
            api={api}
            groupId="group"
            workspaceId="workspace"
          />
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
    expect(api.fetchConversationAttachment).toHaveBeenCalledTimes(1);
  });

  it("does not read or resend widget themes when scrolling changes ancestor metrics", async () => {
    const { container } = render(
      <div data-testid="scroll-parent">
        <DynamicUiWidget
          part={part}
          api={apiClient()}
          groupId="group"
          workspaceId="workspace"
        />
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
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(computed).not.toHaveBeenCalled();
    expect(updates).toEqual([]);
  });

  it("keeps proposals inert until the user adds them to the composer", async () => {
    const draft = vi.fn();
    const compiled = compileMessageMarkdown(
      [{ kind: "markdown", text: "Current weather" }, part],
      { api: apiClient(), groupId: "group", workspaceId: "workspace" }
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

  it("grows and shrinks with content without a nested viewport", async () => {
    const view = render(
      <DynamicUiWidget
        part={part}
        api={apiClient()}
        groupId="group"
        workspaceId="workspace"
      />
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
    const api = apiClient();
    const capture = vi.fn();
    const view = render(
      <div onWheelCapture={capture}>
        <DynamicUiWidget
          part={part}
          api={api}
          groupId="group"
          workspaceId="workspace"
        />
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
    vi.useFakeTimers();
    act(() => visibilityObservers.get(widget)!(false));
    act(() => vi.advanceTimersByTime(500));
    expect(view.container.querySelector("iframe")).toBe(frame);
    act(() => visibilityObservers.get(widget)!(true));
    act(() => vi.advanceTimersByTime(1500));
    expect(view.container.querySelector("iframe")).toBe(frame);
    act(() => visibilityObservers.get(widget)!(false));
    act(() => vi.advanceTimersByTime(1500));
    expect(view.container.querySelector("iframe")).toBeNull();
    expect(widget.style.minHeight).toBe("900px");
    act(() => visibilityObservers.get(widget)!(true));
    vi.useRealTimers();
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    expect(view.container.querySelector("iframe")!.style.height).toBe("900px");
    expect(api.fetchConversationAttachment).toHaveBeenCalledTimes(1);
  });

  it("preserves the iframe and its live channel across window visibility changes", async () => {
    const api = apiClient();
    const view = render(
      <DynamicUiWidget part={part} api={api} groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(view.container.querySelector("iframe")).not.toBeNull());
    const frame = view.container.querySelector("iframe")!;
    const { port } = await connect(frame);
    const commands: unknown[] = [];
    port.addEventListener("message", (event) =>
      commands.push((event as MessageEvent).data)
    );
    const visibility = vi.spyOn(document, "visibilityState", "get");
    vi.useFakeTimers();
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
    expect(api.fetchConversationAttachment).toHaveBeenCalledTimes(1);
  });

  it("shares version state across copies, while isolating accounts and new versions", async () => {
    const api = apiClient();
    const view = render(
      <>
        <DynamicUiWidget
          part={part}
          api={api}
          groupId="group"
          workspaceId="workspace"
        />
        <DynamicUiWidget
          part={{ ...part, conversationId: "task-one", messageId: "task-card" }}
          api={api}
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
    expect(updates).toContainEqual({ type: "state", value: { filter: "tomorrow" } });
    const storageKey = localStorage.key(0)!;
    act(() =>
      window.dispatchEvent(
        new StorageEvent("storage", {
          key: storageKey,
          newValue: JSON.stringify({ filter: "all" }),
        })
      )
    );
    expect(updates).toContainEqual({ type: "state", value: { filter: "all" } });
    view.unmount();
    const next = render(
      <DynamicUiWidget part={part} api={api} groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(next.container.querySelector("iframe")).not.toBeNull());
    expect(
      (await connect(next.container.querySelector("iframe")!)).initial.state
    ).toEqual({ filter: "tomorrow" });
    identity.userId = "bob";
    next.rerender(
      <DynamicUiWidget part={part} api={api} groupId="group" workspaceId="workspace" />
    );
    await waitFor(() => expect(next.container.querySelector("iframe")).not.toBeNull());
    expect(
      (await connect(next.container.querySelector("iframe")!)).initial.state
    ).toEqual({});
    next.rerender(
      <DynamicUiWidget
        part={{ ...part, contentId: "blob-two" }}
        api={api}
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
    const mountWith = async (outcomes: Array<Error | "ok">) => {
      vi.useFakeTimers();
      const api = apiClient();
      const load = vi.mocked(api.fetchConversationAttachment);
      const loaded = await load("group", "home", "message-one", 0);
      load.mockReset();
      for (const outcome of outcomes)
        if (outcome === "ok") load.mockResolvedValueOnce(loaded);
        else load.mockRejectedValueOnce(outcome);
      load.mockResolvedValue(loaded);
      const view = render(
        <DynamicUiWidget
          part={part}
          api={api}
          groupId="group"
          workspaceId="workspace"
        />
      );
      await act(() => vi.advanceTimersByTimeAsync(0));
      return { load, frame: () => view.container.querySelector("iframe") };
    };

    it("tries a gateway failure once more without showing an error", async () => {
      const { load, frame } = await mountWith([gateway()]);

      expect(screen.queryByRole("alert")).toBeNull();
      expect(screen.getByText(part.summary)).toBeTruthy();
      await act(() => vi.advanceTimersByTimeAsync(2000));

      expect(frame()).not.toBeNull();
      expect(screen.queryByRole("alert")).toBeNull();
      expect(load).toHaveBeenCalledTimes(2);
    });

    it("explains a widget that still cannot load and recovers on Retry", async () => {
      const { load, frame } = await mountWith([gateway(), gateway()]);
      await act(() => vi.advanceTimersByTimeAsync(2000));

      const alert = screen.getByRole("alert");
      expect(alert).toHaveTextContent("Couldn’t load this widget");
      expect(alert).toHaveTextContent("Check your connection, then try again.");
      expect(screen.queryByText(/upstream_unavailable/)).toBeNull();
      expect(screen.getByText(part.summary)).toBeTruthy();
      expect(load).toHaveBeenCalledTimes(2);

      fireEvent.click(screen.getByRole("button", { name: "Retry" }));
      await act(() => vi.advanceTimersByTimeAsync(0));
      expect(frame()).not.toBeNull();
      expect(screen.queryByRole("alert")).toBeNull();
    });

    it("reloads a failed widget when the connection comes back", async () => {
      const { frame } = await mountWith([gateway(), gateway()]);
      await act(() => vi.advanceTimersByTimeAsync(2000));
      expect(screen.getByRole("alert")).toBeTruthy();

      act(() => window.dispatchEvent(new Event("online")));
      await act(() => vi.advanceTimersByTimeAsync(0));

      expect(frame()).not.toBeNull();
      expect(screen.queryByRole("alert")).toBeNull();
    });

    it("reports a widget that no longer exists without retrying", async () => {
      const { load } = await mountWith([new CommaApiError(404, "not_found")]);

      expect(screen.getByRole("alert")).toHaveTextContent("Couldn’t load this widget");
      expect(load).toHaveBeenCalledOnce();
    });
  });

  it("tells the reader the text answer stands when the runtime cannot show the widget", async () => {
    const { container } = render(
      <DynamicUiWidget
        part={part}
        api={apiClient()}
        groupId="group"
        workspaceId="workspace"
      />
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
    const api = apiClient();
    const view = render(
      <>
        <DynamicUiWidget
          part={part}
          api={api}
          groupId="group"
          workspaceId="workspace"
        />
        <DynamicUiWidget
          part={{ ...part, conversationId: "task-one", messageId: "task-card" }}
          api={api}
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
    expect(toTwo).toEqual([{ type: "card-state", value: { card: ["notes"] } }]);
    expect(toOne).toEqual([]);

    // Another window saved progress for the same version.
    const cardsKey = [...Array(localStorage.length).keys()]
      .map((index) => localStorage.key(index)!)
      .find((key) => key.startsWith("comma.dynamic-ui-cards:"))!;
    act(() =>
      window.dispatchEvent(
        new StorageEvent("storage", {
          key: cardsKey,
          newValue: JSON.stringify({ card: ["notes", "rollout"] }),
        })
      )
    );
    expect(toOne).toEqual([
      { type: "card-state", value: { card: ["notes", "rollout"] } },
    ]);
  });

  it("keeps card progress apart from widget state, per account and version", async () => {
    const api = apiClient();
    const mount = (contentId = part.contentId) => (
      <DynamicUiWidget
        part={{ ...part, contentId }}
        api={api}
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
      <DynamicUiWidget
        part={part}
        api={apiClient()}
        groupId="group"
        workspaceId="workspace"
      />
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
    const api = apiClient();
    const view = render(
      <DynamicUiWidget part={part} api={api} groupId="group" workspaceId="workspace" />
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
        api={api}
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
      <DynamicUiWidget
        part={part}
        api={apiClient()}
        groupId="group"
        workspaceId="workspace"
      />
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
