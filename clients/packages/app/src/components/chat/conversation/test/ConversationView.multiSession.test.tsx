import { initializeCommaI18n } from "@comma/i18n";
import { CoreProvider, type CoreClient } from "@comma/core-client";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ConversationView, type ConversationViewActions } from "../ConversationView";
import {
  WorkerSessionsRoster,
  workerSessionVendor,
} from "../../tasks/WorkerSessionsRoster";
import type { ChatWorkerSession, ConversationChannelState } from "@comma/core/chat";

const noop = () => {};

const fakeDraftSource = {
  subscribe: () => noop,
  getSnapshot: () => "",
};

const fakeCore: CoreClient = {
  call: async () => undefined,
  subscribe: () => () => {},
} as unknown as CoreClient;

function makeState(workerSessions?: ChatWorkerSession[]): ConversationChannelState {
  return {
    status: "ready",
    connection: "live",
    conversation: {
      id: "cnv_task_run_switch",
      group_id: "grp_1",
      kind: "agent_task",
      title: "Run Switch Guard",
      status: "active",
      labels: [],
      updated_at: 1_732_464_000,
    },
    messages: [],
    serverMessages: [],
    pending: [],
    reply: {
      coming: false,
      thinking: false,
      streaming: false,
      working: false,
      failed: false,
      timedOut: false,
    },
    taskRun: {
      place: { kind: "salix" },
      model: { kind: "catalog", name: "claude-sonnet-4-6" },
      vendor: "anthropic",
    },
    ...(workerSessions ? { workerSessions } : {}),
    draft: "",
    draftAttachments: [],
    questionAttachments: {},
  } as unknown as ConversationChannelState;
}

const leadSession: ChatWorkerSession = {
  participantId: "prt_lead",
  slot: "lead",
  label: "Lead",
  model: "claude-sonnet-4-6",
  isPrimary: true,
  subscribed: true,
  state: "active",
  status: "Working",
  updatedAt: 1_732_464_000,
};

const reviewerSession: ChatWorkerSession = {
  participantId: "prt_rev",
  slot: "reviewer",
  label: "Reviewer",
  model: "gpt-5.3-codex",
  isPrimary: false,
  subscribed: true,
  state: "waiting",
  status: "Waiting",
  updatedAt: 1_732_464_000,
};

describe("ConversationView multi-session run switch guard (R1 Item 10)", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("disables model switching for multi-worker Tasks and auto-closes an open switch dialog on 1->2 upgrade", async () => {
    const actions: ConversationViewActions = {
      discard: noop,
      refresh: noop,
      removeAttachment: noop,
      retry: noop,
      retryAttachment: noop,
      send: noop,
      setDraft: noop,
      setTaskRun: vi.fn(async () => undefined),
    };

    const view = render(
      <CoreProvider client={fakeCore}>
        <ConversationView
          actions={actions}
          conversationId="cnv_task_run_switch"
          draftSource={fakeDraftSource as never}
          groupId="grp_1"
          state={makeState([leadSession])}
          workspaceId="wsp_1"
        />
      </CoreProvider>
    );

    // Single-worker Task exposes the model row and model switch button in Environment.
    expect(screen.getByTestId("task-panel-run-model")).toBeTruthy();
    const switchBtn = screen.getByTestId("task-panel-run-switch");
    expect(switchBtn).toBeTruthy();

    // Open the switch dialog.
    await act(async () => {
      fireEvent.click(switchBtn);
    });
    expect(screen.getByRole("dialog")).toBeTruthy();

    // Upgrade to 2 worker sessions while dialog is open -> dialog closes and switch button disappears.
    await act(async () => {
      view.rerender(
        <CoreProvider client={fakeCore}>
          <ConversationView
            actions={actions}
            conversationId="cnv_task_run_switch"
            draftSource={fakeDraftSource as never}
            groupId="grp_1"
            state={makeState([leadSession, reviewerSession])}
            workspaceId="wsp_1"
          />
        </CoreProvider>
      );
    });

    expect(screen.queryByTestId("task-panel-run-model")).toBeNull();
    expect(screen.queryByTestId("task-panel-run-switch")).toBeNull();
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("A-P1-5: omits status dot and Idle text for unsubscribed preview sessions, but renders them for live sessions", () => {
    const previewSessions: ChatWorkerSession[] = [
      {
        participantId: "prt_lead",
        slot: "lead",
        label: "Lead",
        model: "claude-sonnet-4-6",
        isPrimary: true,
        subscribed: false,
        state: "stopped",
        status: "",
      },
      {
        participantId: "prt_rev",
        slot: "reviewer",
        label: "Reviewer",
        model: "gpt-5.3-codex",
        isPrimary: false,
        subscribed: false,
        state: "stopped",
        status: "",
      },
    ];

    const view = render(<WorkerSessionsRoster sessions={previewSessions} />);

    expect(screen.getByText("Sonnet-4-6")).toBeTruthy();
    expect(screen.getByText("GPT-5.3-codex")).toBeTruthy();
    expect(screen.getByText("@lead")).toBeTruthy();
    expect(screen.getByText("@reviewer")).toBeTruthy();
    expect(view.container.querySelectorAll(".comma-worker-session-dot")).toHaveLength(
      0
    );
    expect(view.container.textContent).not.toContain("Idle");
    expect(screen.queryByText(/Idle/)).toBeNull();

    view.rerender(<WorkerSessionsRoster sessions={[leadSession, reviewerSession]} />);

    expect(
      view.container.querySelectorAll('.comma-worker-session-dot[data-state="active"]')
    ).toHaveLength(1);
    expect(
      view.container.querySelectorAll('.comma-worker-session-dot[data-state="waiting"]')
    ).toHaveLength(1);
    expect(screen.getByText("Lead, claude-sonnet-4-6, Active: Working")).toBeTruthy();
    expect(screen.getByText("Reviewer, gpt-5.3-codex, Waiting")).toBeTruthy();
  });

  it("Astra R5 P1: keyboard Tab focuses a session row to reveal its Tooltip and Escape dismisses it", async () => {
    const user = userEvent.setup();
    render(<WorkerSessionsRoster sessions={[leadSession, reviewerSession]} />);

    await user.tab();
    const tooltip = await screen.findByRole("tooltip");
    expect(tooltip.textContent).toContain("claude-sonnet-4-6");
    expect(tooltip.textContent).toContain("Working");

    await user.keyboard("{Escape}");
    await waitFor(() => {
      expect(screen.queryByRole("tooltip")).toBeNull();
    });
  });

  it("workerSessionVendor maps runtime and falls back to model prefix for salix/empty runtime", () => {
    expect(workerSessionVendor("claude", undefined)).toBe("anthropic");
    expect(workerSessionVendor("codex", undefined)).toBe("openai");
    expect(workerSessionVendor("gemini", undefined)).toBe("google");
    expect(workerSessionVendor("salix", "claude-sonnet-4-6")).toBe("anthropic");
    expect(workerSessionVendor("salix", "gpt-5.3-codex")).toBe("openai");
    expect(workerSessionVendor(undefined, "o3-mini")).toBe("openai");
    expect(workerSessionVendor("", "google/gemini-3-pro")).toBe("google");
    expect(workerSessionVendor("salix", "custom-local-model")).toBeUndefined();
  });
});
