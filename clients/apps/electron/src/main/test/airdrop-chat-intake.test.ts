import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "@comma/app/api";
import { ChatCoordinator } from "../modules/chat";
import { approveAirDropForChat } from "../modules/airdrop/chat-intake";
import type { AirDropOffer } from "../modules/airdrop";

const coordinators: ChatCoordinator[] = [];
const roots: string[] = [];
afterEach(async () => {
  for (const chat of coordinators.splice(0)) chat.close();
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
function harness() {
  const conversation = {
    id: "cnv_1",
    group_id: "grp_1",
    kind: "user_chat",
    status: "active",
    title: "Current chat",
    messages: [],
  };
  const sendMessage = vi.fn(async () => conversation);
  const api = {
    pollConversation: vi.fn(async () => ({ conversation, notModified: false })),
    streamConversationEvents: vi.fn(
      async (_w: unknown, _c: unknown, options: { signal: AbortSignal }) =>
        new Promise<void>((resolve) =>
          options.signal.addEventListener("abort", () => resolve(), { once: true })
        )
    ),
    sendMessage,
  } as unknown as CommaApiClient;
  const chat = new ChatCoordinator({ createApi: () => api });
  coordinators.push(chat);
  const target = {
    workspaceId: "wsp_1",
    groupId: "grp_1",
    conversationId: "cnv_1",
    subscriberId: "main:grp_1/cnv_1",
    leaseId: "renderer-lease",
    surfaceId: "main",
  };
  chat.retain(target);
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
  return {
    chat,
    target,
    picker,
    controller,
    reception,
    sendMessage,
    options: {
      offer,
      signal: controller.signal,
      surfaceId: "main",
      chat,
      picker,
      reception,
    },
  };
}
describe("AirDrop to chat attachments", () => {
  it("adds received files to the existing draft and waits for the user to send", async () => {
    const h = harness();
    h.chat.setDraft({ ...h.target, draft: "Review this" });
    await expect
      .poll(() => h.chat.state().sessions[0]?.state.conversation?.title)
      .toBe("Current chat");
    const intake = await approveAirDropForChat(h.options);
    expect(h.reception.confirm).toHaveBeenCalledWith(
      expect.objectContaining({ chatTitle: "Current chat", senderName: "iPhone" }),
      h.controller.signal
    );
    expect(h.chat.state().sessions[0]?.state.attachmentIntakeInFlight).toBe(true);
    expect(h.picker.importForChat).not.toHaveBeenCalled();
    intake!.progress({ fraction: 0.5, totalBytes: 24, transferredBytes: 12 });
    expect(h.reception.progress).toHaveBeenCalledWith(offer.requestId, {
      fraction: 0.5,
      totalBytes: 24,
      transferredBytes: 12,
    });
    await intake!.complete([await receivedFile()]);
    expect(h.chat.state().sessions[0]?.state).toMatchObject({
      draft: "Review this",
      draftAttachments: [{ name: "report.pdf", status: "uploaded" }],
    });
    expect(h.reception.complete).toHaveBeenCalledWith(offer.requestId, 0);
    expect(h.sendMessage).not.toHaveBeenCalled();
    const reservation = { ...h.target, sendIntentId: "send-after-airdrop" };
    h.chat.beginSendIntent(reservation);
    await h.chat.send({ ...reservation, text: "Review this" });
    expect(h.sendMessage).toHaveBeenCalledWith(
      "grp_1",
      "cnv_1",
      expect.objectContaining({
        text: "Review this",
        localFiles: [expect.objectContaining({ displayName: "report.pdf" })],
      })
    );
  });
  it("declining preserves the draft and leaves no pending attachment intake", async () => {
    const h = harness();
    h.reception.confirm.mockResolvedValue(false);
    h.chat.setDraft({ ...h.target, draft: "Keep me" });
    expect(await approveAirDropForChat(h.options)).toBeUndefined();
    expect(h.chat.state().sessions[0]?.state).toMatchObject({
      draft: "Keep me",
      draftAttachments: [],
    });
    expect(h.chat.state().sessions[0]?.state.attachmentIntakeInFlight).not.toBe(true);
    expect(h.picker.importForChat).not.toHaveBeenCalled();
  });
  it("keeps files local if the user switches chats before upload finishes", async () => {
    const h = harness();
    const intake = await approveAirDropForChat(h.options);
    h.chat.release(h.target);
    h.chat.retain({
      ...h.target,
      conversationId: "cnv_2",
      subscriberId: "main:grp_1/cnv_2",
      leaseId: "next-lease",
    });
    const path = await receivedFile();
    await expect(intake!.complete([path])).rejects.toThrow("changed");
    expect(h.picker.importForChat).not.toHaveBeenCalled();
    expect(
      h.chat.state().sessions.find((s) => s.conversationId === "cnv_2")?.state
        .draftAttachments
    ).toEqual([]);
    expect(h.reception.received).toHaveBeenCalledWith(offer.requestId, [path]);
    expect(h.reception.fail).toHaveBeenCalledWith(offer.requestId, "attach");
  });
  it("does not attach a late transfer after account reset", async () => {
    const h = harness();
    const intake = await approveAirDropForChat(h.options);
    h.chat.reset();
    h.controller.abort();
    await expect(intake!.complete([await receivedFile()])).rejects.toThrow();
    expect(h.chat.state().sessions).toEqual([]);
    expect(h.picker.importForChat).not.toHaveBeenCalled();
  });
  it("attaches a package's files, drops the bundle it emptied, and keeps a full one for Finder", async () => {
    const h = harness();
    await expect
      .poll(() => h.chat.state().sessions[0]?.state.conversation?.title)
      .toBe("Current chat");
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
    h.chat.release(h.target);
    expect(await approveAirDropForChat(h.options)).toBeUndefined();
    expect(h.reception.refuse).toHaveBeenCalledWith(
      expect.not.objectContaining({ chatTitle: expect.any(String) }),
      "no_chat"
    );
    h.chat.retain(h.target);
    expect(
      await approveAirDropForChat({
        ...h.options,
        offer: { ...offer, files: [{ name: "Folder", isDirectory: true }] },
      })
    ).toBeUndefined();
    expect(h.reception.refuse).toHaveBeenLastCalledWith(
      expect.objectContaining({ chatTitle: "Current chat" }),
      "directory"
    );
    expect(h.reception.confirm).not.toHaveBeenCalled();
    expect(h.picker.importForChat).not.toHaveBeenCalled();
  });
  it("recomputes remaining attachment quotas when transfer completes", async () => {
    const h = harness();
    const intake = await approveAirDropForChat(h.options);
    h.chat.attachLocalFiles({
      ...h.target,
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
