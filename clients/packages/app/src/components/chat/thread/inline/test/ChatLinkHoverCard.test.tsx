import type { LinkPreview, LinkPreviewValue } from "@comma/core/contract";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { render as renderBase, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import type { ReactElement } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ChatLinkHoverCard } from "../ChatLinkHoverCard";

const PR_HREF = "https://github.com/AFK-surf/Comma/pull/845";
/** The hover card opens this long after the pointer rests on its anchor (HoverCard's `delay`). */
const OPEN_DELAY = 250;

const pullRequestPreview = {
  additions: 12,
  author: { avatarUrl: null, login: "CatsJuice" },
  changedFiles: 3,
  deletions: 4,
  href: PR_HREF,
  kind: "github_pull_request" as const,
  number: 845,
  repository: "AFK-surf/Comma",
  state: "merged" as const,
  title: "feat(chat): add inline task elements",
  updatedAt: null,
} satisfies LinkPreview;

// What the core says of the link's preview (the core reads it again once no card shows it: see
// core/test/link-previews.test.ts), and the topics the cards asked for and let go.
let preview: LinkPreviewValue = { status: "loading" };
let asked: Record<string, unknown>[] = [];
let released: Record<string, unknown>[] = [];
let core = createScriptedCore();
beforeEach(() => {
  preview = { status: "loading" };
  asked = [];
  released = [];
  core = createScriptedCore({
    values: (topic) => (topic.topic === "linkPreview" ? preview : undefined),
    onSubscribe: (topic) => {
      if (topic.topic === "linkPreview") asked.push(topic);
    },
    onUnsubscribe: (topic) => {
      if (topic.topic === "linkPreview") released.push(topic);
    },
  });
});

const render = (ui: ReactElement) =>
  renderBase(ui, { wrapper: ({ children }) => core.wrap(children) });

describe("ChatLinkHoverCard", () => {
  it("asks for the preview when the card opens and lets it go when the card closes", async () => {
    render(
      <ChatLinkHoverCard
        anchor={<a href={PR_HREF}>PR #845</a>}
        href={PR_HREF}
        workspaceId="wsp_1"
      />
    );

    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    setInteractionModality("pointer");
    const link = screen.getByRole("link", { name: "PR #845" });
    expect(asked).toEqual([]);
    await user.hover(link);
    await advance(OPEN_DELAY);
    const topic = {
      topic: "linkPreview",
      workspace: "wsp_1",
      href: PR_HREF,
      source: "",
    };
    expect(asked).toEqual([topic]);
    expect(screen.getByTestId("recommendation-link-card-skeleton")).toBeInTheDocument();
    preview = { status: "ready", preview: pullRequestPreview };
    core.changed("linkPreview");
    await flush();
    expect(screen.getByTestId("recommendation-link-card")).toBeInTheDocument();

    // The link can be private: a closed card keeps no preview, and reopening asks again.
    await user.unhover(link);
    await advance(1_000);
    expect(screen.queryByRole("tooltip")).toBeNull();
    expect(released).toEqual([topic]);
    await user.hover(link);
    await advance(OPEN_DELAY);
    expect(asked).toEqual([topic, topic]);
  });

  it("labels the generic card with the link host when the anchor has no text", async () => {
    // A repository root is not a shape the server can read, so this link keeps
    // the generic card and never asks for a preview.
    const repositoryHref = "https://github.com/AFK-surf/Comma";
    render(
      <ChatLinkHoverCard
        anchor={<a aria-label="Repository" href={repositoryHref} />}
        href={repositoryHref}
        workspaceId="wsp_1"
      />
    );

    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("link", { name: "Repository" }));
    await advance(OPEN_DELAY);

    const card = screen.getByRole("tooltip");
    expect(card.querySelector("strong")).toHaveTextContent("github.com");
    expect(asked).toEqual([]);
  });
});
