import { CoreProvider } from "@comma/core-client";
import {
  createScriptedCore,
  delegateScriptedCore,
} from "@comma/test-utils/scripted-core";
import { flush } from "@comma/test-utils/fake-clock";
import { labelCatalog, labelsCore } from "../../../../../test/labelsCore";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ChatMessagePart } from "@comma/chat-contract";
import type { ChatMessage } from "@comma/core/chat";
import { messageMarkdown } from "@comma/core/markdown";
import type { ReactNode } from "react";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { useProductInboxProjection } from "../../../../../product-inbox";
import { createProductInboxProjectionHarness } from "../../../../../test/productInboxProjectionHarness";
import {
  messageMarkdownElements,
  InlineTaskLinkAdapterProvider,
  messagePartsHaveInlineElements,
  messagePartsPlainText,
  routeInlineTaskLinkAdapter,
  sameMessageParts,
  userMessageContentWithMentions,
} from "../MessageInlineElements";

/** A core that answers each task preview with `preview`, and keeps every `taskPreview` topic the UI asked for. */
function previewsCore(preview?: Record<string, unknown>) {
  const asked: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    owns: (name) => name === "taskPreview",
    values: (topic) =>
      topic.topic === "taskPreview"
        ? preview
          ? { status: "ready", preview }
          : { status: "loading" }
        : undefined,
    onSubscribe: (topic) => {
      if (topic.topic === "taskPreview") asked.push(topic);
    },
  });
  return { ...core, asked };
}

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

describe("message inline elements", () => {
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

    await flush();
    expect(
      screen.getByRole("link", { name: "Open task: Deploy report" })
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

    await flush();
    expect(
      screen.getByRole("link", { name: "Open task: Deploy report" })
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

    await flush();
    expect(container).toHaveTextContent("Visible");
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
    const previews = previewsCore({
      activity_status: "idle",
      freshness: { state: "fresh" },
      id: "cnv_task_public",
      kind: "agent_task",
      status: "completed",
      title: "Latest deploy report",
      updated_at: 10,
      group_id: "grp_1",
    });
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
      { live: true, groupId: "grp_1", workspaceId: "wsp_1" }
    );
    const inlineTask = compiled.inlineElements.get("element-0");
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

    renderWithRouter(previews.wrap(inlineTask));
    await flush();

    const link = screen.getByRole("link", {
      name: "Open task: Deploy report",
    });
    expect(previews.asked).toEqual([]);
    expect(link).toHaveAttribute("href", "/tasks/wsp_1/grp_1/cnv_task_public");

    await user.tab();
    await flush();
    // Opening the card asks the core for the Task's preview (it reads it, or answers what it keeps).
    expect(previews.asked).toEqual([
      expect.objectContaining({
        group: "grp_1",
        conversation: "cnv_task_public",
        read: "1",
      }),
    ]);
    const hoverCard = screen.getByRole("tooltip");
    expect(hoverCard).toHaveTextContent("Latest deploy report");
    await user.hover(hoverCard);
    expect(link).toHaveFocus();
    fireEvent.keyDown(link, { key: "Escape" });
    await flush();
    expect(screen.queryByRole("tooltip")).toBeNull();
    expect(link).toHaveFocus();

    await user.click(link);
    await flush();
    expect(screen.getByTestId("inline-task-target-route")).toHaveTextContent(
      "cnv_task_public"
    );
  });

  it("updates an inline Task from the shared host projection without a hover read", async () => {
    const previews = previewsCore();
    const labels = labelsCore({
      catalog: labelCatalog({
        labels: [{ id: "lbl_work", name: "Work", color: "blue" }],
      }),
    });
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
      { live: true, groupId: "grp_1", workspaceId: "wsp_1" }
    );

    delegateScriptedCore(projection.controller, labels.client);
    delegateScriptedCore(labels.client, previews.client);
    renderWithRouter(
      <CoreProvider client={projection.controller}>
        <ProductInboxDemand />
        {compiled.inlineElements.get("element-0")}
      </CoreProvider>
    );
    await flush();

    expect(
      screen.getByRole("link", { name: "Open task: Projected task title" })
    ).toBeInTheDocument();
    expect(previews.asked).toEqual([]);

    act(() => projection.emit(productInboxTask("Renamed projected task")));
    await flush();

    expect(
      screen.getByRole("link", { name: "Open task: Renamed projected task" })
    ).toBeInTheDocument();
    expect(previews.asked).toEqual([]);
    await userEvent
      .setup({ advanceTimers: vi.advanceTimersByTime })
      .hover(screen.getByRole("link", { name: "Open task: Renamed projected task" }));
    // The inline Task's hover card opens without a delay.
    await flush();
    const hover = screen.getByRole("tooltip");
    expect(hover).toHaveTextContent("Work");
    expect(hover).toHaveTextContent("Comma");
  });

  it("keeps the snapshot link while summaries load or fail, then keeps a confirmed archive read-only", async () => {
    // The core has said nothing of the Task yet.
    const core = createScriptedCore();
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
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );
    renderWithRouter(
      core.wrap(
        <MarkdownStream
          final
          content={compiled.content}
          inlineElements={compiled.inlineElements}
          nodes={compiled.nodes}
          streamId="slow-summary"
        />
      )
    );
    await flush();
    const link = screen.getByRole("link", { name: "Open task: Old task" });
    expect(link.nextSibling?.textContent).toBe(" after");
    // Its summary could not be read: the core knows nothing of it.
    act(() => core.emit("taskSummaries", { summaries: [] }));
    await flush();
    expect(link).toBeInTheDocument();
    const archivedFacts = {
      id: "cnv_task_public",
      group_id: "grp_1",
      kind: "agent_task",
      status: "archived",
      title: "Old task",
      updated_at: 2,
    };
    act(() => core.emit("taskSummaries", { summaries: [archivedFacts] }));
    await flush();
    expect(screen.queryByRole("link", { name: "Open task: Old task" })).toBeNull();
    const archived = screen.getByTestId("chat-inline-task-cnv_task_public");
    expect(archived).toHaveAttribute("aria-disabled", "true");
    expect(archived).toHaveAttribute("data-status", "archived");
    expect(document.body).toHaveTextContent("Before Old task after");
    fireEvent.click(archived);
    fireEvent.contextMenu(archived);
    expect(screen.queryByRole("menu")).toBeNull();
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
      <CoreProvider client={projection.controller}>
        <ProductInboxDemand />
        {compiled.inlineElements.get("element-0")}
      </CoreProvider>
    );
    await flush();
    expect(
      screen.getByRole("link", { name: "Open task: Old task" })
    ).toBeInTheDocument();
    const archived = productInboxTask("Old task");
    archived.items[0]!.status = "archived";
    act(() => projection.emit(archived));
    await flush();
    expect(screen.queryByRole("link", { name: "Open task: Old task" })).toBeNull();
  });

  it("splices a user message's comma:task mention into the sentence as an InlineTask chip", async () => {
    const content = userMessageContentWithMentions(
      "Check [Fix login](comma:task/cnv1_menu) today",
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );
    expect(content).toBeDefined();

    renderWithRouter(<span data-testid="user-bubble-content">{content}</span>);

    await flush();
    const bubble = screen.getByTestId("user-bubble-content");
    expect(bubble).toHaveTextContent("Check Fix login today");
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

    await flush();
    expect(screen.getByTestId("chat-inline-task-unavailable")).toHaveTextContent(
      "Task unavailable"
    );
    expect(screen.queryByRole("link")).toBeNull();
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
  useProductInboxProjection({ enabled: true });
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
