import type { ChatMessage } from "@comma/core/chat";
import { flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import type { ReactNode } from "react";
import { expect, it } from "vitest";
import {
  InlineTaskLinkAdapterProvider,
  routeInlineTaskLinkAdapter,
} from "../../thread/inline/MessageInlineElements";
import { ChatTaskCards, ChatTaskCardsContext } from "../chatTaskCards";
import { MessageTaskCards } from "../MessageTaskCards";

function taskMessage(titles: readonly string[]): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId: "reply",
    parts: titles.map((title, index) => ({
      kind: "inline-task",
      task: {
        conversationId: `cnv_${index}`,
        status: "in_progress",
        title,
        unavailable: false,
      },
    })),
    refs: [],
    role: "assistant",
    source: "server",
    status: "completed",
    text: "",
  };
}

async function renderCards(message: ChatMessage) {
  const core = createScriptedCore();
  const cards = new ChatTaskCards();
  cards.update([message], true);
  renderWithRouter(
    core.wrap(
      <ChatTaskCardsContext.Provider value={cards}>
        <MessageTaskCards groupId="grp_1" message={message} workspaceId="wsp_1" />
      </ChatTaskCardsContext.Provider>
    )
  );
  await flush();
}

it("shows the Task card under a reply that created one Task", async () => {
  await renderCards(taskMessage(["Deploy report"]));

  const card = screen.getByTestId("chat-task-card-cnv_0");
  expect(card).toHaveTextContent("Deploy report");
  expect(card).toHaveAttribute("href", "/tasks/wsp_1/grp_1/cnv_0");
});

it("keeps a reply that names several Tasks to its inline chips", async () => {
  await renderCards(taskMessage(["Alpha", "Beta"]));

  expect(screen.queryByTestId("chat-task-cards")).toBeNull();
});

function renderWithRouter(element: ReactNode) {
  const rootRoute = createRootRoute({ component: Outlet });
  const sourceRoute = createRoute({
    component: () => element,
    getParentRoute: () => rootRoute,
    path: "/",
  });
  const router = createRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
    routeTree: rootRoute.addChildren([sourceRoute]),
  });
  return render(
    <InlineTaskLinkAdapterProvider adapter={routeInlineTaskLinkAdapter}>
      <RouterProvider router={router} />
    </InlineTaskLinkAdapterProvider>
  );
}
