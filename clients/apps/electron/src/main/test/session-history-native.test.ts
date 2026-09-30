import { expect, it, vi } from "vitest";
import { SessionHistoryRuntime } from "@comma/session-history-runtime";
import {
  sessionHistoryRetainCapability,
  sessionHistoryReleaseCapability,
  sessionHistoryLoadCapability,
} from "@comma/native-bridge";
import { IpcGateway, type NativeCallerContext } from "../modules/ipc";
import { createCallerBoundSessionHistoryProvider } from "../modules/native";

it("generated history commands retain the same runtime independently for two native callers", async () => {
  const session = {
    audience: "https://api.comma.test",
    sessionId: "session",
    authorityInstanceId: "main",
    generation: 1,
  };
  const signal = new AbortController().signal;
  const runtime = new SessionHistoryRuntime({
    authority: {
      acquireProductCredential: () => ({
        audience: session.audience,
        signal,
        token: "main-secret",
      }),
      isCurrentProductCredential: (credential) => credential.signal === signal,
    },
    fetch: vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            conversation_id: "c",
            participant_id: "p",
            records: [{ id: "1", kind: "assistant", content: "one" }],
            has_more: false,
            next_before: null,
          })
        )
    ),
  });
  const provider = createCallerBoundSessionHistoryProvider(runtime);
  const handlers = new Map<
    string,
    (event: unknown, input: unknown) => Promise<unknown>
  >();
  const gateway = new IpcGateway({
    ipcMain: {
      handle: (channel, handler) => {
        handlers.set(channel, handler);
      },
    },
    resolveCallerContext: (event) => event as NativeCallerContext,
    senderPolicy: { allow: () => true },
  });
  gateway.register(sessionHistoryRetainCapability.contract, provider.retain);
  gateway.register(sessionHistoryReleaseCapability.contract, provider.release);
  gateway.register(sessionHistoryLoadCapability.contract, provider.load);
  const target = { session, groupId: "g", conversationId: "c", participantId: "p" };
  const demand = { ...target, consumerId: "same-react-id" };
  const retain = handlers.get(sessionHistoryRetainCapability.contract.channel)!;
  const release = handlers.get(sessionHistoryReleaseCapability.contract.channel)!;
  const load = handlers.get(sessionHistoryLoadCapability.contract.channel)!;
  try {
    expect(await retain(caller("a"), demand)).toMatchObject({ ok: true });
    expect(await retain(caller("b"), demand)).toMatchObject({ ok: true });
    expect(await load(caller("a"), { ...target, mode: "latest" })).toMatchObject({
      ok: true,
    });
    expect(await release(caller("a"), demand)).toEqual({ ok: true, value: true });
    expect(runtime.state(target).snapshot.records).toHaveLength(1);
    expect(await release(caller("b"), demand)).toEqual({ ok: true, value: true });
    expect(runtime.state(target).snapshot.records).toHaveLength(0);
  } finally {
    runtime.close();
  }
});

const caller = (windowId: string) => ({
  windowId,
  webContentsId: windowId === "a" ? 1 : 2,
  role: "main-window",
  origin: "assets://.",
});
