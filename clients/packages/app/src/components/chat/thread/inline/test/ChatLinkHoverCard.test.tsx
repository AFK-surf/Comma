import { render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaRecommendationLinkPreview,
} from "../../../../../api";
import { resetRecommendationLinkPreviewCacheForTests } from "../../../../recommendations/linkPreviewCache";
import { ChatLinkHoverCard } from "../ChatLinkHoverCard";

const PR_HREF = "https://github.com/AFK-surf/Comma/pull/845";

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
};

function previewApi(
  getRecommendationLinkPreview: CommaApiClient["getRecommendationLinkPreview"]
) {
  return { getRecommendationLinkPreview } as Partial<CommaApiClient> as CommaApiClient;
}

describe("ChatLinkHoverCard", () => {
  afterEach(() => {
    resetRecommendationLinkPreviewCacheForTests();
  });

  it("keeps the single anchor, opens on the skeleton, and settles into the rich card", async () => {
    let resolvePreview!: (preview: CommaRecommendationLinkPreview) => void;
    const getRecommendationLinkPreview = vi.fn<
      CommaApiClient["getRecommendationLinkPreview"]
    >(
      () =>
        new Promise<CommaRecommendationLinkPreview>((resolve) => {
          resolvePreview = resolve;
        })
    );
    render(
      <ChatLinkHoverCard
        anchor={
          <a href={PR_HREF} rel="noopener noreferrer" target="_blank">
            PR #845
          </a>
        }
        api={previewApi(getRecommendationLinkPreview)}
        href={PR_HREF}
        workspaceId="wsp_1"
      />
    );

    // The wrapper decorates the exact anchor it was handed — no extra links.
    const link = screen.getByRole("link", { name: "PR #845" });
    expect(link).toHaveAttribute("href", PR_HREF);
    expect(screen.getAllByRole("link")).toHaveLength(1);
    // Nothing loads until the card first opens.
    expect(getRecommendationLinkPreview).not.toHaveBeenCalled();

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(link);

    const card = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(getRecommendationLinkPreview).toHaveBeenCalledOnce();
    expect(getRecommendationLinkPreview).toHaveBeenCalledWith("wsp_1", {
      href: PR_HREF,
    });
    // While the read is in flight the card shows the skeleton, already at the
    // rich card's width so nothing resizes sideways when the preview lands.
    expect(screen.getByTestId("recommendation-link-card-skeleton")).toBeInTheDocument();
    expect(card).toHaveClass("comma-recommendation-rich-link-hover-card");
    expect(screen.queryByTestId("recommendation-link-card")).toBeNull();

    resolvePreview(pullRequestPreview);

    await waitFor(() =>
      expect(card).toHaveTextContent("feat(chat): add inline task elements")
    );
    expect(screen.queryByTestId("recommendation-link-card-skeleton")).toBeNull();
    expect(screen.getByTestId("recommendation-link-card")).toHaveAttribute(
      "data-kind",
      "github_pull_request"
    );
    expect(screen.getAllByRole("link")).toHaveLength(1);

    // Reopening reuses the loaded preview instead of refetching.
    await user.unhover(link);
    await waitFor(() => expect(screen.queryByRole("tooltip")).toBeNull());
    await user.hover(link);
    await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(getRecommendationLinkPreview).toHaveBeenCalledOnce();
  });

  it("keeps the generic destination card when the preview read fails", async () => {
    const getRecommendationLinkPreview = vi
      .fn()
      .mockRejectedValue(new Error("preview unavailable"));
    render(
      <ChatLinkHoverCard
        anchor={<a href={PR_HREF}>PR #845</a>}
        api={previewApi(getRecommendationLinkPreview)}
        href={PR_HREF}
        workspaceId="wsp_1"
      />
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("link", { name: "PR #845" }));

    const card = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    await waitFor(() => expect(getRecommendationLinkPreview).toHaveBeenCalledOnce());

    expect(card).toHaveTextContent("PR #845");
    expect(card).toHaveTextContent("GitHub · github.com/AFK-surf/Comma/pull/845");
    expect(card).not.toHaveClass("comma-recommendation-rich-link-hover-card");
    expect(screen.queryByTestId("recommendation-link-card")).toBeNull();
  });

  it("opens a remembered failure straight on the generic card without re-reading", async () => {
    // A GitHub PR the connected account cannot see comes back as 503.
    const getRecommendationLinkPreview = vi
      .fn()
      .mockRejectedValue(new CommaApiError(503, "workspace_unavailable"));
    const api = previewApi(getRecommendationLinkPreview);
    const view = render(
      <ChatLinkHoverCard
        anchor={<a href={PR_HREF}>PR #845</a>}
        api={api}
        href={PR_HREF}
        workspaceId="wsp_1"
      />
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("link", { name: "PR #845" }));
    await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    await waitFor(() =>
      expect(screen.queryByTestId("recommendation-link-card-skeleton")).toBeNull()
    );
    view.unmount();

    // A fresh card (another message, a remount) for the same link.
    render(
      <ChatLinkHoverCard
        anchor={<a href={PR_HREF}>PR #845</a>}
        api={api}
        href={PR_HREF}
        workspaceId="wsp_1"
      />
    );
    await user.hover(screen.getByRole("link", { name: "PR #845" }));
    const card = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(screen.queryByTestId("recommendation-link-card-skeleton")).toBeNull();
    expect(card).toHaveTextContent("GitHub · github.com/AFK-surf/Comma/pull/845");
    expect(getRecommendationLinkPreview).toHaveBeenCalledOnce();
  });

  it("opens a cached preview straight on the rich card in a fresh card", async () => {
    const getRecommendationLinkPreview = vi.fn().mockResolvedValue(pullRequestPreview);
    const api = previewApi(getRecommendationLinkPreview);
    const view = render(
      <ChatLinkHoverCard
        anchor={<a href={PR_HREF}>PR #845</a>}
        api={api}
        href={PR_HREF}
        workspaceId="wsp_1"
      />
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("link", { name: "PR #845" }));
    await screen.findByTestId("recommendation-link-card", {}, { timeout: 3_000 });
    view.unmount();

    render(
      <ChatLinkHoverCard
        anchor={<a href={PR_HREF}>PR #845</a>}
        api={api}
        href={PR_HREF}
        workspaceId="wsp_1"
      />
    );
    await user.hover(screen.getByRole("link", { name: "PR #845" }));
    await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(screen.queryByTestId("recommendation-link-card-skeleton")).toBeNull();
    expect(screen.getByTestId("recommendation-link-card")).toBeInTheDocument();
    expect(getRecommendationLinkPreview).toHaveBeenCalledOnce();
  });

  it("labels the generic card with the link host when the anchor has no text", async () => {
    const getRecommendationLinkPreview = vi.fn();
    // A repository root is not a shape the server can read, so this link keeps
    // the generic card and never asks for a preview.
    const repositoryHref = "https://github.com/AFK-surf/Comma";
    render(
      <ChatLinkHoverCard
        anchor={<a aria-label="Repository" href={repositoryHref} />}
        api={previewApi(getRecommendationLinkPreview)}
        href={repositoryHref}
        workspaceId="wsp_1"
      />
    );

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("link", { name: "Repository" }));

    const card = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(card.querySelector("strong")).toHaveTextContent("github.com");
    expect(getRecommendationLinkPreview).not.toHaveBeenCalled();
  });
});
