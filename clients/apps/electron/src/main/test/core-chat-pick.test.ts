import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { settle } from "@comma/test-utils/settle";
import { HostError } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import {
  FakeDesktop,
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "@comma/core/testing";
import type { ChatAttachmentPickInput } from "../modules/local-files/picker";
import { MainChat } from "../modules/chat";
import { createCoreChatPick } from "../modules/chat/pick";

// The file's timers run on the test's clock: a test moves it.
beforeEach(() => {
  vi.useFakeTimers();
});

const clients: CoreClient[] = [];
afterEach(() => {
  for (const client of clients.splice(0)) client.close();
});

const file = {
  localFileRef: `lfi1_${"a".repeat(43)}`,
  mediaType: "application/pdf",
  name: "report.pdf",
  size: 12,
};

/**
 * A client core (the real clock) whose desktop file dialog is Main's port (`createCoreChatPick`), with a picker that
 * registers as the real one does: it asks the core about the intake before each file.
 */
function harness(options: { windowOpen?: boolean } = {}) {
  const host = new FakeHost({ time: null });
  host.api.on("GET", "/v1/comma/groups/grp_1/conversations/cnv_1", {
    id: "cnv_1",
    group_id: "grp_1",
    kind: "user_chat",
    status: "active",
    title: "Current chat",
    messages: [],
  });
  host.api.onStream("/v1/comma/groups/grp_1/conversations/cnv_1/events");
  host.api.on(
    "POST",
    "/v1/comma/groups/grp_1/files",
    json(200, {
      name: "photo.png",
      path: `/uploads/${"u".repeat(22)}-photo.png`,
      size: 3,
    })
  );
  const desktop = new FakeDesktop();
  host.desktop = desktop;
  const core = startTestCore(host);
  core.observeSession(signedIn());
  const mainClient = new CoreClient(inProcessOpener(core, host));
  const window = new CoreClient(inProcessOpener(core, host, "win_main"));
  clients.push(mainClient, window);
  const seen: ChatAttachmentPickInput[] = [];
  const picker = {
    pickForChat: vi.fn(async (input: ChatAttachmentPickInput) => {
      seen.push(input);
      input.onDialogClosed?.();
      await input.refreshLocalFileRegistration?.();
      input.assertLocalFileRegistrationAllowed();
      return {
        cancelled: false,
        errors: [],
        items: [
          {
            kind: "upload" as const,
            name: "photo.png",
            size: 3,
            bytes: Uint8Array.of(1, 2, 3),
          },
          { kind: "local_file" as const, file },
        ],
      };
    }),
  };
  const leases: unknown[] = [];
  const pick = createCoreChatPick({
    chat: new MainChat(() => mainClient),
    picker: () => picker,
    guard: {
      runLease: async (lease, handler) => {
        leases.push(lease);
        return handler(() => undefined);
      },
    },
    windowContents: (surfaceId) =>
      surfaceId === "win_main" && options.windowOpen !== false ? 7 : undefined,
  });
  // Main's answer, or why it failed, as the utility process passes them on.
  desktop.pick = (request) =>
    pick(request, new AbortController().signal).catch(
      (error: Error) => new HostError(error.message)
    );
  const target = {
    workspaceId: "wsp_1",
    groupId: "grp_1",
    conversationId: "cnv_1",
    subscriberId: "win_main:grp_1/cnv_1",
    leaseId: "00000000-0000-4000-8000-000000000001",
  };
  /** The window's draft attachments in the first chat snapshot it is sent where `ready` holds of them. */
  const draft = async (
    ready: (rows: { name: string; status: string }[]) => boolean = () => true
  ) =>
    settle(
      new Promise<{ name: string; status: string }[]>((resolve) => {
        const stop = window.subscribe(
          { topic: "chat", surface: "win_main" },
          (value) => {
            const session = (
              value as {
                snapshot: {
                  sessions: {
                    conversationId: string;
                    state: { draftAttachments: { name: string; status: string }[] };
                    surfaceProjections?: {
                      subscriberId: string;
                      state: { draftAttachments: { name: string; status: string }[] };
                    }[];
                  }[];
                };
              }
            ).snapshot.sessions.find((s) => s.conversationId === "cnv_1");
            const rows =
              (
                session?.surfaceProjections?.find(
                  (p) => p.subscriberId === target.subscriberId
                )?.state ?? session?.state
              )?.draftAttachments ?? [];
            if (!ready(rows)) return;
            resolve(rows);
            queueMicrotask(stop);
          },
          () => undefined
        );
      })
    );
  /** The window's view of cnv_1, as its calls name it; showing it retains the conversation. */
  const view = {
    workspace: "wsp_1",
    group: "grp_1",
    conversation: "cnv_1",
    surface: "win_main",
  };
  const show = () =>
    settle(
      new Promise<void>((resolve) => {
        window.subscribe(
          { topic: "chatView", ...view },
          (value) => {
            if ((value as { state: unknown }).state) resolve();
          },
          () => undefined
        );
      })
    );
  return { window, picker, seen, leases, draft, view, show };
}

describe("a window's file pick through the core", () => {
  it("opens the dialog on that window and attaches what Main registered under the core's intake", async () => {
    const h = harness();
    await h.show();
    expect(await h.window.call("chatView.pickAttachments", h.view)).toBe(true);
    expect(h.seen[0]).toMatchObject({
      dialogOwnerWebContentsId: 7,
      localFileIntakeId: expect.any(String),
      workspaceId: "wsp_1",
    });
    expect(h.leases).toEqual([
      expect.objectContaining({ sessionId: "session-user-1" }),
    ]);
    const attached = await h.draft((rows) => rows.length === 2);
    expect(attached.map((row) => row.name)).toEqual(["photo.png", "report.pdf"]);
  });

  it("refuses a pick for a window that is no longer open, leaving the intake failed", async () => {
    const h = harness({ windowOpen: false });
    await h.show();
    await expect(
      settle(h.window.call("chatView.pickAttachments", h.view))
    ).rejects.toThrow("not open");
    expect(h.picker.pickForChat).not.toHaveBeenCalled();
    expect(await h.draft()).toEqual([expect.objectContaining({ status: "failed" })]);
  });

  it("registers no more files once the core gave the pick up", async () => {
    const intake = {
      intakeId: "intake-1",
      refresh: vi.fn(async () => undefined),
      assertCurrent: vi.fn(),
      markDialogClosed: vi.fn(),
    };
    const controller = new AbortController();
    let allowed: (() => void) | undefined;
    const pick = createCoreChatPick({
      chat: { intake: () => intake },
      picker: () => ({
        pickForChat: async (input) => {
          allowed = input.assertLocalFileRegistrationAllowed;
          return { cancelled: true, errors: [], items: [] };
        },
      }),
      guard: { runLease: async (_lease, handler) => handler(() => undefined) },
      windowContents: () => 7,
    });
    await pick(
      {
        intakeId: "intake-1",
        surfaceId: "win_main",
        workspaceId: "wsp_1",
        lease: {
          audience: "a",
          authorityInstanceId: "b",
          generation: 1,
          sessionId: "c",
        },
        maxFiles: 1,
        maxTotalSize: 1,
        maxUploadFiles: 1,
      },
      controller.signal
    );
    expect(() => allowed?.()).not.toThrow();
    controller.abort();
    expect(() => allowed?.()).toThrow("gave this pick up");
  });
});
