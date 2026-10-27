import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import type { ProductInboxListResult, QuickChatMessage } from "@comma/core/contract";
import type { NotchHostEvent, NotchTaskItem } from "@comma/native-bridge";
import {
  signedInSessionSnapshotSchema,
  signedOutSessionSnapshotSchema,
} from "@comma/session-contract";
import type { CommaLocale } from "@comma/i18n";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { realMainClock } from "../clock";
import { QuickChatService, type QuickChatServiceOptions } from "../quick-chat";

vi.mock("electron-log/main", () => ({
  default: { warn: vi.fn() },
}));

const requestId = "0f8fad5b-d9cb-469f-a165-70867728950e";
/** The n-th of many requests, in the helper's id shape. */
const nthRequest = (n: number) => String(n).padStart(16, "r");
const click = (fixture: ReturnType<typeof createFixture>, id: string) =>
  fixture.emitNotch({ payload: { action: "task:open", value: id }, type: "action" });

const signedIn = (generation: number, kind?: "guest" | "registered") =>
  signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation,
    revision: generation,
    phase: "signed_in",
    principal: {
      email: "ada@example.test",
      userId: "user-1",
      ...(kind ? { kind } : {}),
    },
    session: {
      audience: "https://api.example.test",
      expiresAtEpochSeconds: 1_900_000_000,
      sessionId: `session-${generation}`,
    },
  });

const signedOut = (generation: number) =>
  signedOutSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation,
    revision: generation,
    phase: "signed_out",
    principal: null,
    reason: "user_signed_out",
    session: null,
  });

function list(
  items: Array<{
    id: string;
    status: string;
    title: string;
    parentMessageId?: string;
    statusBucket?: "in_progress" | "done";
  }>
): ProductInboxListResult {
  return {
    activeWorkspaceId: "workspace-1",
    items: items.map(({ id, status, title, parentMessageId, statusBucket }) => ({
      ...(parentMessageId ? { parentMessageId } : {}),
      ...(statusBucket ? { statusBucket } : {}),
      conversationId: id.split(":")[1]!,
      groupId: id.split(":")[0]!,
      id,
      kind: "agent_task",
      source: "salix.conversation",
      status,
      title,
      updatedAt: 1,
      workspaceId: "workspace-1",
      workspaceName: "Ada",
    })),
    source: "live-sync",
    workspaces: [{ group_id: "group-1", id: "workspace-1", name: "Ada" }],
  };
}

function deferred<Value>() {
  let resolve!: (value: Value) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<Value>((onResolve, onReject) => {
    resolve = onResolve;
    reject = onReject;
  });
  return { promise, reject, resolve };
}

function createFixture(overrides: Partial<QuickChatServiceOptions> = {}) {
  const hosts: FakeQuickChatHost[] = [];
  const shown: Array<{ items: NotchTaskItem[]; notify: boolean | undefined }> = [];
  const notchListeners = new Set<(event: NotchHostEvent) => void>();
  let locale: CommaLocale = "en";
  let listListener: ((list: ProductInboxListResult) => void) | undefined;
  const unsubscribeTasks = vi.fn(() => {
    listListener = undefined;
  });
  const sendMessage = vi.fn(
    (_params: { client_request_id: string; text: string }) =>
      deferred<QuickChatMessage>().promise
  );
  const transcribe = vi.fn(
    (_audio: Uint8Array, _purpose: "dictation" | "quick_chat_send") =>
      deferred<string>().promise
  );
  const notch = {
    close: vi.fn(),
    onEvent: (listener: (event: NotchHostEvent) => void) => {
      notchListeners.add(listener);
      return () => notchListeners.delete(listener);
    },
    setMainTasks: vi.fn(
      (items: readonly NotchTaskItem[], options?: { notify?: boolean }) => {
        shown.push({ items: [...items], notify: options?.notify });
      }
    ),
    showsMainTask: vi.fn(() => true),
  };
  const selectWorkspace = vi.fn(
    (_workspace: string): Promise<unknown> => Promise.resolve(null)
  );
  const openRoute = vi.fn();
  const service = new QuickChatService({
    sendMessage,
    hostPath: "/comma/QuickChatHost",
    isTestRun: () => false,
    locale: () => locale,
    notch,
    clock: { ...realMainClock, now: () => 1_787_563_260_000 },
    openRoute,
    osRelease: () => "25.6.0",
    pathExists: () => true,
    platform: "darwin",
    productName: "Comma",
    spawnHost: () => {
      const host = new FakeQuickChatHost();
      hosts.push(host);
      return host as unknown as ChildProcessWithoutNullStreams;
    },
    selectWorkspace,
    subscribeTasks: (listener) => {
      listListener = listener;
      return unsubscribeTasks;
    },
    transcribe,
    ...overrides,
  });
  return {
    sendMessage,
    transcribe,
    hosts,
    notch,
    openRoute,
    selectWorkspace,
    publishList: (value: ProductInboxListResult) => listListener?.(value),
    service,
    setLocale: (next: CommaLocale) => {
      locale = next;
    },
    emitNotch: (event: NotchHostEvent) => {
      for (const listener of notchListeners) listener(event);
    },
    lastShown: () => shown.at(-1),
    shown,
    unsubscribeTasks,
  };
}

/**
 * A running helper that said it is ready, with its first `configure` read,
 * and (unless `list: false`) the Task list naming the workspace in focus.
 */
async function readyHost(
  fixture: ReturnType<typeof createFixture>,
  { list: listed = true }: { list?: boolean } = {}
) {
  fixture.service.sessionChanged(signedIn(1));
  const host = fixture.hosts.at(-1)!;
  host.emitEvent({ type: "ready" });
  await expect(host.nextCommand()).resolves.toMatchObject({ type: "configure" });
  if (listed) fixture.publishList(list([]));
  return host;
}

describe("QuickChatService", () => {
  // Stopping a helper and restarting one set timers; they run on the test clock.
  beforeEach(() => {
    vi.useFakeTimers();
  });

  it("starts no helper before macOS 26, for a guest, or in a test run", () => {
    const older = createFixture({ osRelease: () => "24.6.0" });
    older.service.sessionChanged(signedIn(1));
    const guest = createFixture();
    guest.service.sessionChanged(signedIn(1, "guest"));
    const testRun = createFixture({ isTestRun: undefined });
    testRun.service.sessionChanged(signedIn(1));

    expect(older.hosts).toHaveLength(0);
    expect(guest.hosts).toHaveLength(0);
    expect(testRun.hosts).toHaveLength(0);
  });

  it("starts Windows' native helper from Windows 10 2004 and tells it Comma's AppUserModelID", async () => {
    const started: Array<{
      path: string;
      args: readonly string[];
      env: NodeJS.ProcessEnv;
      host: FakeQuickChatHost;
    }> = [];
    const windows = (osRelease: string) =>
      createFixture({
        hostPath: "C:/Comma/resources/native/win32/x64/QuickChatHost.exe",
        appUserModelId: "surf.comma.desktop",
        osRelease: () => osRelease,
        platform: "win32",
        spawnHost: (path, env, args) => {
          const host = new FakeQuickChatHost();
          started.push({ path, args, env, host });
          return host as unknown as ChildProcessWithoutNullStreams;
        },
      });
    windows("10.0.18363").service.sessionChanged(signedIn(1));
    expect(started).toHaveLength(0);

    windows("10.0.26100").service.sessionChanged(signedIn(1));
    expect(started).toHaveLength(1);
    expect(started[0]).toMatchObject({
      path: "C:/Comma/resources/native/win32/x64/QuickChatHost.exe",
      args: [],
    });
    // What a Windows program needs to start, and nothing of Main's own.
    expect(Object.keys(started[0]!.env)).not.toContain("LANG");
    const host = started[0]!.host;
    host.emitEvent({ type: "ready" });
    await expect(host.nextCommand()).resolves.toMatchObject({
      type: "configure",
      appUserModelId: "surf.comma.desktop",
    });
  });

  it("shows a send immediately, then opens its acknowledged Home without inventing a Task", async () => {
    const fixture = createFixture();
    const sent = deferred<QuickChatMessage>();
    fixture.sendMessage.mockReturnValueOnce(sent.promise);
    const host = await readyHost(fixture);
    const id = `quick-chat:${requestId}`;
    const submit = {
      requestId,
      text: "Plan the design review for Friday",
      type: "submit",
    };
    host.emitEvent(submit);
    expect(fixture.lastShown()).toEqual({
      items: [
        expect.objectContaining({
          id,
          title: "Plan the design review for Friday",
          status: "in_progress",
          subtitle: "Sending…",
        }),
      ],
      notify: true,
    });
    expect(fixture.sendMessage).toHaveBeenCalledExactlyOnceWith({
      client_request_id: requestId,
      text: submit.text,
      workspace: "workspace-1",
    });
    sent.resolve({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-1",
    });
    await expect(host.nextCommand()).resolves.toEqual({
      ok: true,
      requestId,
      type: "result",
    });
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({
        id,
        conversationId: "home-1",
        title: "Plan the design review for Friday",
        status: "sent",
        subtitle: "Sent",
      }),
    ]);
    // Neither a duplicate helper event nor an unrelated Task can change this receipt.
    host.emitEvent(submit);
    fixture.publishList(
      list([{ id: "group-1:unrelated", status: "active", title: "Another task" }])
    );
    expect(fixture.sendMessage).toHaveBeenCalledTimes(1);
    // A sent message opens Home, once the app works in the workspace it went to.
    const selected = deferred<unknown>();
    fixture.selectWorkspace.mockReturnValueOnce(selected.promise);
    click(fixture, id);
    expect(fixture.selectWorkspace).toHaveBeenCalledExactlyOnceWith("workspace-1");
    expect(fixture.openRoute).not.toHaveBeenCalled();
    selected.resolve(null);
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.openRoute).toHaveBeenCalledExactlyOnceWith(
      "/?workspace=workspace-1"
    );
    fixture.setLocale("zh-CN");
    fixture.service.localeChanged();
    expect(fixture.lastShown()?.items[0]?.title).toBe(submit.text);
    expect(fixture.lastShown()?.items[0]?.subtitle).toBe("已发送");
    fixture.service.close();
  });

  it("opens Home for a sent message even when its workspace cannot be selected", async () => {
    const fixture = createFixture();
    fixture.sendMessage.mockResolvedValue({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-1",
    });
    fixture.selectWorkspace.mockRejectedValueOnce(new Error("signed out"));
    const host = await readyHost(fixture);
    host.emitEvent({ requestId, text: "Plan the design review", type: "submit" });
    await expect(host.nextCommand()).resolves.toMatchObject({
      type: "result",
      ok: true,
    });

    click(fixture, `quick-chat:${requestId}`);
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.openRoute).toHaveBeenCalledExactlyOnceWith(
      "/?workspace=workspace-1"
    );
    fixture.service.close();
  });

  it("turns a sent message into the Task the Router made of it, in the same row", async () => {
    const fixture = createFixture();
    fixture.sendMessage.mockResolvedValue({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-1",
    });
    const host = await readyHost(fixture);
    const id = `quick-chat:${requestId}`;
    host.emitEvent({
      requestId,
      text: "Plan the design review for Friday",
      type: "submit",
    });
    await expect(host.nextCommand()).resolves.toMatchObject({
      type: "result",
      ok: true,
    });
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, status: "sent", subtitle: "Sent" }),
    ]);

    // The Router answers the message with a Task: the row becomes that Task.
    const task = {
      id: "group-1:task-1",
      parentMessageId: "message-1",
      status: "active",
      statusBucket: "in_progress" as const,
      title: "Design review",
    };
    fixture.publishList(list([task]));
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({
        id,
        standsFor: "group-1:task-1",
        conversationId: "task-1",
        groupId: "group-1",
        status: "in_progress",
        subtitle: "In progress",
        title: "Design review",
      }),
    ]);
    fixture.publishList(list([{ ...task, title: "Friday design review" }]));
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, title: "Friday design review" }),
    ]);

    // The row is that Task now: a click opens the Task's chat, not Home.
    click(fixture, id);
    expect(fixture.openRoute).toHaveBeenCalledExactlyOnceWith(
      "/inbox/workspace-1/group-1/task-1"
    );
    expect(fixture.selectWorkspace).not.toHaveBeenCalled();

    // A Task that stops running leaves the Notch, as the renderer's rows do.
    fixture.publishList(list([{ ...task, status: "done", statusBucket: "done" }]));
    expect(fixture.lastShown()?.items).toEqual([]);
    fixture.service.close();
  });

  it("sends the server's transcript after the text the audio continued", async () => {
    const fixture = createFixture();
    fixture.sendMessage.mockResolvedValue({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-1",
    });
    const heard = deferred<string>();
    fixture.transcribe.mockReturnValueOnce(heard.promise);
    const host = await readyHost(fixture);
    fixture.publishList(list([]));

    host.emitEvent({
      audio: Buffer.from("m4a audio").toString("base64"),
      draft: "帮我",
      requestId,
      text: "帮我把 Githop上那个评论总结一下",
      type: "submit",
    });
    // The helper's local words appear immediately; sending waits for the server transcript.
    expect(fixture.lastShown()?.items[0]?.title).toBe(
      "帮我把 Githop上那个评论总结一下"
    );
    expect(new TextDecoder().decode(fixture.transcribe.mock.calls[0]![0])).toBe(
      "m4a audio"
    );
    // A send's audio waits for its turn at the server, unlike a pause's.
    expect(fixture.transcribe.mock.calls[0]![1]).toBe("quick_chat_send");
    expect(fixture.sendMessage).not.toHaveBeenCalled();

    heard.resolve(" 把 GitHub 上那个评论总结一下\n");
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.sendMessage).toHaveBeenCalledWith({
      client_request_id: requestId,
      text: "帮我把 GitHub 上那个评论总结一下",
      workspace: "workspace-1",
    });
    expect(fixture.lastShown()?.items[0]?.title).toBe(
      "帮我把 GitHub 上那个评论总结一下"
    );

    // Latin words keep a space between the draft and the server's words.
    const next = "1b4e28ba-2fa1-11d2-883f-0016d3cca427";
    fixture.transcribe.mockResolvedValueOnce("and remind me at three");
    host.emitEvent({
      audio: "bTRh",
      draft: "Book the room",
      requestId: next,
      text: "Book the room and remind me",
      type: "submit",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: next,
      text: "Book the room and remind me at three",
      workspace: "workspace-1",
    });

    // Chinese and a Latin word get one space, as the helper writes them.
    const third = "2c5f39cb-3fa2-42e3-994f-1127e4ddb538";
    fixture.transcribe.mockResolvedValueOnce("Kevin 下午开个 sync");
    host.emitEvent({
      audio: "bTRh",
      draft: "提醒我约",
      requestId: third,
      text: "提醒我约 Kevin",
      type: "submit",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: third,
      text: "提醒我约 Kevin 下午开个 sync",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("shows preparation immediately, then sends the finished words once in the same row", async () => {
    const fixture = createFixture();
    const created = deferred<QuickChatMessage>();
    fixture.sendMessage.mockReturnValueOnce(created.promise);
    const host = await readyHost(fixture);
    const id = `quick-chat:${requestId}`;
    const preparing = { requestId, text: "Plan the revue", type: "preparing" };
    host.emitEvent(preparing);
    host.emitEvent(preparing);

    expect(fixture.shown).toEqual([
      {
        items: [
          expect.objectContaining({
            id,
            title: "Plan the revue",
            status: "in_progress",
          }),
        ],
        notify: true,
      },
    ]);
    expect(fixture.sendMessage).not.toHaveBeenCalled();

    const submit = {
      prepared: true,
      requestId,
      text: "Plan the review",
      type: "submit",
    };
    host.emitEvent(submit);
    host.emitEvent(submit);
    host.emitEvent(preparing);
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, title: "Plan the review", status: "in_progress" }),
    ]);
    expect(fixture.shown.filter((update) => update.notify)).toHaveLength(1);
    expect(fixture.sendMessage).toHaveBeenCalledExactlyOnceWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    expect(fixture.transcribe).not.toHaveBeenCalled();

    created.resolve({
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-1",
      workspace_id: "workspace-1",
    });
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: true, requestId });
    host.emitEvent(submit);
    host.emitEvent(preparing);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(1);
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({
        id: `quick-chat:${requestId}`,
        title: "Plan the review",
        status: "sent",
      }),
    ]);
    expect(host.queuedCommands()).toEqual([]);
    fixture.service.close();
  });

  it("bounds preparation from Return, keeps a retryable row and rejects late prepared words", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);
    const id = `quick-chat:${requestId}`;
    const preparing = { requestId, text: "Plan the review", type: "preparing" };
    host.emitEvent(preparing);
    await vi.advanceTimersByTimeAsync(20_000);
    host.emitEvent(preparing);
    host.emitEvent({
      requestId,
      text: "Plan the review tomorrow",
      type: "preparing",
      update: true,
    });
    await vi.advanceTimersByTimeAsync(10_000);
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: false, requestId });
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({
        id,
        status: "failed",
        title: "Plan the review tomorrow",
        subtitle: "Send failed, click to try again",
      }),
    ]);

    const late = {
      prepared: true,
      requestId,
      text: "Late corrected words",
      type: "submit",
    };
    host.emitEvent(late);
    host.emitEvent({
      requestId,
      text: "Late updated words",
      type: "preparing",
      update: true,
    });
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    click(fixture, id);
    host.emitEvent(late);
    expect(fixture.sendMessage).toHaveBeenCalledExactlyOnceWith({
      client_request_id: requestId,
      text: "Plan the review tomorrow",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("rejects an expired prepared submit even after its failed row leaves the Notch", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);
    for (let n = 1; n <= 6; n += 1) {
      host.emitEvent({
        requestId: nthRequest(n),
        text: `Send ${n}`,
        type: "preparing",
      });
    }
    await vi.advanceTimersByTimeAsync(30_000);
    expect(fixture.lastShown()?.items).toHaveLength(5);
    expect(
      fixture
        .lastShown()
        ?.items.some((item) => item.id === `quick-chat:${nthRequest(1)}`)
    ).toBe(false);
    host.emitEvent({
      requestId: nthRequest(1),
      text: "Late updated words",
      type: "preparing",
      update: true,
    });
    host.emitEvent({
      prepared: true,
      requestId: nthRequest(1),
      text: "Late words",
      type: "submit",
    });
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    expect(fixture.lastShown()?.items).toHaveLength(5);
    fixture.service.close();
  });

  it("keeps words retryable when their preparing helper exits and fences its late submit", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);
    const id = `quick-chat:${requestId}`;
    host.emitEvent({ requestId, text: "Plan the review", type: "preparing" });
    host.emitEvent({
      requestId,
      text: "Plan the review tomorrow",
      type: "preparing",
      update: true,
    });
    host.emit("exit", 1, null);
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({
        id,
        title: "Plan the review tomorrow",
        status: "failed",
      }),
    ]);
    await vi.advanceTimersByTimeAsync(1_000);
    const restarted = fixture.hosts.at(-1)!;
    const late = { prepared: true, requestId, text: "Late words", type: "submit" };
    host.emitEvent(late);
    restarted.emitEvent({
      requestId,
      text: "New helper words",
      type: "preparing",
      update: true,
    });
    restarted.emitEvent(late);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenCalledExactlyOnceWith({
      client_request_id: requestId,
      text: "Plan the review tomorrow",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("sends the helper's words when the server cannot transcribe the audio", async () => {
    const fixture = createFixture();
    fixture.transcribe.mockRejectedValueOnce(new Error("Transcription is busy."));
    const host = await readyHost(fixture);

    host.emitEvent({
      audio: "bTRh",
      requestId,
      text: "Plan the review",
      type: "submit",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.sendMessage).toHaveBeenCalledWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("transcribes background clips directly and waits for admission for clips finishing a send", async () => {
    const fixture = createFixture();
    fixture.transcribe
      .mockResolvedValueOnce(" 把 GitHub 上那个评论总结一下。\n")
      .mockRejectedValueOnce(new Error("Transcription is busy."));
    const host = await readyHost(fixture);

    host.emitEvent({ audio: "bTRh", clipId: requestId, type: "transcribe" });
    expect(await host.nextCommand()).toEqual({
      clipId: requestId,
      text: "把 GitHub 上那个评论总结一下。",
      type: "transcript",
    });
    expect(fixture.transcribe.mock.calls[0]![1]).toBe("dictation");
    const next = "1b4e28ba-2fa1-11d2-883f-0016d3cca427";
    host.emitEvent({
      audio: "bTRh",
      clipId: next,
      type: "transcribe",
      waitForSlot: true,
    });
    expect(await host.nextCommand()).toEqual({
      clipId: next,
      text: null,
      type: "transcript",
    });
    expect(fixture.transcribe.mock.calls[1]![1]).toBe("quick_chat_send");
    // Clip transcription alone does not send a message.
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    fixture.service.close();
  });

  it("gives the helper a live dictation ticket, or none when the server has no live dictation", async () => {
    const dictationTicket = vi
      .fn<() => Promise<{ url: string; ticket: string }>>()
      .mockResolvedValueOnce({
        url: "wss://api.comma.test/v1/comma/dictation",
        ticket: "t.s",
      })
      .mockRejectedValueOnce(new Error("dictation_unavailable"));
    const fixture = createFixture({ dictationTicket });
    const host = await readyHost(fixture);

    host.emitEvent({ requestId, type: "dictationTicket" });
    expect(await host.nextCommand()).toEqual({
      requestId,
      ticket: "t.s",
      type: "dictationTicket",
      url: "wss://api.comma.test/v1/comma/dictation",
    });
    const next = "1b4e28ba-2fa1-11d2-883f-0016d3cca427";
    host.emitEvent({ requestId: next, type: "dictationTicket" });
    expect(await host.nextCommand()).toEqual({
      requestId: next,
      type: "dictationTicket",
    });
    fixture.service.close();
  });

  it("keeps a send that could not be made in the Notch, and a click sends it again as it was", async () => {
    const fixture = createFixture();
    const created = deferred<QuickChatMessage>();
    fixture.sendMessage.mockReturnValueOnce(created.promise);
    const host = await readyHost(fixture);
    const id = `quick-chat:${requestId}`;

    host.emitEvent({ requestId, text: "Plan the review", type: "submit" });
    // The row names the workspace in focus as it was sent.
    expect(fixture.lastShown()?.items[0]).toMatchObject({
      groupId: "group-1",
      workspaceId: "workspace-1",
    });

    created.reject(new Error("network unavailable"));
    await expect(host.nextCommand()).resolves.toEqual({
      message: "network unavailable",
      ok: false,
      requestId,
      type: "result",
    });
    // On the wire the row is a failed one: the Notch draws no progress beside it.
    expect(fixture.lastShown()).toEqual({
      items: [
        expect.objectContaining({
          id,
          status: "failed",
          subtitle: "Send failed, click to try again",
          title: "Plan the review",
        }),
      ],
      notify: undefined,
    });
    // The row says so in Main's language.
    fixture.setLocale("zh-CN");
    fixture.service.localeChanged();
    await expect(host.nextCommand()).resolves.toMatchObject({ type: "configure" });
    expect(fixture.lastShown()?.items[0]?.subtitle).toBe("发送失败，点击重试");
    fixture.setLocale("en");
    fixture.service.localeChanged();
    await expect(host.nextCommand()).resolves.toMatchObject({ type: "configure" });

    // A click sends the same request, with the same words; the row is under way again, and
    // nothing opens. The helper was answered once and hears no more of it.
    const again = deferred<QuickChatMessage>();
    fixture.sendMessage.mockReturnValueOnce(again.promise);
    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(2);
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    expect(fixture.openRoute).not.toHaveBeenCalled();
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, status: "in_progress", subtitle: "Sending…" }),
    ]);
    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(2);

    again.resolve({
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-1",
      workspace_id: "workspace-1",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({
        id: `quick-chat:${requestId}`,
        title: "Plan the review",
        status: "sent",
      }),
    ]);
    expect(host.queuedCommands()).toEqual([]);
    fixture.service.close();
  });

  it("does not send words too long to send, or again what the server refused; a click takes the row out", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);
    const tooLong = `quick-chat:${nthRequest(1)}`;
    const noCredits = `quick-chat:${nthRequest(2)}`;
    const invalid = `quick-chat:${nthRequest(3)}`;
    const row = (id: string) =>
      fixture.lastShown()?.items.find((item) => item.id === id);

    // 5,334 three-byte characters: 16,002 bytes, past the server's 16,000.
    host.emitEvent({
      requestId: nthRequest(1),
      text: "好".repeat(5_334),
      type: "submit",
    });
    await expect(host.nextCommand()).resolves.toEqual({
      message: "The words are too long to send.",
      ok: false,
      requestId: nthRequest(1),
      type: "result",
    });
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    expect(row(tooLong)).toMatchObject({ subtitle: "Too long to send" });

    fixture.sendMessage
      .mockRejectedValueOnce(
        Object.assign(new Error("budget_exhausted"), { status: 402 })
      )
      .mockRejectedValueOnce(
        Object.assign(new Error("Invalid request"), { status: 400 })
      );
    host.emitEvent({ requestId: nthRequest(2), text: "Book the room", type: "submit" });
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: false });
    host.emitEvent({ requestId: nthRequest(3), text: "Remind me", type: "submit" });
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: false });
    expect(row(noCredits)).toMatchObject({
      subtitle: "Out of Comma credits, not sent",
    });
    expect(row(invalid)).toMatchObject({ subtitle: "Couldn’t send" });

    for (const id of [tooLong, noCredits, invalid]) click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(2);
    expect(fixture.openRoute).not.toHaveBeenCalled();
    expect(fixture.lastShown()).toEqual({ items: [], notify: undefined });
    fixture.service.close();
  });

  it("dismisses a refused message without changing its id or resending its words", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);
    const id = `quick-chat:${requestId}`;
    fixture.sendMessage.mockRejectedValueOnce(
      Object.assign(new Error("not_found"), { status: 404 })
    );
    host.emitEvent({ requestId, text: "Plan the review", type: "submit" });
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: false, requestId });
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, status: "failed", subtitle: "Couldn’t send" }),
    ]);
    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(1);
    expect(fixture.lastShown()?.items).toEqual([]);
    fixture.service.close();
  });

  it("sends and retries in the workspace in focus when the words were sent, not one chosen after", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);
    fixture.publishList(list([]));
    const id = `quick-chat:${requestId}`;
    fixture.sendMessage.mockRejectedValueOnce(new Error("network unavailable"));
    host.emitEvent({ requestId, text: "Plan the review", type: "submit" });
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: false, requestId });

    // Another workspace comes into focus; the failed send stays, and a click sends it where it was sent.
    fixture.publishList({
      ...list([]),
      activeWorkspaceId: "workspace-2",
      workspaces: [{ group_id: "group-2", id: "workspace-2", name: "Bo" }],
    });
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, status: "failed" }),
    ]);
    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("holds a send made before the list loads until it names the workspace, and retries there", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture, { list: false });
    const id = `quick-chat:${requestId}`;
    fixture.sendMessage.mockRejectedValueOnce(new Error("network unavailable"));
    host.emitEvent({ requestId, text: "Plan the review", type: "submit" });
    // No list yet: the row shows, and nothing is sent to a workspace the core would pick later.
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, status: "in_progress" }),
    ]);
    expect(fixture.sendMessage).not.toHaveBeenCalled();

    fixture.publishList(list([]));
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: false, requestId });

    fixture.publishList({
      ...list([]),
      activeWorkspaceId: "workspace-2",
      workspaces: [{ group_id: "group-2", id: "workspace-2", name: "Bo" }],
    });
    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("fails a send as retryable when no list names a workspace within 30 s", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture, { list: false });
    const id = `quick-chat:${requestId}`;
    host.emitEvent({ requestId, text: "Plan the review", type: "submit" });
    await vi.advanceTimersByTimeAsync(30_000);
    await expect(host.nextCommand()).resolves.toMatchObject({
      message: "Quick Chat has no workspace yet.",
      ok: false,
      requestId,
    });
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, status: "failed" }),
    ]);
    // The list comes later; a click sends the words there.
    fixture.publishList(list([]));
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: requestId,
      text: "Plan the review",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("keeps the preparing workspace through clip completion, a focus change and a failed retry", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);
    fixture.publishList(list([]));
    const id = `quick-chat:${requestId}`;
    fixture.sendMessage.mockRejectedValueOnce(new Error("network unavailable"));
    host.emitEvent({ requestId, text: "Plan the review", type: "preparing" });
    expect(fixture.sendMessage).not.toHaveBeenCalled();

    fixture.publishList({
      ...list([]),
      activeWorkspaceId: "workspace-2",
      workspaces: [{ group_id: "group-2", id: "workspace-2", name: "Bo" }],
    });
    host.emitEvent({
      requestId,
      text: "Plan the review tomorrow",
      type: "preparing",
      update: true,
    });
    host.emitEvent({
      prepared: true,
      requestId,
      text: "Plan the review tomorrow",
      type: "submit",
    });
    expect(fixture.sendMessage).toHaveBeenCalledExactlyOnceWith({
      client_request_id: requestId,
      text: "Plan the review tomorrow",
      workspace: "workspace-1",
    });
    await expect(host.nextCommand()).resolves.toMatchObject({ ok: false, requestId });
    expect(fixture.lastShown()?.items).toEqual([
      expect.objectContaining({ id, status: "failed", workspaceId: "workspace-1" }),
    ]);

    click(fixture, id);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(2);
    expect(fixture.sendMessage).toHaveBeenLastCalledWith({
      client_request_id: requestId,
      text: "Plan the review tomorrow",
      workspace: "workspace-1",
    });
    fixture.service.close();
  });

  it("runs no helper while Settings turns Quick Chat off, and starts one when it is on again", async () => {
    const onAvailableChanged = vi.fn();
    const fixture = createFixture({ enabled: false, onAvailableChanged });
    expect(fixture.service.supported).toBe(true);
    fixture.service.sessionChanged(signedIn(1));
    expect(fixture.hosts).toHaveLength(0);
    expect(fixture.service.listen()).toBe(false);

    fixture.service.setEnabled(true);
    expect(fixture.hosts).toHaveLength(1);
    const host = fixture.hosts[0]!;
    host.emitEvent({ type: "ready" });
    await expect(host.nextCommand()).resolves.toMatchObject({ type: "configure" });
    expect(onAvailableChanged).toHaveBeenLastCalledWith(true);
    host.emitEvent({ requestId, text: "Plan the review", type: "submit" });
    expect(fixture.lastShown()?.items).toHaveLength(1);

    // Off: the helper quits on stdin EOF, its delivery rows leave the Notch, and it is not restarted.
    fixture.service.setEnabled(false);
    expect(host.stdin.writableEnded).toBe(true);
    expect(onAvailableChanged).toHaveBeenLastCalledWith(false);
    expect(fixture.lastShown()).toEqual({ items: [], notify: undefined });
    host.emit("exit", 0, null);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(fixture.hosts).toHaveLength(1);
    // A new session while off starts nothing either.
    fixture.service.sessionChanged(signedIn(2));
    expect(fixture.hosts).toHaveLength(1);
    fixture.service.close();
  });

  it("keeps the newest five failed sends, and the newest twenty sent messages", async () => {
    let clock = 1_787_563_260_000;
    const fixture = createFixture({
      clock: { ...realMainClock, now: () => (clock += 1_000) },
    });
    const host = await readyHost(fixture);
    const titles = () => fixture.lastShown()?.items.map((item) => item.title);

    fixture.sendMessage.mockRejectedValue(new Error("offline"));
    for (let n = 1; n <= 6; n += 1) {
      host.emitEvent({ requestId: nthRequest(n), text: `Send ${n}`, type: "submit" });
      await vi.advanceTimersByTimeAsync(0);
    }
    expect(titles()).toEqual(["Send 2", "Send 3", "Send 4", "Send 5", "Send 6"]);

    fixture.sendMessage.mockImplementation(async ({ client_request_id }) => ({
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: `message-${client_request_id}`,
      workspace_id: "workspace-1",
    }));
    for (let n = 7; n <= 27; n += 1) {
      host.emitEvent({ requestId: nthRequest(n), text: `Task ${n}`, type: "submit" });
      await vi.advanceTimersByTimeAsync(0);
    }
    const shown = titles()!;
    expect(shown).toHaveLength(25);
    expect(shown.filter((title) => title.startsWith("Task "))).toHaveLength(20);
    expect(shown).not.toContain("Task 7");
    expect(shown).toContain("Task 27");
    fixture.service.close();
  });

  it("preserves Return order across transcript completion and waits for each message acknowledgement", async () => {
    const fixture = createFixture();
    const first = deferred<QuickChatMessage>();
    const second = deferred<QuickChatMessage>();
    fixture.sendMessage
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const host = await readyHost(fixture);
    const next = nthRequest(2);
    host.emitEvent({ requestId, text: "First local words", type: "preparing" });
    host.emitEvent({ requestId: next, text: "Then these words", type: "preparing" });
    host.emitEvent({
      requestId: next,
      text: "Then these words",
      type: "submit",
      prepared: true,
    });
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    host.emitEvent({
      requestId,
      text: "First corrected words",
      type: "submit",
      prepared: true,
    });
    expect(fixture.sendMessage).toHaveBeenCalledExactlyOnceWith({
      client_request_id: requestId,
      text: "First corrected words",
      workspace: "workspace-1",
    });
    first.resolve({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-1",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(
      fixture.sendMessage.mock.calls.map(([params]) => params.client_request_id)
    ).toEqual([requestId, next]);
    second.resolve({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-2",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(
      fixture.lastShown()?.items.map(({ id, status }) => ({ id, status }))
    ).toEqual([
      { id: `quick-chat:${requestId}`, status: "sent" },
      { id: `quick-chat:${next}`, status: "sent" },
    ]);
    fixture.service.close();
  });

  it("places an explicit retry after messages already queued, preserving its original identity and words", async () => {
    const fixture = createFixture();
    const first = deferred<QuickChatMessage>();
    const second = deferred<QuickChatMessage>();
    const third = deferred<QuickChatMessage>();
    fixture.sendMessage
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise)
      .mockReturnValueOnce(third.promise);
    const host = await readyHost(fixture);
    const next = nthRequest(2);
    const queued = nthRequest(3);
    host.emitEvent({ requestId, text: "First words", type: "submit" });
    host.emitEvent({ requestId: next, text: "Later words", type: "submit" });
    expect(fixture.sendMessage).toHaveBeenCalledTimes(1);
    first.reject(new Error("answer lost"));
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(2);
    host.emitEvent({ requestId: queued, text: "Already queued words", type: "submit" });
    click(fixture, `quick-chat:${requestId}`);
    expect(fixture.sendMessage).toHaveBeenCalledTimes(2);
    second.resolve({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-2",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(
      fixture.sendMessage.mock.calls.map(([params]) => params.client_request_id)
    ).toEqual([requestId, next, queued]);
    third.resolve({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "message-3",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.sendMessage.mock.calls.map(([params]) => params)).toEqual([
      { client_request_id: requestId, text: "First words", workspace: "workspace-1" },
      { client_request_id: next, text: "Later words", workspace: "workspace-1" },
      {
        client_request_id: queued,
        text: "Already queued words",
        workspace: "workspace-1",
      },
      { client_request_id: requestId, text: "First words", workspace: "workspace-1" },
    ]);
    fixture.service.close();
  });

  it("listens when the menu-bar item is clicked, while the helper is ready", async () => {
    const onAvailableChanged = vi.fn();
    const fixture = createFixture({ onAvailableChanged });
    expect(fixture.service.listen()).toBe(false);

    const host = await readyHost(fixture);
    expect(onAvailableChanged).toHaveBeenLastCalledWith(true);
    expect(fixture.service.listen()).toBe(true);
    expect(await host.nextCommand()).toEqual({ type: "listen" });

    // A helper that is gone, until the next one is ready, starts nothing.
    host.emit("exit", 1, null);
    expect(onAvailableChanged).toHaveBeenLastCalledWith(false);
    expect(fixture.service.listen()).toBe(false);
    expect(onAvailableChanged).toHaveBeenCalledTimes(2);
  });

  it("stops the helper and clears its delivery rows when the session ends", async () => {
    const onAvailableChanged = vi.fn();
    const fixture = createFixture({ onAvailableChanged });
    const host = await readyHost(fixture);
    host.emitEvent({ requestId, text: "Plan the review", type: "preparing" });
    expect(fixture.lastShown()?.items).toHaveLength(1);

    fixture.service.sessionChanged(signedOut(2));

    // stdin EOF is how QuickChatHost quits.
    expect(host.stdin.writableEnded).toBe(true);
    // A click on the menu-bar item opens its menu again.
    expect(onAvailableChanged).toHaveBeenLastCalledWith(false);
    expect(fixture.service.listen()).toBe(false);
    expect(fixture.unsubscribeTasks).toHaveBeenCalledOnce();
    expect(fixture.lastShown()).toEqual({ items: [], notify: undefined });
    // The helper ending now is not a crash to recover from.
    host.emit("exit", 0, null);
    host.emitEvent({
      prepared: true,
      requestId,
      text: "Plan the review",
      type: "submit",
    });
    await vi.advanceTimersByTimeAsync(30_000);
    expect(fixture.sendMessage).not.toHaveBeenCalled();
    expect(fixture.lastShown()).toEqual({ items: [], notify: undefined });
    expect(fixture.hosts).toHaveLength(1);
  });

  it("drops queued messages at session end and ignores an old acknowledgement", async () => {
    const fixture = createFixture();
    const old = deferred<QuickChatMessage>();
    fixture.sendMessage.mockReturnValueOnce(old.promise);
    const host = await readyHost(fixture);
    host.emitEvent({ requestId, text: "Old first", type: "submit" });
    host.emitEvent({ requestId: nthRequest(2), text: "Old queued", type: "submit" });
    fixture.service.sessionChanged(signedOut(2));
    fixture.service.sessionChanged(signedIn(3));
    const current = fixture.hosts.at(-1)!;
    current.emitEvent({ type: "ready" });
    await current.nextCommand();
    fixture.publishList(list([]));
    current.emitEvent({
      requestId: nthRequest(3),
      text: "Current first",
      type: "submit",
    });
    current.emitEvent({
      requestId: nthRequest(4),
      text: "Current queued",
      type: "submit",
    });
    old.resolve({
      workspace_id: "workspace-1",
      group_id: "group-1",
      conversation_id: "home-1",
      message_id: "old-message",
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.sendMessage.mock.calls.map(([params]) => params.text)).toEqual([
      "Old first",
      "Current first",
    ]);
    expect(fixture.lastShown()?.items.map((item) => item.title)).toEqual([
      "Current first",
      "Current queued",
    ]);
    expect(current.queuedCommands()).toEqual([]);
    fixture.service.close();
  });

  it("starts a new helper after one exits on its own", async () => {
    const fixture = createFixture();
    const host = await readyHost(fixture);

    host.emit("exit", 1, null);
    expect(fixture.hosts).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(fixture.hosts).toHaveLength(2);
    fixture.service.close();
  });

  it("sends the helper's text again when Main's language changes", async () => {
    // System Settings lists the release's own app, such as Comma Staging.
    const fixture = createFixture({ productName: "Comma Staging" });
    const host = await readyHost(fixture);

    fixture.setLocale("zh-CN");
    fixture.service.localeChanged();

    await expect(host.nextCommand()).resolves.toEqual({
      strings: {
        close: "关闭",
        listening: "正在聆听…",
        microphoneDenied: "请在“系统设置”中允许 Comma Staging 使用麦克风。",
        preparing: "正在准备语音识别…",
        resume: "按 ⌘ 继续",
        send: "发送",
        sendFailed: "发送失败，请在刘海处重试。",
        speechUnavailable: "语音识别不可用。",
      },
      type: "configure",
    });
    fixture.service.close();
  });
});

class FakeQuickChatHost extends EventEmitter {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  exitCode: number | null = null;
  killed = false;
  signalCode: NodeJS.Signals | null = null;
  readonly #commands: unknown[] = [];
  readonly #waiting: Array<(command: unknown) => void> = [];
  #buffer = "";

  constructor() {
    super();
    this.stdin.on("data", (chunk) => {
      this.#buffer += chunk.toString();
      for (;;) {
        const newline = this.#buffer.indexOf("\n");
        if (newline < 0) return;
        const command: unknown = JSON.parse(this.#buffer.slice(0, newline));
        this.#buffer = this.#buffer.slice(newline + 1);
        const waiting = this.#waiting.shift();
        if (waiting) waiting(command);
        else this.#commands.push(command);
      }
    });
  }

  /** Writes one line as QuickChatHost does; Main reads it synchronously. */
  emitEvent(event: unknown) {
    this.stdout.emit("data", Buffer.from(`${JSON.stringify(event)}\n`));
  }

  nextCommand(): Promise<unknown> {
    const command = this.#commands.shift();
    if (command !== undefined) return Promise.resolve(command);
    return new Promise((resolve) => this.#waiting.push(resolve));
  }

  /** The commands written and not yet read. */
  queuedCommands(): unknown[] {
    return [...this.#commands];
  }

  kill() {
    this.killed = true;
    return true;
  }
}
