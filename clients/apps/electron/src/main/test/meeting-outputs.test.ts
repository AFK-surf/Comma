import { describe, expect, it, vi } from "vitest";
import type { AudioCaptureRecording } from "@comma/native-bridge";
import type { CommaApiClient, SalixMessage } from "@comma/app/api";
import type { MainSessionBoundApi } from "../modules/session/main-session-transport";
import {
  archiveMeetingOutputFiles,
  MeetingOutputArchive,
  type MeetingOutputJob,
} from "../modules/meeting-recorder/outputs";

const job = (id = "meeting"): MeetingOutputJob => ({
  id,
  account: "alice",
  groupId: "group",
  taskId: id,
  completed: [],
  recording: {
    file: { name: "meeting.m4a", size: 100, mediaType: "audio/mp4" },
    driveFile: { space: "drive", path: "recording/2026-09-09/meeting.m4a" },
    channels: 1,
    sampleRate: 16000,
    durationMs: 1000,
  } satisfies AudioCaptureRecording,
});
const message = (extensions = ["transcript.txt", "transcript.json", "summary.md"]) =>
  ({
    kind: "message",
    actor_type: "agent",
    message_id: "result",
    content: extensions.map((ext) => ({
      type: "file",
      path: `/artifacts/meeting.${ext}`,
    })),
  }) as SalixMessage;
function harness() {
  let account = "alice";
  const streams: AbortSignal[] = [];
  const api = {
    getConversation: vi.fn(async () => ({
      status: "active",
      messages: [] as SalixMessage[],
    })),
    fetchConversationAttachment: vi.fn(async () => new Blob(["artifact"])),
    streamConversationListEvents: vi.fn(async (_group, opts) => {
      streams.push(opts.signal);
      if (!opts.signal.aborted)
        await new Promise<void>((resolve) =>
          opts.signal.addEventListener("abort", () => resolve(), { once: true })
        );
    }),
  };
  const deps = {
    account: () => account,
    runOwned: async <T>(f: () => Promise<T>) => f(),
    bindSession: () =>
      ({
        api,
        assertCurrent: () => {
          if (account !== "alice") throw Error("Account replaced");
        },
      }) as unknown as MainSessionBoundApi,
    write: vi.fn<ConstructorParameters<typeof MeetingOutputArchive>[0]["write"]>(
      async () => ({ status: "done" as const })
    ),
    checkpoint: vi.fn(async () => {}),
    publish: vi.fn(),
  };
  const archive = new MeetingOutputArchive(deps);
  return {
    api,
    deps,
    archive,
    streams,
    replaceAccount: () => {
      account = "bob";
      archive.reconcileAccount();
    },
  };
}
describe("meeting output archive", () => {
  it("does not report archive failure when a closing stream races completed writes", async () => {
    const h = harness();
    h.api.getConversation.mockResolvedValue({
      status: "active",
      messages: [message()],
    });
    const download = Promise.withResolvers<Blob>();
    h.api.fetchConversationAttachment.mockImplementation(() => download.promise);
    h.api.streamConversationListEvents.mockRejectedValue(Error("Stream disconnected"));
    try {
      h.archive.watch(job());
      await vi.waitFor(() =>
        expect(h.api.fetchConversationAttachment).toHaveBeenCalledOnce()
      );
      download.resolve(new Blob(["output"]));
      await vi.waitFor(() =>
        expect(h.deps.publish).toHaveBeenCalledWith(expect.anything(), "done")
      );
      expect(h.deps.publish).toHaveBeenCalledOnce();
    } finally {
      h.archive.close();
    }
  });
  it("downloads only canonical agent attachments and retries only files not saved", async () => {
    const j = job();
    const api = {
      fetchConversationAttachment: vi.fn<CommaApiClient["fetchConversationAttachment"]>(
        async () => new Blob(["output"])
      ),
    };
    const write = vi.fn(async (ext: (typeof j.completed)[number]) => {
      if (ext === "transcript.json") throw Error("Drive unavailable");
      j.completed.push(ext);
    });
    const messages = [
      { ...message(), actor_type: "user" },
      message(["wrong.md", "transcript.txt", "transcript.json", "summary.md"]),
    ] as SalixMessage[];
    await expect(archiveMeetingOutputFiles(api, j, messages, write)).rejects.toThrow(
      "Drive unavailable"
    );
    expect(j.completed).toEqual(["transcript.txt"]);
    expect(
      api.fetchConversationAttachment.mock.calls.map((c) => c.slice(0, 4))
    ).toEqual([
      ["group", "meeting", "result", 1],
      ["group", "meeting", "result", 2],
    ]);
    api.fetchConversationAttachment.mockClear();
    await archiveMeetingOutputFiles(api, j, messages, async (ext) => {
      j.completed.push(ext);
    });
    expect(api.fetchConversationAttachment.mock.calls.map((c) => c[3])).toEqual([2, 3]);
    expect(j.completed).toEqual(["transcript.txt", "transcript.json", "summary.md"]);
  });
  it("writes exact saved-audio paths and publishes success only after all checkpoints", async () => {
    const h = harness();
    h.api.getConversation.mockResolvedValue({
      status: "ready_for_review",
      messages: [message()],
    });
    try {
      h.archive.watch(job());
      await vi.waitFor(() =>
        expect(h.deps.publish).toHaveBeenCalledWith(expect.anything(), "done")
      );
      expect(h.deps.write.mock.calls.map((c) => c[0].path)).toEqual([
        "recording/2026-09-09/meeting.transcript.txt",
        "recording/2026-09-09/meeting.transcript.json",
        "recording/2026-09-09/meeting.summary.md",
      ]);
      expect(h.deps.checkpoint).toHaveBeenCalledTimes(3);
    } finally {
      h.archive.close();
    }
  });
  it("holds at most two streams and aborts them without writing after account replacement", async () => {
    const h = harness();
    const pending = Promise.withResolvers<Blob>();
    h.api.getConversation.mockResolvedValue({
      status: "active",
      messages: [message()],
    });
    h.api.fetchConversationAttachment.mockImplementation(() => pending.promise);
    try {
      for (let i = 0; i < 4; i++) h.archive.watch(job(`${i}`));
      await vi.waitFor(() => expect(h.streams).toHaveLength(2));
      expect(h.api.getConversation).toHaveBeenCalledTimes(2);
      h.replaceAccount();
      pending.resolve(new Blob(["previous account bytes"]));
      await vi.waitFor(() => expect(h.streams.every((s) => s.aborted)).toBe(true));
      await new Promise((resolve) => setImmediate(resolve));
      expect(h.deps.write).not.toHaveBeenCalled();
      expect(h.deps.publish).not.toHaveBeenCalled();
      expect(h.streams).toHaveLength(2);
    } finally {
      h.archive.close();
    }
  });
  it("keeps a failed Drive write retryable without claiming archive success", async () => {
    const h = harness();
    h.api.getConversation.mockResolvedValue({
      status: "ready_for_review",
      messages: [message()],
    });
    h.api.streamConversationListEvents.mockImplementation(async () => {
      await new Promise((resolve) => setImmediate(resolve));
    });
    h.deps.write.mockRejectedValueOnce(Error("Drive unavailable"));
    try {
      const j = job();
      h.archive.watch(j);
      await vi.waitFor(() =>
        expect(h.deps.publish).toHaveBeenCalledWith(j, "error", expect.any(Error))
      );
      expect(j.completed).toEqual([]);
      h.archive.watch(j);
      await vi.waitFor(() => expect(h.deps.publish).toHaveBeenCalledWith(j, "done"));
      expect(j.completed).toHaveLength(3);
    } finally {
      h.archive.close();
    }
  });
});
