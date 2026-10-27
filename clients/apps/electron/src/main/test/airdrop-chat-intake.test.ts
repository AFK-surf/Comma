import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ChatRuntimeSnapshot, ConversationProjection } from "@comma/chat-contract";
import { CoreClient } from "@comma/core-kernel/client";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "@comma/core/testing";
import { MainChat } from "../modules/chat";
import { approveAirDropForChat } from "../modules/airdrop/chat-intake";
import type { AirDropOffer } from "../modules/airdrop";

const clients: CoreClient[] = [];
const roots: string[] = [];
afterEach(async () => {
  for (const client of clients.splice(0)) client.close();
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { force: true, recursive: true }))
  );
});
/** The helper's directory for one transfer, with what it saved there. */
async function receivedDirectory() {
  const root = await mkdtemp(join(tmpdir(), "comma-airdrop-received-"));
  roots.push(root);
  return root;
}
async function receivedFile(name = "report.pdf") {
  const path = join(await receivedDirectory(), name);
  await writeFile(path, "received bytes");
  return path;
}
const offer: AirDropOffer = {
  version: 1,
  type: "approval_requested",
  requestId: "11111111-1111-4111-8111-111111111111",
  senderName: "iPhone",
  files: [{ name: "report.pdf", isDirectory: false }],
  linkCount: 0,
};
/** The chat the window shows, as the server gives it. */
const conversation = (id: string) => ({
  id,
  group_id: "grp_1",
  kind: "user_chat",
  status: "active",
  title: "Current chat",
  messages: [],
});

/** A client core on a fake Comma API (the real clock), Main's chat on it, and a window that retains a chat. */
function harness({ view = false }: { view?: boolean } = {}) {
  const host = new FakeHost({ time: null });
  host.api.on("GET", "/v1/comma/groups/grp_1/conversations/*", (request) =>
    json(200, conversation(request.path.split("/").at(-1)!.split("?")[0]!))
  );
  host.api.onStream("/v1/comma/groups/grp_1/conversations/cnv_1/events");
  host.api.onStream("/v1/comma/groups/grp_1/conversations/cnv_2/events");
  const sent = Promise.withResolvers<void>();
  const sendMessage = vi.fn((_request: { body: unknown }) => {
    sent.resolve();
    return json(200, conversation("cnv_1"));
  });
  host.api.on(
    "POST",
    "/v1/comma/groups/grp_1/conversations/cnv_1/messages",
    sendMessage
  );
  const core = startTestCore(host);
  core.observeSession(signedIn());
  const client = new CoreClient(inProcessOpener(core, host));
  clients.push(client);
  const call = (name: string, params: unknown) => client.call(name, params);
  const main = new MainChat(() => client);
  const target = {
    workspaceId: "wsp_1",
    groupId: "grp_1",
    conversationId: "cnv_1",
    subscriberId: "main:grp_1/cnv_1",
    leaseId: "00000000-0000-4000-8000-000000000001",
  };
  /** The window's view of cnv_1 (`view`), as its calls name it; otherwise the window retains cnv_1 under `target`. */
  const named = {
    workspace: "wsp_1",
    group: "grp_1",
    conversation: "cnv_1",
    surface: "main",
  };
  const act = (name: string, params: Record<string, unknown>) =>
    call(`chatView.${name}`, { ...named, ...params });
  const retained = view
    ? new Promise<void>((resolve, reject) => {
        // The view's first value: the conversation is retained for the window.
        client.subscribe(
          { topic: "chatView", ...named },
          (value) => {
            if ((value as { state: unknown }).state) resolve();
          },
          reject
        );
      })
    : call("chat.retain", target);
  const file = {
    localFileRef: `lfi1_${"a".repeat(43)}`,
    name: "report.pdf",
    size: 12,
    mediaType: "application/pdf",
  };
  const picker = {
    importForChat: vi.fn(
      async (
        _paths: readonly string[],
        input: { assertLocalFileRegistrationAllowed: () => void }
      ) => {
        input.assertLocalFileRegistrationAllowed();
        return {
          cancelled: false,
          errors: [],
          items: [{ kind: "local_file" as const, file }],
        };
      }
    ),
  };
  const controller = new AbortController();
  const reception = {
    complete: vi.fn(async (_requestId: string, _unattachedCount: number) => undefined),
    confirm: vi.fn(async (_offer: unknown, _signal: AbortSignal) => true),
    fail: vi.fn(),
    progress: vi.fn(),
    received: vi.fn(),
    refuse: vi.fn(),
  };
  /** `conversationId`'s state in the first chat snapshot Main is sent where `ready` holds of it. */
  const sessionWhen = (
    ready: (state: ConversationProjection | undefined) => boolean,
    conversationId = "cnv_1"
  ) =>
    new Promise<ConversationProjection | undefined>((resolve, reject) => {
      const stop = client.subscribe(
        { topic: "chat" },
        (value) => {
          const state = (
            value as { snapshot: ChatRuntimeSnapshot }
          ).snapshot.sessions.find((s) => s.conversationId === conversationId)?.state;
          if (!ready(state)) return;
          resolve(state);
          queueMicrotask(stop);
        },
        reject
      );
    });
  const session = (conversationId = "cnv_1") => sessionWhen(() => true, conversationId);
  return {
    core,
    act,
    call,
    retained,
    session,
    sessionWhen,
    target,
    picker,
    controller,
    reception,
    sendMessage,
    sent: sent.promise,
    options: {
      offer,
      signal: controller.signal,
      surfaceId: "main",
      chat: main,
      picker,
      reception,
    },
  };
}
describe("AirDrop to chat attachments", () => {
  it("adds received files to the existing draft and waits for the user to send", async () => {
    const h = harness({ view: true });
    await h.retained;
    await h.act("setDraft", { draft: "Review this" });
    await h.sessionWhen((state) => state?.conversation?.title === "Current chat");
    const intake = await approveAirDropForChat(h.options);
    expect(h.reception.confirm).toHaveBeenCalledWith(
      expect.objectContaining({ chatTitle: "Comma", senderName: "iPhone" }),
      h.controller.signal
    );
    expect((await h.session())?.attachmentIntakeInFlight).toBe(true);
    expect(h.picker.importForChat).not.toHaveBeenCalled();
    intake!.progress({ fraction: 0.5, totalBytes: 24, transferredBytes: 12 });
    expect(h.reception.progress).toHaveBeenCalledWith(offer.requestId, {
      fraction: 0.5,
      totalBytes: 24,
      transferredBytes: 12,
    });
    await intake!.complete([await receivedFile()]);
    expect(
      await h.sessionWhen((state) => state?.draftAttachments.length === 1)
    ).toMatchObject({
      draft: "Review this",
      draftAttachments: [{ name: "report.pdf", status: "uploaded" }],
    });
    expect(h.reception.complete).toHaveBeenCalledWith(offer.requestId, 0);
    expect(h.sendMessage).not.toHaveBeenCalled();
    await h.act("send", { text: "Review this" });
    await h.sent;
    expect(h.sendMessage).toHaveBeenCalledOnce();
    expect(h.sendMessage.mock.calls[0]![0]).toMatchObject({
      body: {
        message: {
          content: [
            { type: "text", text: "Review this" },
            expect.objectContaining({ type: "local_file", display_name: "report.pdf" }),
          ],
        },
      },
    });
  });
  it("declining preserves the draft and leaves no pending attachment intake", async () => {
    const h = harness({ view: true });
    h.reception.confirm.mockResolvedValue(false);
    await h.retained;
    await h.act("setDraft", { draft: "Keep me" });
    expect(await approveAirDropForChat(h.options)).toBeUndefined();
    expect(
      await h.sessionWhen(
        (state) => state !== undefined && state.attachmentIntakeInFlight !== true
      )
    ).toMatchObject({ draft: "Keep me", draftAttachments: [] });
    expect(h.picker.importForChat).not.toHaveBeenCalled();
  });
  it("keeps files local if the user switches chats before upload finishes", async () => {
    const h = harness();
    await h.retained;
    const intake = await approveAirDropForChat(h.options);
    await h.call("chat.release", h.target);
    await h.call("chat.retain", {
      ...h.target,
      conversationId: "cnv_2",
      subscriberId: "main:grp_1/cnv_2",
      leaseId: "00000000-0000-4000-8000-000000000002",
    });
    const path = await receivedFile();
    await expect(intake!.complete([path])).rejects.toThrow("changed");
    expect(h.picker.importForChat).not.toHaveBeenCalled();
    expect((await h.session("cnv_2"))?.draftAttachments).toEqual([]);
    expect(h.reception.received).toHaveBeenCalledWith(offer.requestId, [path]);
    expect(h.reception.fail).toHaveBeenCalledWith(offer.requestId, "attach");
  });
  it("attaches a package's files, drops the bundle it emptied, and keeps a full one for Finder", async () => {
    const h = harness();
    await h.retained;
    await h.sessionWhen((state) => state?.conversation?.title === "Current chat");
    const intake = await approveAirDropForChat(h.options);
    const root = await receivedDirectory();
    // A Live Photo: the helper published the still beside its .pvt bundle.
    const still = join(root, "IMG_1999.HEIC");
    await writeFile(still, "heic bytes");
    const bundle = join(root, "IMG_1999.pvt");
    await mkdir(bundle);
    // A package whose contents stayed inside it: nothing here can attach.
    const deck = join(root, "Pitch.key");
    await mkdir(deck);
    await writeFile(join(deck, "Index.zip"), "keynote bytes");

    await intake!.complete([still, bundle, deck]);

    expect(h.picker.importForChat).toHaveBeenCalledWith([still], expect.anything());
    expect(h.reception.received).toHaveBeenCalledWith(offer.requestId, [still, deck]);
    expect(h.reception.complete).toHaveBeenCalledWith(offer.requestId, 1);
  });

  it("requires a single live destination and refuses folder attachments", async () => {
    const h = harness();
    await h.retained;
    await h.call("chat.release", h.target);
    expect(await approveAirDropForChat(h.options)).toBeUndefined();
    expect(h.reception.refuse).toHaveBeenCalledWith(
      expect.not.objectContaining({ chatTitle: expect.any(String) }),
      "no_chat"
    );
    await h.call("chat.retain", {
      ...h.target,
      leaseId: "00000000-0000-4000-8000-000000000002",
    });
    await h.sessionWhen((state) => state?.conversation?.title === "Current chat");
    expect(
      await approveAirDropForChat({
        ...h.options,
        offer: { ...offer, files: [{ name: "Folder", isDirectory: true }] },
      })
    ).toBeUndefined();
    expect(h.reception.refuse).toHaveBeenLastCalledWith(
      expect.objectContaining({ chatTitle: "Comma" }),
      "directory"
    );
    expect(h.reception.confirm).not.toHaveBeenCalled();
    expect(h.picker.importForChat).not.toHaveBeenCalled();
  });
  it("recomputes remaining attachment quotas when transfer completes", async () => {
    const h = harness();
    await h.retained;
    const intake = await approveAirDropForChat(h.options);
    await h.call("chat.attachLocalFiles", {
      ...h.target,
      surfaceId: "main",
      files: [
        {
          localFileRef: `lfi1_${"b".repeat(43)}`,
          name: "existing.pdf",
          size: 100,
          mediaType: "application/pdf",
        },
      ],
    });
    const path = await receivedFile();
    await intake!.complete([path]);
    expect(h.picker.importForChat).toHaveBeenCalledWith(
      [path],
      expect.objectContaining({
        maxFiles: 49,
        maxTotalSize: 1024 * 1024 * 1024 - 100,
        maxUploadFiles: 8,
      })
    );
  });
});
