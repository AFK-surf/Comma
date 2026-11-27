import { render, screen, waitFor } from "@comma/test-utils/render";
import { act, fireEvent, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as messages from "@comma/i18n/messages";
import { startFailure } from "../../people/startFailure";
import {
  clearStoredGuestSession,
  CollabGuestError,
  type CollabGuestClient,
} from "../collabGuestApi";
import { CollabGuestApp } from "../CollabGuestApp";

class FakeEventSource {
  static instances: FakeEventSource[] = [];
  readonly url: string;
  private listeners = new Map<string, Array<(e: MessageEvent<string>) => void>>();
  onerror: ((e: Event) => void) | null = null;
  closed = false;

  constructor(url: string) {
    this.url = url;
    FakeEventSource.instances.push(this);
  }

  addEventListener(type: string, listener: (e: MessageEvent<string>) => void) {
    const list = this.listeners.get(type) ?? [];
    list.push(listener);
    this.listeners.set(type, list);
  }

  emit(type: string, data = "") {
    const event = { data } as MessageEvent<string>;
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event);
    }
  }

  close() {
    this.closed = true;
  }
}

function makeMockClient(overrides: Partial<CollabGuestClient> = {}): CollabGuestClient {
  return {
    getInvite: vi.fn(async () => ({
      status: "invited" as const,
      email_hint: "a***@partner.io",
      expires_at: "2026-11-30T00:00:00Z",
      title: "Q4 Launch Coordination",
      host_name: "Maya Lin",
    })),
    requestOtp: vi.fn(async () => ({
      challenge_id: "chg_1",
      expires_in_seconds: 600,
      resend_after_seconds: 30,
      email_hint: "a***@partner.io",
    })),
    verifyOtp: vi.fn(async ({ name }) => ({
      token: "cgs_session_token_123",
      expires_at: "2026-12-01T00:00:00Z",
      guest: { email: "alex@partner.io", name: name ?? "Alex" },
      task: {
        group_id: "grp_iso_1",
        conversation_id: "cnv_task_1",
        title: "Q4 Launch Coordination",
        status: "running",
      },
    })),
    getTask: vi.fn(async () => ({
      guest: { email: "alex@partner.io", name: "Alex" },
      task: {
        group_id: "grp_iso_1",
        conversation_id: "cnv_task_1",
        title: "Q4 Launch Coordination",
        status: "running",
        host_name: "Maya Lin",
        members: [
          {
            role: "host" as const,
            name: "Maya Lin",
            status: "active" as const,
            is_guest: false,
            is_self: false,
          },
          {
            role: "member" as const,
            name: "Alex",
            status: "active" as const,
            is_guest: true,
            is_self: true,
          },
          {
            role: "member" as const,
            name: null,
            status: "invited" as const,
            is_guest: true,
            is_self: false,
          },
        ],
      },
      messages: [
        {
          id: "m1",
          role: "user",
          sender_name: "Maya Lin",
          text: "Welcome! Let's review the launch checklist together.",
        },
        {
          id: "m2",
          role: "assistant",
          content: [
            { type: "text", text: "I prepared the live launch tracker for this task." },
            {
              type: "mini_app",
              app_id: "app_tracker_1",
              name: "Launch Tracker",
              summary: "Interactive milestones and owner status",
              version: 2,
            },
          ],
        },
      ],
      next_cursor: null,
    })),
    sendMessage: vi.fn(async (_token, { text }) => ({
      id: "m3",
      role: "user" as const,
      senderName: "Alex",
      isGuestSender: true,
      isSelf: true,
      text,
      miniApps: [],
      attachments: [],
    })),
    listFiles: vi.fn(async () => ({
      entries: [{ path: "/task/launch-brief.pdf", size: 1_500_000 }],
    })),
    uploadFile: vi.fn(async () => {}),
    leaveTask: vi.fn(async () => {}),
    eventsUrl: (t) =>
      `/v1/comma/public/collaborations/task/events?token=${encodeURIComponent(t)}`,
    openEvents: (t) =>
      new FakeEventSource(
        `/v1/comma/public/collaborations/task/events?token=${encodeURIComponent(t)}`
      ) as unknown as EventSource,
    downloadFileUrl: (t, p) =>
      `/v1/comma/public/collaborations/task/files/download?path=${encodeURIComponent(p)}&token=${encodeURIComponent(t)}`,
    ...overrides,
  };
}

describe("CollabGuestApp & error mappings", () => {
  afterEach(() => {
    clearStoredGuestSession("tok_otp");
    clearStoredGuestSession("tok_expired");
    clearStoredGuestSession("tok_quota");
    clearStoredGuestSession("tok_revoke");
    clearStoredGuestSession("tok_live");
    FakeEventSource.instances = [];
  });

  it("completes OTP verification with display name, renders Mini App link, enforces member privacy, and sends @Comma message", async () => {
    const client = makeMockClient();

    render(<CollabGuestApp client={client} inviteToken="tok_otp" />);

    const otpGate = await screen.findByTestId("collab-guest-otp-gate");
    expect(otpGate).toBeVisible();
    expect(within(otpGate).getByText("Q4 Launch Coordination")).toBeVisible();

    const emailInput = otpGate.querySelector<HTMLInputElement>('input[type="email"]')!;
    fireEvent.change(emailInput, {
      target: { value: "alex@partner.io" },
    });
    fireEvent.change(otpGate.querySelector('input[autocomplete="name"]')!, {
      target: { value: "Alex Chen" },
    });
    fireEvent.submit(emailInput.closest("form")!);

    expect(await screen.findByText("Check your email")).toBeVisible();
    expect(client.requestOtp).toHaveBeenCalledWith("alex@partner.io");

    // The sixth digit verifies, as the app's own sign-in does.
    fireEvent.change(document.querySelector('input[autocomplete="one-time-code"]')!, {
      target: { value: "482910" },
    });

    expect(await screen.findByTestId("collab-guest-workspace")).toBeVisible();
    expect(client.verifyOtp).toHaveBeenCalledWith({
      challengeId: "chg_1",
      code: "482910",
      name: "Alex Chen",
    });

    // A Mini App is a link to its authenticated collaboration route
    await waitFor(() =>
      expect(
        document.querySelector(
          'a[href="/#/collaborations/grp_iso_1/cnv_task_1/apps/app_tracker_1?version=2"]'
        )
      ).not.toBeNull()
    );

    // Unnamed invited member displays neutral placeholder, never an email
    const membersPanel = screen.getByTestId("collab-guest-members-panel");
    expect(membersPanel.textContent).toContain("Pending");
    expect(membersPanel.textContent).not.toMatch(/[^\s@]+@[^\s@]+\.[^\s@]+/);

    // Typing @Comma asks Comma, as in the app's Task together
    const composer = screen.getByTestId("collab-guest-composer-input");
    fireEvent.change(composer, { target: { value: "@Comma summarize action items" } });
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));

    await waitFor(() => {
      expect(client.sendMessage).toHaveBeenCalledWith("cgs_session_token_123", {
        text: "@Comma summarize action items",
        mentionComma: true,
      });
    });
  });

  it("shows 410 expired invite screen with 7-day message and Use full Comma CTA", async () => {
    const client = makeMockClient({
      getInvite: vi.fn(async () => {
        throw new CollabGuestError("invite_expired", 410);
      }),
    });

    render(<CollabGuestApp client={client} inviteToken="tok_expired" />);

    const status = await screen.findByTestId("collab-guest-status-expired");
    expect(status.textContent).toContain("links expire after 7 days");
    expect(screen.getByRole("button", { name: "Use full Comma" })).toBeVisible();
  });

  it("shows an inline error when a file is over the size limit and revokes access on SSE revoked event", async () => {
    window.sessionStorage.setItem(
      "comma:collab-guest:v1:tok_revoke",
      JSON.stringify({ token: "cgs_live_token" })
    );
    const client = makeMockClient({
      uploadFile: vi.fn(async () => {
        throw new CollabGuestError("file_too_large", 413);
      }),
    });

    const { container } = render(
      <CollabGuestApp client={client} inviteToken="tok_revoke" />
    );

    expect(await screen.findByTestId("collab-guest-workspace")).toBeVisible();

    // Trigger a file upload the server refuses as too large
    const fileInput = container.querySelector('input[type="file"]') as HTMLInputElement;
    const file = new File(["hello"], "big-deck.pdf", { type: "application/pdf" });
    fireEvent.change(fileInput, { target: { files: [file] } });

    const errorBanner = await screen.findByTestId("collab-guest-file-error");
    expect(errorBanner.textContent).toBe(messages.collab_guest_files_error_too_large());

    // Emit SSE revoked event -> clears storage and renders revoked screen
    expect(FakeEventSource.instances).toHaveLength(1);
    act(() => {
      FakeEventSource.instances[0]!.emit("revoked", "{}");
    });

    expect(await screen.findByTestId("collab-guest-status-revoked")).toBeVisible();
    expect(
      window.sessionStorage.getItem("comma:collab-guest:v1:tok_revoke")
    ).toBeNull();
  });

  it("refreshes task messages and files live when SSE emits task_updated", async () => {
    window.sessionStorage.setItem(
      "comma:collab-guest:v1:tok_live",
      JSON.stringify({ token: "cgs_live_token" })
    );

    const baseClient = makeMockClient();
    const initialTask = await baseClient.getTask("cgs_live_token");
    const updatedTask = {
      ...initialTask,
      messages: [
        ...initialTask.messages,
        {
          id: "m_live_reply",
          role: "user",
          sender_name: "Maya Lin",
          text: "Uploaded the updated deck for final sign-off.",
        },
      ],
    };

    const getTask = vi
      .fn<CollabGuestClient["getTask"]>()
      .mockResolvedValueOnce(initialTask)
      .mockResolvedValueOnce(updatedTask);
    const listFiles = vi
      .fn<CollabGuestClient["listFiles"]>()
      .mockResolvedValueOnce({
        entries: [{ path: "/task/launch-brief.pdf", size: 1_500_000 }],
      })
      .mockResolvedValueOnce({
        entries: [
          { path: "/task/launch-brief.pdf", size: 1_500_000 },
          { path: "/task/final-signoff.pdf", size: 2_000_000 },
        ],
      });

    const client = makeMockClient({ getTask, listFiles });
    render(<CollabGuestApp client={client} inviteToken="tok_live" />);

    expect(await screen.findByTestId("collab-guest-workspace")).toBeVisible();
    expect(FakeEventSource.instances).toHaveLength(1);

    // Initial resync on first connect should not cause a redundant refetch
    act(() => {
      FakeEventSource.instances[0]!.emit(
        "resync",
        JSON.stringify({ type: "task_resync_required" })
      );
    });
    expect(getTask).toHaveBeenCalledTimes(1);

    // Emit SSE task_updated -> refetches task + files and renders new message & file live
    act(() => {
      FakeEventSource.instances[0]!.emit(
        "task_updated",
        JSON.stringify({
          group_id: "grp_iso_1",
          conversation_id: "cnv_task_1",
          version: 2,
        })
      );
    });

    expect(
      await screen.findByText("Uploaded the updated deck for final sign-off.")
    ).toBeVisible();
    expect(await screen.findByText("final-signoff.pdf")).toBeVisible();
    expect(getTask).toHaveBeenCalledTimes(2);
    expect(listFiles).toHaveBeenCalledTimes(2);
  });

  it("offers Ask Comma under the guest's own line that did not name Comma, and sends @Comma", async () => {
    window.sessionStorage.setItem(
      "comma:collab-guest:v1:tok_live",
      JSON.stringify({ token: "cgs_live_token" })
    );
    const base = makeMockClient();
    const task = await base.getTask("cgs_live_token");
    const ownLine = {
      id: "m_own",
      role: "user",
      sender_name: "Alex",
      is_guest: true,
      is_self: true,
      content: [{ type: "text", text: "Can we move the launch to Thursday?" }],
    };
    const sendMessage = vi.fn(async () => ({
      id: "m_ask",
      role: "user" as const,
      senderName: "Alex",
      isGuestSender: true,
      isSelf: true,
      text: "@Comma",
      miniApps: [],
      attachments: [],
    }));
    const client = makeMockClient({
      getTask: vi.fn(async () => ({ ...task, messages: [...task.messages, ownLine] })),
      sendMessage,
    });
    render(<CollabGuestApp client={client} inviteToken="tok_live" />);

    const chip = await screen.findByTestId("chat-suggestion-ask-comma");
    fireEvent.click(chip);
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith("cgs_live_token", {
        text: "@Comma",
        mentionComma: true,
      })
    );
    // Asked, the line that named Comma is the newest: no chip under it.
    await waitFor(() =>
      expect(screen.queryByTestId("chat-suggestion-ask-comma")).toBeNull()
    );
  });

  it("maps invite_daily_limit_reached in startFailure", () => {
    expect(
      startFailure({ status: 429, code: "invite_daily_limit_reached" }, messages)
    ).toContain("20 invite emails");
  });
});
