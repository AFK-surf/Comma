import { render, screen, waitFor, fireEvent, act } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { it, expect, vi } from "vitest";
import { createCommaApi } from "../../../../../api";
import { renderHook } from "@testing-library/react";
import { CommaI18nProvider } from "@comma/i18n/react";
import { initializeCommaI18n } from "@comma/i18n";
import { AgentBrowserPanel, AgentBrowserTrigger } from "../AgentBrowserPanel";
import { useSessionBrowser } from "../useSessionBrowser";

it("requires takeover for input and stops its stream when unmounted", async () => {
  let control = "agent";
  const calls: Record<string, unknown>[] = [];
  let cancelled = false;
  let stream: ReadableStreamDefaultController<Uint8Array> | undefined;
  const binding = {
    agent_id: "agent",
    session_id: "session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00.000000Z",
  };
  const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.includes("/events?")) {
      init?.signal?.addEventListener("abort", () => {
        cancelled = true;
      });
      return new Response(
        new ReadableStream({
          start(controller) {
            stream = controller;
            init?.signal?.addEventListener("abort", () => controller.close());
          },
        })
      );
    }
    if (init?.method === "POST") {
      const body = JSON.parse(String(init.body));
      calls.push(body);
      if (body.operation === "take_control") control = "human";
      if (body.operation === "return_control") control = "agent";
      return new Response(
        JSON.stringify({
          ...binding,
          control,
          storage_error:
            body.operation === "return_control"
              ? "browser_storage_partially_saved"
              : null,
          updated_at: "2026-09-28T00:00:01.000000Z",
          tabs: [{ tab_id: "tab", title: "Test page", url: "https://example.com" }],
        })
      );
    }
    return new Response(JSON.stringify({ browsers: [binding] }));
  });
  const api = createCommaApi({
    baseUrl: "https://comma.test",
    token: "",
    fetch: fetcher,
  });
  const { unmount } = render(
    <AgentBrowserPanel
      api={api}
      workspaceId="workspace"
      id="browser-panel"
      binding={binding}
      onRefresh={() => {}}
    />
  );
  await screen.findByRole("option", { name: "Test page" });
  expect(
    screen.getByRole("textbox", { name: "Text to type in the browser" })
  ).toBeDisabled();
  await userEvent.click(screen.getByRole("button", { name: "Take control" }));
  await waitFor(() =>
    expect(
      screen.getByRole("textbox", { name: "Text to type in the browser" })
    ).toBeEnabled()
  );
  // A delayed pre-takeover frame must not revoke the successful grant.
  await act(async () => {
    stream?.enqueue(
      new TextEncoder().encode(
        `data: ${JSON.stringify({ browser: binding, can_control: false, frame: null })}\n\n`
      )
    );
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(
    screen.getByRole("textbox", { name: "Text to type in the browser" })
  ).toBeEnabled();
  fireEvent.change(
    screen.getByRole("textbox", { name: "Text to type in the browser" }),
    { target: { value: "中文輸入" } }
  );
  await userEvent.click(screen.getByRole("button", { name: "Send text" }));
  await waitFor(() =>
    expect(
      calls.some(
        (call) =>
          call.operation === "input" && JSON.stringify(call.args).includes("中文輸入")
      )
    ).toBe(true)
  );
  await userEvent.click(screen.getByRole("button", { name: "Return to agent" }));
  await waitFor(() =>
    expect(
      screen.getByRole("textbox", { name: "Text to type in the browser" })
    ).toBeDisabled()
  );
  expect(screen.getByRole("alert")).toHaveTextContent(
    "Some browser changes were saved."
  );
  unmount();
  await waitFor(() => expect(cancelled).toBe(true));
});

it("clears a previous session's browser and ignores its late response after switching", async () => {
  const binding = {
    agent_id: "agent",
    session_id: "old-session",
    status: "ready",
    control: "agent",
    busy: false,
    updated_at: "2026-09-28T00:00:00Z",
  };
  let finishOld: ((response: Response) => void) | undefined;
  const fetcher = vi.fn((input: RequestInfo | URL) => {
    const url = new URL(String(input));
    expect(url.searchParams.get("conversation_id")).toBe("conversation");
    if (url.searchParams.get("participant_id") === "old-participant") {
      return new Promise<Response>((resolve) => {
        finishOld = resolve;
      });
    }
    return Promise.resolve(new Response(JSON.stringify({ browsers: [] })));
  });
  const api = createCommaApi({
    baseUrl: "https://comma.test",
    token: "",
    fetch: fetcher,
  });
  const { result, rerender, unmount } = renderHook(
    ({ participant }) =>
      useSessionBrowser(api, "workspace", "conversation", participant),
    { initialProps: { participant: "old-participant" } }
  );
  await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  rerender({ participant: "new-participant" });
  await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2));
  expect(result.current.browser).toBeUndefined();
  await act(async () => {
    finishOld?.(new Response(JSON.stringify({ browsers: [binding] })));
  });
  expect(result.current.browser).toBeUndefined();
  unmount();
});

it("words the header trigger and the panel in the reader's language", () => {
  const binding = {
    agent_id: "agent",
    session_id: "session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00.000000Z",
  };
  // The tabs never arrive, so the panel stays in its first state.
  const fetcher = vi.fn(() => new Promise<Response>(() => {}));
  const api = createCommaApi({
    baseUrl: "https://comma.test",
    token: "",
    fetch: fetcher,
  });
  try {
    render(
      <CommaI18nProvider locale="zh-CN">
        <AgentBrowserTrigger open={false} panelId="browser-panel" onToggle={() => {}} />
        <AgentBrowserPanel
          api={api}
          workspaceId="workspace"
          id="browser-panel"
          binding={binding}
          onRefresh={() => {}}
        />
      </CommaI18nProvider>
    );
    expect(screen.getByRole("button", { name: "浏览器" })).toBeInTheDocument();
    expect(screen.getByRole("region", { name: "Agent 浏览器" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "接管控制" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "刷新" })).toBeEnabled();
    expect(screen.getByText("正在加载浏览器…")).toBeInTheDocument();
    expect(
      screen.getByRole("textbox", { name: "要在浏览器中输入的文字" })
    ).toHaveAttribute("placeholder", "输入或粘贴文字，支持中文输入");
  } finally {
    initializeCommaI18n(["en"]);
  }
});
