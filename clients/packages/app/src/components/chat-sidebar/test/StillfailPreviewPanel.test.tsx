import { initializeCommaI18n } from "@comma/i18n";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  LinkPreview,
  LinkPreviewValue,
  StationTasksValue,
} from "@comma/core/contract";
import { StillfailPreviewPanel } from "../StillfailPreviewPanel";

const openExternalSpy = vi.fn();

vi.mock("../../chat/thread/inline/linkActions", () => ({
  openUrlInExternalBrowser: (...args: unknown[]) => openExternalSpy(...args),
}));

const samplePreview: LinkPreview = {
  kind: "stillfail_chat",
  href: "https://app.youdid.wtf/o/ws/st-1/chat%3Ac-1",
  ref: "station:st-1:chat:c-1",
  title: "Duo monoid 发热排查",
  stationName: "pengx17",
  status: "need",
  note: "决定是否重签重装",
  updatedAt: null,
  offline: false,
  messages: [
    {
      seq: 1,
      authorKind: "person",
      author: "peng@example.com",
      text: "帮我查一下手机发热",
      createdAt: null,
      card: null,
    },
    {
      seq: 2,
      authorKind: "agent",
      author: "agent",
      text: "已定位到后台轮询过频，补丁已就绪。",
      createdAt: null,
      card: {
        type: "options",
        choice: null,
        closed: false,
        options: ["重签并安装", "先不装"],
      },
    },
  ],
};

afterEach(() => {
  openExternalSpy.mockReset();
  initializeCommaI18n(["en"]);
});

describe("StillfailPreviewPanel", () => {
  it("renders native bubbles, propagates title, refreshes manually, and opens external link", async () => {
    const onTitleChange = vi.fn();
    const asked: Record<string, unknown>[] = [];
    const value: LinkPreviewValue = {
      status: "ready",
      preview: samplePreview,
    };
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "linkPreview" ? value : undefined),
      onSubscribe: (topic) => {
        if (topic.topic === "linkPreview") asked.push(topic);
      },
    });

    render(
      core.wrap(
        <StillfailPreviewPanel
          active
          onTitleChange={onTitleChange}
          preview={{
            id: samplePreview.href,
            href: samplePreview.href,
            workspaceId: "wsp-1",
          }}
        />
      )
    );
    await flush();

    const panel = screen.getByTestId("stillfail-preview-panel");
    expect(panel).toHaveTextContent("Duo monoid 发热排查");
    expect(panel).toHaveTextContent("pengx17");
    expect(panel).toHaveTextContent("Waiting for you");
    expect(panel).toHaveTextContent("帮我查一下手机发热");
    expect(panel).toHaveTextContent("已定位到后台轮询过频，补丁已就绪。");
    expect(panel).toHaveTextContent("重签并安装");
    expect(panel).toHaveTextContent("先不装");
    expect(onTitleChange).toHaveBeenCalledWith("Duo monoid 发热排查");

    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await flush();
    expect(asked.some((t) => t.topic === "linkPreview" && t.read === "1")).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "Open in still.fail" }));
    expect(openExternalSpy).toHaveBeenCalledWith(samplePreview.href);
  });

  it("auto-refreshes on stationTasks updates and polls while running but not once done", async () => {
    const asked: Record<string, unknown>[] = [];
    let previewValue: LinkPreviewValue = {
      status: "ready",
      preview: { ...samplePreview, status: "running" },
    };
    let tasksValue: StationTasksValue = {
      state: "ready",
      tasks: [
        {
          id: samplePreview.ref,
          station: "st-1",
          device: "dev-1",
          machine: { name: "pengx17", online: true },
          thread: "chat:c-1",
          title: samplePreview.title,
          status: "in_progress",
          createdBy: null,
          createdAt: 1_000,
          lastActivityAt: 10_000,
          runtime: null,
          model: null,
          labels: [],
          url: samplePreview.href,
        },
      ],
    };

    const core = createScriptedCore({
      values: (topic) => {
        if (topic.topic === "linkPreview") return previewValue;
        if (topic.topic === "stationTasks") return tasksValue;
        return undefined;
      },
      onSubscribe: (topic) => {
        if (topic.topic === "linkPreview") asked.push(topic);
      },
    });

    render(
      core.wrap(
        <StillfailPreviewPanel
          active
          preview={{
            id: samplePreview.href,
            href: samplePreview.href,
            workspaceId: "wsp-1",
          }}
        />
      )
    );
    await flush();
    expect(asked).toHaveLength(1);

    // 1. Station index update bumps refresh immediately without waiting for timer.
    tasksValue = {
      ...tasksValue,
      tasks: [{ ...tasksValue.tasks[0]!, lastActivityAt: 11_000 }],
    };
    core.changed("stationTasks");
    await flush();
    expect(asked.some((t) => t.read === "1")).toBe(true);

    // 2. While running, bounded 4s poll keeps live messages fresh.
    await advance(4_000);
    await flush();
    expect(asked.some((t) => t.read === "2")).toBe(true);

    // 3. Once done, background polling stops.
    previewValue = {
      status: "ready",
      preview: { ...samplePreview, status: "done" },
    };
    core.changed("linkPreview");
    await flush();
    const countAfterDone = asked.length;
    await advance(15_000);
    await flush();
    expect(asked).toHaveLength(countAfterDone);
  });

  it("shows offline notice and cached note when station is offline", async () => {
    const value: LinkPreviewValue = {
      status: "ready",
      preview: {
        ...samplePreview,
        offline: true,
        messages: [],
      },
    };
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "linkPreview" ? value : undefined),
    });

    render(
      core.wrap(
        <StillfailPreviewPanel
          active
          preview={{
            id: samplePreview.href,
            href: samplePreview.href,
            workspaceId: "wsp-1",
          }}
        />
      )
    );
    await flush();

    const panel = screen.getByTestId("stillfail-preview-panel");
    expect(panel).toHaveTextContent("Station offline");
    expect(panel).toHaveTextContent("决定是否重签重装");
  });

  it("keeps cached messages visible during background loading and transient offline blips, and skips empty bubbles", async () => {
    let previewValue: LinkPreviewValue = {
      status: "ready",
      preview: {
        ...samplePreview,
        messages: [
          ...samplePreview.messages,
          {
            seq: 3,
            authorKind: "person",
            author: "peng@example.com",
            text: "   ",
            createdAt: null,
            card: null,
          },
        ],
      },
    };
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "linkPreview" ? previewValue : undefined),
    });

    render(
      core.wrap(
        <StillfailPreviewPanel
          active
          preview={{
            id: samplePreview.href,
            href: samplePreview.href,
            workspaceId: "wsp-1",
          }}
        />
      )
    );
    await flush();

    const panel = screen.getByTestId("stillfail-preview-panel");
    expect(panel.querySelectorAll("article.comma-stillfail-row")).toHaveLength(2);
    expect(panel).toHaveTextContent("已定位到后台轮询过频，补丁已就绪。");

    // 1. Background refresh enters loading: messages stay mounted without blanking to a spinner.
    previewValue = { status: "loading" };
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    core.changed("linkPreview");
    await flush();
    expect(panel).toHaveTextContent("已定位到后台轮询过频，补丁已就绪。");

    // 2. Transient offline response with empty messages keeps cached messages and shows banner.
    previewValue = {
      status: "ready",
      preview: {
        ...samplePreview,
        offline: true,
        messages: [],
      },
    };
    core.changed("linkPreview");
    await flush();
    expect(panel).toHaveTextContent("Station offline");
    expect(panel).toHaveTextContent("已定位到后台轮询过频，补丁已就绪。");
    expect(panel.querySelectorAll("article.comma-stillfail-row")).toHaveLength(2);
  });
});
