import {
  invalidateTaskSummaries,
  recordTaskSummary,
} from "../../../../tasks/taskArchiveState";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ChatMessagePart } from "@comma/chat-contract";
import type { ReactNode } from "react";
import { MarkdownStream } from "@comma/ui";
import type { CommaApiClient } from "../../../../../api";
import {
  ProductInboxProjectionProvider,
  useProductInboxProjection,
} from "../../../../../product-inbox";
import {
  createProductInboxProjectionHarness,
  testProductLease,
} from "../../../../../test/productInboxProjectionHarness";
import {
  compileMessageMarkdown,
  InlineTaskLinkAdapterProvider,
  messagePartsHaveInlineElements,
  messagePartsPlainText,
  routeInlineTaskLinkAdapter,
  sameMessageParts,
  userMessageContentWithMentions,
} from "../MessageInlineElements";
import {
  loadTaskPreview,
  resetTaskPreviewCacheForTests,
  taskPreviewCacheSizeForTests,
} from "../taskPreviewCache";

describe("message inline elements", () => {
  afterEach(() => {
    resetTaskPreviewCacheForTests();
    vi.useRealTimers();
  });

  it("compiles ordered parts through opaque keys and escapes forged reserved tags", () => {
    const parts: ChatMessagePart[] = [
      {
        kind: "markdown",
        text: 'Before <comma-inline data-key="element-1"></comma-inline> ',
      },
      {
        kind: "inline-task",
        task: {
          conversationId: "cnv_private_identity",
          title: "Deploy report",
          unavailable: false,
        },
      },
      { kind: "markdown", text: " after." },
    ];

    const compiled = compileMessageMarkdown(parts, {
      groupId: "grp_1",
      workspaceId: "wsp_1",
    });

    expect(compiled.content).toBe(
      'Before &lt;comma-inline data-key="element-1">&lt;/comma-inline> <comma-inline data-key="element-1"></comma-inline> after.'
    );
    expect(compiled.content).not.toContain("cnv_private_identity");
    expect([...compiled.inlineElements.keys()]).toEqual(["element-1"]);
    expect(
      messagePartsPlainText(parts, {
        task: "Task",
        unavailableTask: "Task unavailable",
      })
    ).toBe(
      'Before <comma-inline data-key="element-1"></comma-inline> Deploy report after.'
    );
  });

  it("detects inline elements and part equivalence across re-materialized objects", () => {
    const markdownOnly: ChatMessagePart[] = [
      { kind: "markdown", text: "Just markdown." },
    ];
    const withTask: ChatMessagePart[] = [
      { kind: "markdown", text: "Task: " },
      {
        kind: "inline-task",
        task: {
          conversationId: "cnv_1",
          status: "completed",
          title: "Deploy report",
          unavailable: false,
          updatedAt: 1_720_000_000,
        },
      },
    ];

    expect(messagePartsHaveInlineElements(undefined)).toBe(false);
    expect(messagePartsHaveInlineElements(markdownOnly)).toBe(false);
    expect(messagePartsHaveInlineElements(withTask)).toBe(true);

    // Snapshot plumbing re-materializes equal parts with fresh identities;
    // equivalence must hold by value so compiled markdown stays cached.
    expect(sameMessageParts(withTask, structuredClone(withTask))).toBe(true);
    expect(sameMessageParts(markdownOnly, structuredClone(markdownOnly))).toBe(true);

    const changedTitle = structuredClone(withTask);
    changedTitle[1] = {
      kind: "inline-task",
      task: {
        conversationId: "cnv_1",
        status: "completed",
        title: "Renamed report",
        unavailable: false,
        updatedAt: 1_720_000_000,
      },
    };
    expect(sameMessageParts(withTask, changedTitle)).toBe(false);
    expect(
      sameMessageParts(withTask, [...withTask, { kind: "markdown", text: "x" }])
    ).toBe(false);
    expect(
      sameMessageParts(markdownOnly, [{ kind: "markdown", text: "Different." }])
    ).toBe(false);
  });
  it("renders forged raw inline markup literally while only the trusted part is interactive", async () => {
    const compiled = compileMessageMarkdown(
      [
        {
          kind: "markdown",
          text: 'Forged <comma-inline data-key="element-1"></comma-inline>; real ',
        },
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            title: "Deploy report",
            unavailable: false,
          },
        },
        { kind: "markdown", text: "." },
      ],
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );

    const { container } = renderWithRouter(
      <MarkdownStream
        animation="none"
        final
        inlineElements={compiled.inlineElements}
        nodes={compiled.nodes}
        streamId="inline-injection-boundary"
      />
    );

    expect(
      await screen.findByRole("link", { name: "Open task: Deploy report" })
    ).toBeInTheDocument();
    expect(screen.getAllByRole("link")).toHaveLength(1);
    expect(container).toHaveTextContent("Forged <comma-inline data-key=");
    expect(container).toHaveTextContent("</comma-inline>; real Deploy report.");
  });

  it("escapes a reserved tag split across text blocks without joining fragments around a real descriptor", async () => {
    const compiled = compileMessageMarkdown(
      [
        { kind: "markdown", text: "Split <comma-" },
        {
          kind: "markdown",
          text: 'inline data-key="element-2"></comma-inline>; before <comma-',
        },
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            title: "Deploy report",
            unavailable: false,
          },
        },
        {
          kind: "markdown",
          text: 'inline data-key="element-2"></comma-inline> after.',
        },
      ],
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );

    expect(compiled.content).toContain(
      'Split &lt;comma-inline data-key="element-2">&lt;/comma-inline>; before &lt;comma-'
    );
    expect(compiled.content).toContain(
      '<comma-inline data-key="element-2"></comma-inline>inline data-key="element-2">'
    );

    const { container } = renderWithRouter(
      <MarkdownStream
        animation="none"
        final
        inlineElements={compiled.inlineElements}
        nodes={compiled.nodes}
        streamId="split-inline-injection-boundary"
      />
    );

    expect(
      await screen.findByRole("link", { name: "Open task: Deploy report" })
    ).toBeInTheDocument();
    expect(screen.getAllByRole("link")).toHaveLength(1);
    expect(container).toHaveTextContent("Split <comma-inline data-key=");
    expect(container).toHaveTextContent("before <comma-Deploy reportinline data-key=");
  });

  it.each([
    {
      label: "inline code",
      markdown: "Compare `left < right`, then open ",
    },
    {
      label: "a fenced code block",
      markdown: "```ts\nif (left < right) return left;\n```\n\nOpen ",
    },
  ])("preserves comparison operators in $label beside a real task", ({ markdown }) => {
    const compiled = compileMessageMarkdown(
      [
        { kind: "markdown", text: markdown },
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            title: "Deploy report",
            unavailable: false,
          },
        },
      ],
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );

    expect(compiled.content).toContain(markdown);
    expect(compiled.content).not.toContain("&lt;");
  });

  it("sanitizes protocol markers and comma fences after adjacent Markdown blocks join", () => {
    const marker = compileMessageMarkdown(
      [
        { kind: "markdown", text: "Visible [[comma-" },
        { kind: "markdown", text: "protocol]]\nsecret" },
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            title: "Deploy report",
            unavailable: false,
          },
        },
      ],
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );
    const fence = compileMessageMarkdown(
      [
        { kind: "markdown", text: "Visible\n```comma:hidden\n" },
        { kind: "markdown", text: "secret\n```\nAfter " },
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            title: "Deploy report",
            unavailable: false,
          },
        },
      ],
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );

    expect(marker.content).toBe("Visible ");
    expect(marker.content).not.toContain("secret");
    expect(
      messagePartsPlainText(
        [
          { kind: "markdown", text: "Visible [[comma-" },
          { kind: "markdown", text: "protocol]]\nsecret" },
        ],
        { task: "Task", unavailableTask: "Task unavailable" }
      )
    ).toBe("Visible ");
    expect(fence.content).toBe(
      'Visible\n\nAfter <comma-inline data-key="element-2"></comma-inline>'
    );
    expect(fence.content).not.toContain("secret");
  });

  it("removes a private comma fence that crosses an inline descriptor", () => {
    const parts: ChatMessagePart[] = [
      { kind: "markdown", text: "Visible\n```comma:hidden\nsecret before " },
      {
        kind: "inline-task",
        task: {
          conversationId: "cnv_task_public",
          title: "Deploy report",
          unavailable: false,
        },
      },
      { kind: "markdown", text: " secret after\n```\nAfter" },
    ];

    const compiled = compileMessageMarkdown(parts, {
      groupId: "grp_1",
      workspaceId: "wsp_1",
    });

    expect(compiled.content).toBe("Visible\n\nAfter");
    expect(compiled.content).not.toContain("comma-inline");
    expect(compiled.content).not.toContain("secret");
    expect(
      messagePartsPlainText(parts, {
        task: "Task",
        unavailableTask: "Task unavailable",
      })
    ).toBe("Visible\n\nAfter");
  });

  it("fails closed when an unclosed private comma fence crosses an inline descriptor", async () => {
    const parts: ChatMessagePart[] = [
      { kind: "markdown", text: "Visible\n```comma:hidden\nsecret before " },
      {
        kind: "inline-task",
        task: {
          conversationId: "cnv_task_public",
          title: "SECRET ACTION",
          unavailable: false,
        },
      },
      { kind: "markdown", text: " secret after" },
    ];
    const compiled = compileMessageMarkdown(parts, {
      groupId: "grp_1",
      workspaceId: "wsp_1",
    });

    const { container } = renderWithRouter(
      <MarkdownStream
        animation="none"
        final
        inlineElements={compiled.inlineElements}
        nodes={compiled.nodes}
        streamId="unclosed-private-fence-boundary"
      />
    );

    await waitFor(() => expect(container).toHaveTextContent("Visible"));
    expect(container).not.toHaveTextContent("secret");
    expect(screen.queryByRole("link", { name: /SECRET ACTION/ })).toBeNull();
    expect(compiled.inlineElements.size).toBe(0);
    expect(
      messagePartsPlainText(parts, {
        task: "Task",
        unavailableTask: "Task unavailable",
      })
    ).toBe("Visible\n");
  });

  it("renders an accessible Task link, refreshes its hover preview, and navigates", async () => {
    const getConversationPreview = vi.fn().mockResolvedValue({
      activity_status: "idle",
      freshness: { state: "fresh" },
      id: "cnv_task_public",
      kind: "agent_task",
      status: "completed",
      title: "Latest deploy report",
      updated_at: 10,
      group_id: "grp_1",
    });
    const api = { getConversationPreview } as Partial<CommaApiClient> as CommaApiClient;
    const compiled = compileMessageMarkdown(
      [
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            status: "running",
            title: "Deploy report",
            unavailable: false,
          },
        },
      ],
      { api, groupId: "grp_1", workspaceId: "wsp_1" }
    );
    const inlineTask = compiled.inlineElements.get("element-0");
    const user = userEvent.setup();

    renderWithRouter(inlineTask);

    const link = await screen.findByRole("link", {
      name: "Open task: Deploy report",
    });
    expect(link).toHaveAttribute("href", "/tasks/wsp_1/grp_1/cnv_task_public");

    await user.tab();
    await waitFor(() => expect(getConversationPreview).toHaveBeenCalledOnce());
    const hoverCard = await screen.findByRole("tooltip");
    await waitFor(() => expect(hoverCard).toHaveTextContent("Latest deploy report"));
    await user.hover(hoverCard);
    expect(link).toHaveFocus();
    fireEvent.keyDown(link, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("tooltip")).toBeNull());
    expect(link).toHaveFocus();

    await user.click(link);
    expect(await screen.findByTestId("inline-task-target-route")).toHaveTextContent(
      "cnv_task_public"
    );
  });

  it("updates an inline Task from the shared host projection without a hover read", async () => {
    const getConversationPreview = vi.fn().mockReturnValue(new Promise(() => {}));
    const listTaskLabels = vi.fn().mockResolvedValue({
      colors: [],
      proposals: [],
      labels: [{ id: "lbl_work", name: "Work", color: "blue" }],
    });
    const api = {
      getConversationPreview,
      listTaskLabels,
    } as Partial<CommaApiClient> as CommaApiClient;
    const projection = createProductInboxProjectionHarness({
      initial: productInboxTask("Projected task title"),
    });
    const compiled = compileMessageMarkdown(
      [
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            unavailable: false,
          },
        },
      ],
      { api, groupId: "grp_1", workspaceId: "wsp_1" }
    );

    renderWithRouter(
      <ProductInboxProjectionProvider controller={projection.controller}>
        <ProductInboxDemand />
        {compiled.inlineElements.get("element-0")}
      </ProductInboxProjectionProvider>
    );

    expect(
      await screen.findByRole("link", { name: "Open task: Projected task title" })
    ).toBeInTheDocument();
    expect(getConversationPreview).not.toHaveBeenCalled();

    projection.emit(productInboxTask("Renamed projected task"));

    expect(
      await screen.findByRole("link", { name: "Open task: Renamed projected task" })
    ).toBeInTheDocument();
    expect(getConversationPreview).not.toHaveBeenCalled();
    await userEvent.hover(
      screen.getByRole("link", { name: "Open task: Renamed projected task" })
    );
    const hover = await screen.findByRole("tooltip");
    await waitFor(() => expect(hover).toHaveTextContent("Work"));
    expect(hover).toHaveTextContent("Comma");
  });

  it("keeps the snapshot link while summaries load or fail, then keeps a confirmed archive read-only", async () => {
    let reject!: (reason: Error) => void;
    const getTaskSummaries = vi.fn(
      () =>
        new Promise<never>((_resolve, fail) => {
          reject = fail;
        })
    );
    const api = { getTaskSummaries } as unknown as CommaApiClient;
    const compiled = compileMessageMarkdown(
      [
        { kind: "markdown", text: "Before " },
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            title: "Old task",
            status: "completed",
            unavailable: false,
          },
        },
        { kind: "markdown", text: " after" },
      ],
      { api, groupId: "grp_1", workspaceId: "wsp_1" }
    );
    renderWithRouter(
      <MarkdownStream
        final
        content={compiled.content}
        inlineElements={compiled.inlineElements}
        nodes={compiled.nodes}
        streamId="slow-summary"
      />
    );
    const link = await screen.findByRole("link", { name: "Open task: Old task" });
    expect(link.nextSibling?.textContent).toBe(" after");
    await waitFor(() => expect(getTaskSummaries).toHaveBeenCalledOnce());
    await act(async () => reject(new Error("offline")));
    expect(link).toBeInTheDocument();
    act(() =>
      recordTaskSummary(api, {
        id: "cnv_task_public",
        group_id: "grp_1",
        kind: "agent_task",
        status: "archived",
        title: "Old task",
        updated_at: 2,
      })
    );
    expect(screen.queryByRole("link", { name: "Open task: Old task" })).toBeNull();
    const archived = screen.getByTestId("chat-inline-task-cnv_task_public");
    expect(archived).toHaveAttribute("aria-disabled", "true");
    expect(archived).toHaveAttribute("data-status", "archived");
    expect(document.body).toHaveTextContent("Before Old task after");
    fireEvent.click(archived);
    fireEvent.contextMenu(archived);
    expect(screen.queryByRole("menu")).toBeNull();
    act(() => invalidateTaskSummaries(api));
    expect(screen.queryByRole("link", { name: "Open task: Old task" })).toBeNull();
  });

  it("preserves historical structured references as read-only when the owner reports archived", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: productInboxTask("Old task"),
    });
    const compiled = compileMessageMarkdown(
      [
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            title: "Old task",
            status: "completed",
            unavailable: false,
          },
        },
      ],
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );
    renderWithRouter(
      <ProductInboxProjectionProvider controller={projection.controller}>
        <ProductInboxDemand />
        {compiled.inlineElements.get("element-0")}
      </ProductInboxProjectionProvider>
    );
    expect(
      await screen.findByRole("link", { name: "Open task: Old task" })
    ).toBeInTheDocument();
    const archived = productInboxTask("Old task");
    archived.items[0]!.status = "archived";
    act(() => projection.emit(archived));
    await waitFor(() =>
      expect(screen.queryByRole("link", { name: "Open task: Old task" })).toBeNull()
    );
  });

  it("splices a user message's comma:task mention into the sentence as an InlineTask chip", async () => {
    const content = userMessageContentWithMentions(
      "Check [Fix login](comma:task/cnv1_menu) today",
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );
    expect(content).toBeDefined();

    renderWithRouter(<span data-testid="user-bubble-content">{content}</span>);

    const bubble = await screen.findByTestId("user-bubble-content");
    await waitFor(() => expect(bubble).toHaveTextContent("Check Fix login today"));
    expect(bubble.textContent).not.toContain("comma:task");
    expect(screen.getByTestId("chat-inline-task-cnv1_menu")).toHaveTextContent(
      "Fix login"
    );
  });

  it("links plain HTTP URLs in user bubbles without changing their text", () => {
    const text = "查看 https://example.com/a?x=1&y=2。 Then http://example.org/path.";
    const content = userMessageContentWithMentions(text, {
      groupId: "grp_1",
      workspaceId: "wsp_1",
    });
    render(<span data-testid="plain-links">{content ?? text}</span>);
    expect(
      screen.getAllByRole("link").map((link) => link.getAttribute("href"))
    ).toEqual(["https://example.com/a?x=1&y=2", "http://example.org/path"]);
    expect(screen.getByTestId("plain-links").textContent).toBe(text);
  });

  it("returns undefined for user text without mentions or URLs so bubbles keep the text path", () => {
    expect(
      userMessageContentWithMentions("plain text", {
        groupId: "grp_1",
        workspaceId: "wsp_1",
      })
    ).toBeUndefined();
  });

  it("renders an unavailable Task as inert localized text", async () => {
    const compiled = compileMessageMarkdown(
      [{ kind: "inline-task", task: { unavailable: true } }],
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );

    renderWithRouter(compiled.inlineElements.get("element-0"));

    expect(await screen.findByTestId("chat-inline-task-unavailable")).toHaveTextContent(
      "Task unavailable"
    );
    expect(screen.queryByRole("link")).toBeNull();
  });

  it("deduplicates concurrent preview reads inside the session-scoped cache", async () => {
    let resolvePreview!: (
      value: Awaited<ReturnType<CommaApiClient["getConversationPreview"]>>
    ) => void;
    const getConversationPreview = vi.fn(
      () =>
        new Promise<Awaited<ReturnType<CommaApiClient["getConversationPreview"]>>>(
          (resolve) => {
            resolvePreview = resolve;
          }
        )
    );
    const api = { getConversationPreview } as Partial<CommaApiClient> as CommaApiClient;

    const first = loadTaskPreview(api, "grp_1", "cnv_task_public");
    const second = loadTaskPreview(api, "grp_1", "cnv_task_public");
    expect(getConversationPreview).toHaveBeenCalledOnce();

    await act(async () => {
      resolvePreview({
        activity_status: "idle",
        freshness: { state: "fresh" },
        id: "cnv_task_public",
        kind: "agent_task",
        status: "running",
        title: "Deploy report",
        updated_at: 1,
        group_id: "grp_1",
      });
      await Promise.all([first, second]);
    });

    expect(await first).toEqual(expect.objectContaining({ id: "cnv_task_public" }));
  });

  it("stays bounded when evicted in-flight previews resolve later", async () => {
    const resolvers: Array<
      (value: Awaited<ReturnType<CommaApiClient["getConversationPreview"]>>) => void
    > = [];
    const getConversationPreview = vi.fn(
      (_groupId: string, conversationId: string) =>
        new Promise<Awaited<ReturnType<CommaApiClient["getConversationPreview"]>>>(
          (resolve) => {
            resolvers.push((value) => resolve({ ...value, id: conversationId }));
          }
        )
    );
    const api = { getConversationPreview } as Partial<CommaApiClient> as CommaApiClient;
    const reads = Array.from({ length: 129 }, (_, index) =>
      loadTaskPreview(api, "grp_1", `cnv_task_${index}`)
    );

    expect(taskPreviewCacheSizeForTests(api)).toBe(128);

    resolvers.forEach((resolve) =>
      resolve({
        activity_status: "idle",
        freshness: { state: "fresh" },
        id: "overridden-by-resolver",
        kind: "agent_task",
        status: "running",
        title: "Deploy report",
        updated_at: 1,
        group_id: "grp_1",
      })
    );
    await Promise.all(reads);

    expect(taskPreviewCacheSizeForTests(api)).toBe(128);
  });
});

function renderWithRouter(element: ReactNode) {
  const rootRoute = createRootRoute({ component: Outlet });
  const sourceRoute = createRoute({
    component: () => element,
    getParentRoute: () => rootRoute,
    path: "/",
  });
  const targetRoute = createRoute({
    component: TargetRoute,
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
  });
  const router = createRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
    routeTree: rootRoute.addChildren([sourceRoute, targetRoute]),
  });
  return render(
    <InlineTaskLinkAdapterProvider adapter={routeInlineTaskLinkAdapter}>
      <RouterProvider router={router} />
    </InlineTaskLinkAdapterProvider>
  );
}

function TargetRoute() {
  return <div data-testid="inline-task-target-route">cnv_task_public</div>;
}

function ProductInboxDemand() {
  useProductInboxProjection({ enabled: true, session: testProductLease });
  return null;
}

function productInboxTask(title: string) {
  return {
    activeWorkspaceId: "wsp_1",
    items: [
      {
        conversationId: "cnv_task_public",
        freshness: "fresh" as const,
        groupId: "grp_1",
        id: "wsp_1:cnv_task_public",
        kind: "agent_task" as const,
        source: "salix.conversation" as const,
        status: "running",
        title,
        updatedAt: 1_000,
        archiveVersion: 1,
        labels: ["lbl_work"],
        origin: "comma",
        workspaceId: "wsp_1",
        workspaceName: "Workspace",
      },
    ],
    source: "live-sync" as const,
  };
}
