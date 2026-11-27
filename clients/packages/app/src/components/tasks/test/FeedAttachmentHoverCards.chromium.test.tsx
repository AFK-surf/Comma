import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import type { TaskFile } from "@comma/core-client";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { cleanup, render } from "@comma/test-utils/render";
import { uiClock } from "@comma/ui/clock";
import { TaskFeedView, type TaskFeedEntry } from "@comma/ui/components/task-workspace";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { page, userEvent } from "vitest/browser";
import {
  createTaskFilePreviewCache,
  releaseTaskFilePreviewCache,
} from "../../chat/tasks/TaskFilePreviewCard";
import { FeedFileHoverCard, type TaskFileListCache } from "../FeedAttachmentHoverCards";

const NOW = uiClock.now();

const VIDEO_TASK_FILE: TaskFile = {
  conversation_id: "conv-review-1",
  task_title: "Feed attachment hover preview",
  message_id: "msg-rev-4",
  seq: 4,
  index: 0,
  type: "file",
  file_name: "pr4235-real-client.webm",
  mime_type: "video/webm",
  size: 14_155_776,
  created_at: 1_793_065_200_000,
};

const FALLBACK_FILENAME =
  "very-long-attachment-filename-that-should-use-full-hover-card-width.zip";

function makeEntries(fileName: string, mimeType: string): readonly TaskFeedEntry[] {
  return [
    {
      id: "entry-review-1",
      conversationId: "conv-review-1",
      groupId: "group-1",
      clusterKey: "cluster-review-1",
      triggerKind: "brief",
      taskTitle: "Feed attachment hover preview",
      taskStatus: "needs_review",
      statusBucket: "needs_review",
      taskUpdatedAt: NOW - 14 * 60_000,
      reviewVersion: 7,
      isLoop: false,
      occurredAt: NOW - 14 * 60_000,
      milestones: [
        {
          title: "PR #4227 CI passed and squashed into main",
          at: NOW - 14 * 60_000,
          messageId: "msg-rev-4",
        },
      ],
      milestoneCount: 1,
      outcomeMessageId: "msg-rev-4",
      outcomeText:
        "Verified attachment hover card sizing across video, loading, and fallback states.",
      media: [],
      files: [{ name: fileName, mimeType }],
    },
  ];
}

async function settleHoverCard(card: HTMLElement) {
  await Promise.all(
    card
      .getAnimations()
      .filter((a) => a.effect?.getTiming().iterations !== Infinity)
      .map((a) => a.finished.catch(() => undefined))
  );
}

function expectSymmetricalContentWidth(card: HTMLElement, content: HTMLElement) {
  const cardRect = card.getBoundingClientRect();
  const contentRect = content.getBoundingClientRect();
  const style = getComputedStyle(card);
  const padLeft = Number.parseFloat(style.paddingLeft);
  const padRight = Number.parseFloat(style.paddingRight);
  const borderLeft = Number.parseFloat(style.borderLeftWidth);
  const borderRight = Number.parseFloat(style.borderRightWidth);
  const innerWidth = cardRect.width - borderLeft - borderRight - padLeft - padRight;

  const leftInset = contentRect.left - cardRect.left;
  const rightInset = cardRect.right - contentRect.right;

  expect(Math.abs(leftInset - rightInset)).toBeLessThanOrEqual(1);
  expect(Math.abs(contentRect.width - innerWidth)).toBeLessThanOrEqual(1);
}

describe("FeedFileHoverCard width layout", () => {
  const caches: ReturnType<typeof createTaskFilePreviewCache>[] = [];

  beforeEach(() => {
    setInteractionModality("pointer");
  });

  afterEach(() => {
    cleanup();
    for (const cache of caches.splice(0)) {
      releaseTaskFilePreviewCache(cache);
    }
    document.body.replaceChildren();
  });

  function mountFeedHover({
    fileName,
    mimeType,
    taskFilesAnswer,
    streamStatus = "ready",
  }: {
    fileName: string;
    mimeType: string;
    taskFilesAnswer: () => Promise<unknown> | unknown;
    streamStatus?: "ready" | "unsupported";
  }) {
    initializeCommaI18n(["en"]);
    const previewCache = createTaskFilePreviewCache();
    caches.push(previewCache);
    const fileListCache: TaskFileListCache = new Map();

    const core = createScriptedCore({
      calls: (name) => {
        if (name === "taskFiles.list") return taskFilesAnswer();
        return null;
      },
      values: (topic) => {
        if (topic.topic === "fileStream") {
          return streamStatus === "ready"
            ? { status: "ready", url: undefined }
            : { status: "unsupported" };
        }
        return undefined;
      },
    });

    const entries = makeEntries(fileName, mimeType);
    render(
      core.wrap(
        <CommaI18nProvider>
          <div className="h-[640px] w-full bg-primary p-4">
            <TaskFeedView
              entries={entries}
              renderFile={(file, entry, defaultNode) => (
                <FeedFileHoverCard
                  anchor={defaultNode}
                  entry={entry}
                  file={file}
                  fileListCache={fileListCache}
                  previewCache={previewCache}
                />
              )}
            />
          </div>
        </CommaI18nProvider>
      )
    );
  }

  it("fills the full HoverCard inner width with symmetrical padding for matched media previews", async () => {
    await page.viewport(1280, 800);
    mountFeedHover({
      fileName: VIDEO_TASK_FILE.file_name,
      mimeType: "video/webm",
      taskFilesAnswer: () => ({
        status: "ready",
        files: [VIDEO_TASK_FILE],
        nextCursor: null,
      }),
    });

    const chip = document.querySelector<HTMLElement>('[data-slot="task-feed-file"]')!;
    await userEvent.hover(chip);

    await expect.element(page.getByTestId("task-file-preview-media")).toBeVisible();

    const card = document.querySelector<HTMLElement>('[data-slot="hover-card"]')!;
    await settleHoverCard(card);
    const preview = document.querySelector<HTMLElement>(
      '[data-testid="task-file-preview"]'
    )!;
    const media = document.querySelector<HTMLElement>(
      '[data-testid="task-file-preview-media"]'
    )!;

    expectSymmetricalContentWidth(card, preview);
    expectSymmetricalContentWidth(card, media);
    await userEvent.unhover(chip);
  });

  it("fills the full HoverCard inner width for loading and fallback states", async () => {
    await page.viewport(1280, 800);
    let resolveList!: (value: unknown) => void;
    const pendingList = new Promise((resolve) => {
      resolveList = resolve;
    });

    mountFeedHover({
      fileName: FALLBACK_FILENAME,
      mimeType: "application/zip",
      taskFilesAnswer: () => pendingList,
    });

    const chip = document.querySelector<HTMLElement>('[data-slot="task-feed-file"]')!;
    await userEvent.hover(chip);

    await expect.element(page.getByTestId("feed-file-hover-loading")).toBeVisible();
    const card = document.querySelector<HTMLElement>('[data-slot="hover-card"]')!;
    await settleHoverCard(card);
    const loading = document.querySelector<HTMLElement>(
      '[data-testid="feed-file-hover-loading"]'
    )!;
    expectSymmetricalContentWidth(card, loading);

    resolveList({ status: "ready", files: [], nextCursor: null });

    await expect.element(page.getByTestId("feed-file-hover-fallback")).toBeVisible();
    await settleHoverCard(card);
    const fallback = document.querySelector<HTMLElement>(
      '[data-testid="feed-file-hover-fallback"]'
    )!;
    expectSymmetricalContentWidth(card, fallback);
    await userEvent.unhover(chip);
  });

  it("stays bounded inside narrow viewports without losing symmetrical inner padding", async () => {
    await page.viewport(320, 600);
    mountFeedHover({
      fileName: VIDEO_TASK_FILE.file_name,
      mimeType: "video/webm",
      taskFilesAnswer: () => ({
        status: "ready",
        files: [VIDEO_TASK_FILE],
        nextCursor: null,
      }),
    });

    const chip = document.querySelector<HTMLElement>('[data-slot="task-feed-file"]')!;
    await userEvent.hover(chip);

    await expect.element(page.getByTestId("task-file-preview-media")).toBeVisible();

    const card = document.querySelector<HTMLElement>('[data-slot="hover-card"]')!;
    await settleHoverCard(card);
    const media = document.querySelector<HTMLElement>(
      '[data-testid="task-file-preview-media"]'
    )!;
    const cardRect = card.getBoundingClientRect();

    expect(cardRect.width).toBeLessThanOrEqual(320 - 32 + 1);
    expect(cardRect.right).toBeLessThanOrEqual(320);
    expectSymmetricalContentWidth(card, media);
    await userEvent.unhover(chip);
  });
});
