import type { ProductInboxListResult } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { describe, expect, it, vi } from "vitest";
import {
  createElectronProductInboxProjectionController,
  productInboxErrorMessage,
  type ProductInboxProjectionBridge,
  type ProductInboxProjectionEnvelope,
} from "../controller";

describe("Electron ProductInbox projection controller", () => {
  it("retains one Main scheduler and releases only the captured Session lease", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, snapshot("workspace-a"))
    );
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    const releaseFirst = controller.retain({ session: leaseA });
    const releaseSecond = controller.retain({ session: leaseA });

    await vi.waitFor(() => {
      expect(bridge.retain).toHaveBeenCalledOnce();
      expect(controller.getSnapshotSync()).toEqual(
        envelope(leaseA, snapshot("workspace-a"))
      );
    });

    releaseFirst();
    expect(bridge.release).not.toHaveBeenCalled();
    releaseSecond();
    await vi.waitFor(() => {
      expect(bridge.release).toHaveBeenCalledWith({ session: leaseA });
    });
  });

  it("serializes startup reads and pagination while retaining both pages", async () => {
    const first = envelope(leaseA, {
      ...taskList("workspace-a", "active"),
      hasMore: true,
      nextCursor: "page-2",
    });
    const second = envelope(leaseA, {
      ...first.snapshot,
      hasMore: false,
      nextCursor: undefined,
      items: [
        {
          ...first.snapshot.items[0]!,
          id: "conversation-b",
          conversationId: "conversation-b",
        },
      ],
    });
    const bridge = new FakeProductInboxProjectionBridge(first);
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());

    const initialRead = Promise.withResolvers<ProductInboxProjectionEnvelope>();
    const pageRead = Promise.withResolvers<ProductInboxProjectionEnvelope>();
    bridge.refresh
      .mockImplementationOnce(() => initialRead.promise)
      .mockImplementationOnce(() => pageRead.promise);
    const refresh = controller.refresh({ workspaceId: "workspace-a" });
    const more = Promise.all([
      controller.refresh({ workspaceId: "workspace-a", cursor: "page-2" }),
      controller.refresh({ workspaceId: "workspace-a", cursor: "page-2" }),
    ]);
    await vi.waitFor(() => expect(bridge.refresh).toHaveBeenCalledTimes(1));
    initialRead.resolve(first);
    await refresh;
    await vi.waitFor(() => expect(bridge.refresh).toHaveBeenCalledTimes(2));
    // The owner publishes the page before its command response arrives.
    bridge.emit(second);
    pageRead.resolve(second);
    const pages = await more;
    expect(pages[0]).toEqual(pages[1]);
    expect(bridge.refresh).toHaveBeenCalledTimes(2);
    expect(controller.getSnapshotSync()?.snapshot.items.map((item) => item.id)).toEqual(
      ["conversation-a", "conversation-b"]
    );
  });

  it("switches Workspace without waiting for old reads or running their queued commands", async () => {
    const first = envelope(leaseA, snapshot("workspace-a"));
    const second = envelope(leaseA, snapshot("workspace-b"));
    const bridge = new FakeProductInboxProjectionBridge(first);
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());
    const oldRead = Promise.withResolvers<ProductInboxProjectionEnvelope>();
    bridge.refresh
      .mockImplementationOnce(() => oldRead.promise)
      .mockResolvedValueOnce(second);
    const old = Promise.allSettled([
      controller.refresh({ workspaceId: "workspace-a" }),
      controller.refresh({ workspaceId: "workspace-a", limit: 25 }),
    ]);
    await vi.waitFor(() => expect(bridge.refresh).toHaveBeenCalledOnce());
    await expect(controller.refresh({ workspaceId: "workspace-b" })).resolves.toEqual(
      second
    );
    oldRead.resolve(first);
    expect((await old).map((result) => result.status)).toEqual([
      "rejected",
      "rejected",
    ]);
    expect(bridge.refresh).toHaveBeenCalledTimes(2);
    expect(controller.getSnapshotSync()).toEqual(second);
  });

  it("drops late envelopes from an old Session and accepts explicit refresh state", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, snapshot("workspace-a"))
    );
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    const releaseA = controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());
    releaseA();

    controller.retain({ session: leaseB });
    bridge.emit(envelope(leaseA, snapshot("workspace-a")));
    expect(controller.getSnapshotSync()).toBeNull();

    bridge.nextRefresh = envelope(leaseB, snapshot("workspace-b"));
    await expect(
      controller.refresh({ limit: 50, workspaceId: "workspace-b" })
    ).resolves.toEqual(bridge.nextRefresh);
    expect(bridge.refresh).toHaveBeenCalledWith({
      limit: 50,
      session: leaseB,
      workspaceId: "workspace-b",
    });
    expect(controller.getSnapshotSync()).toEqual(bridge.nextRefresh);
  });

  it("keeps the list through an equal reread and still reports each owner read", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, taskList("workspace-a", "in_progress", 1))
    );
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());
    const published = controller.getSnapshotSync();
    const listener = vi.fn();
    const ownerRead = vi.fn();
    controller.subscribe(listener);
    controller.subscribeOwnerSnapshot(ownerRead);

    // The owner restates the list, and every page that mounts rereads it; both
    // answer with an equal envelope in a new object. List readers keep what
    // they hold, while each read still reaches the facts outside the page.
    bridge.emit(envelope(leaseA, taskList("workspace-a", "in_progress", 1)));
    bridge.nextRefresh = envelope(leaseA, taskList("workspace-a", "in_progress", 1));
    await expect(controller.refresh({ workspaceId: "workspace-a" })).resolves.toBe(
      published
    );
    expect(controller.getSnapshotSync()).toBe(published);
    expect(listener).not.toHaveBeenCalled();
    expect(ownerRead).toHaveBeenCalledTimes(2);
    expect(controller.getOwnerSnapshotSync()).not.toBe(published);
    expect(controller.getOwnerSnapshotSync()).toEqual(published);

    bridge.nextRefresh = envelope(leaseA, taskList("workspace-a", "completed", 2));
    await controller.refresh({ workspaceId: "workspace-a" });
    expect(listener).toHaveBeenCalledOnce();
    expect(ownerRead).toHaveBeenCalledTimes(3);
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("completed");
  });

  it("clears an item-inferred Workspace projection before a different refresh settles", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, {
        items: [
          {
            conversationId: "conversation-a",
            id: "workspace-a:conversation-a",
            kind: "agent_task",
            source: "salix.conversation",
            status: "in_progress",
            title: "Account A task",
            updatedAt: 1,
            workspaceId: "workspace-a",
            workspaceName: "Account A",
            groupId: "grp_test",
          },
        ],
        source: "live-sync",
      })
    );
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());

    bridge.nextRefresh = envelope(leaseA, snapshot("workspace-b"));
    const refresh = controller.refresh({ workspaceId: "workspace-b" });
    expect(controller.getSnapshotSync()).toBeNull();
    await refresh;
    expect(controller.getSnapshotSync()).toEqual(bridge.nextRefresh);
  });

  it("publishes an explicit unavailable projection when generated state fails", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, snapshot("workspace-a"))
    );
    bridge.failRetain = true;
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });

    controller.retain({ session: leaseA });

    await vi.waitFor(() => {
      expect(controller.getSnapshotSync()).toEqual({
        session: leaseA,
        snapshot: {
          errorCode: "utility_unavailable",
          items: [],
          source: "unavailable",
        },
      });
    });
    expect(bridge.refresh).not.toHaveBeenCalled();
  });

  it("shows a staged archive at once and lets only the owner end it", async () => {
    const running = envelope(leaseA, taskList("workspace-a", "in_progress", 1));
    const bridge = new FakeProductInboxProjectionBridge(running);
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("in_progress");

    const stage = controller.stageTaskArchived({
      conversationId: "conversation-a",
      groupId: "grp_test",
      version: 1,
    });
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("archived");

    // Confirming keeps the decided view while the owner still reports the same
    // version of the Task: the decision outlives the request that carried it.
    stage.confirm();
    bridge.emit(running);
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("archived");

    // The owner's own archived fact is the end of the decision, and from there
    // the owner's envelope is published exactly as served.
    bridge.emit(envelope(leaseA, taskList("workspace-a", "archived", 2)));
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("archived");
    bridge.emit(running);
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("in_progress");
  });

  it("gives a Task back when the authority reports a later version", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, taskList("workspace-a", "in_progress", 1))
    );
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());

    const stage = controller.stageTaskArchived({
      conversationId: "conversation-a",
      groupId: "grp_test",
      version: 1,
    });
    stage.confirm();
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("archived");

    // Another client reverse-archived the Task before this client reread it, so
    // the authority now reports a version later than the one the decision was
    // taken against. Its word ends the decision, instead of leaving the card
    // hidden behind a fact nobody holds any more.
    bridge.emit(envelope(leaseA, taskList("workspace-a", "completed", 3)));
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("completed");
  });

  it("returns a Task the authority never confirmed", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, taskList("workspace-a", "in_progress", 1))
    );
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());

    const stage = controller.stageTaskArchived({
      conversationId: "conversation-a",
      groupId: "grp_test",
      version: 1,
    });
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("archived");

    stage.rollback();
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("in_progress");
  });

  it("never carries one Session's decisions into another", async () => {
    const bridge = new FakeProductInboxProjectionBridge(
      envelope(leaseA, taskList("workspace-a", "in_progress", 1))
    );
    const controller = createElectronProductInboxProjectionController({
      bridge: bridge.value,
    });
    const releaseA = controller.retain({ session: leaseA });
    await vi.waitFor(() => expect(controller.getSnapshotSync()).not.toBeNull());
    controller.stageTaskArchived({
      conversationId: "conversation-a",
      groupId: "grp_test",
      version: 1,
    });
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("archived");
    releaseA();

    bridge.nextRefresh = envelope(leaseB, taskList("workspace-a", "in_progress", 1));
    controller.retain({ session: leaseB });
    const next = await controller.refresh({ workspaceId: "workspace-a" });
    expect(next.session).toEqual(leaseB);
    expect(controller.getSnapshotSync()!.snapshot.items[0]!.status).toBe("in_progress");
  });
});

describe("ProductInbox error copy", () => {
  it("uses the requested client locale", () => {
    expect(productInboxErrorMessage("network_unavailable")).toBe(
      "Comma could not reach the ProductInbox authority."
    );
    expect(productInboxErrorMessage("network_unavailable", "zh-CN")).toBe(
      "Comma 无法连接 ProductInbox 服务。"
    );
  });
});

class FakeProductInboxProjectionBridge {
  readonly refresh = vi.fn(
    async (_input: {
      cursor?: string | undefined;
      limit?: number | undefined;
      session: SessionProductLease;
      workspaceId?: string | undefined;
    }) => this.nextRefresh
  );
  readonly release = vi.fn(async (_input: { session: SessionProductLease }) => true);
  readonly retain = vi.fn(async (_input: { session: SessionProductLease }) => {
    if (this.failRetain) {
      throw new Error("retain unavailable");
    }
    return this.current;
  });
  failRetain = false;
  nextRefresh: ProductInboxProjectionEnvelope;
  private current: ProductInboxProjectionEnvelope;
  private readonly listeners = new Set<
    (value: ProductInboxProjectionEnvelope) => void
  >();
  readonly value: ProductInboxProjectionBridge;

  constructor(initial: ProductInboxProjectionEnvelope) {
    this.current = initial;
    this.nextRefresh = initial;
    const get = vi.fn(async () => this.current);
    const state = Object.assign(get, {
      get,
      subscribe: (
        listener: (value: ProductInboxProjectionEnvelope) => void,
        _input: { session: SessionProductLease }
      ) => {
        this.listeners.add(listener);
        queueMicrotask(() => listener(this.current));
        return () => {
          this.listeners.delete(listener);
        };
      },
    });
    this.value = {
      refresh: this.refresh,
      release: this.release,
      retain: this.retain,
      state,
    };
  }

  emit(value: ProductInboxProjectionEnvelope) {
    this.current = value;
    for (const listener of this.listeners) {
      listener(value);
    }
  }
}

const leaseA: SessionProductLease = {
  audience: "https://api.example",
  authorityInstanceId: "main-authority",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};

const leaseB: SessionProductLease = {
  ...leaseA,
  generation: 2,
  sessionId: "22222222-2222-4222-8222-222222222222",
};

function envelope(
  session: SessionProductLease,
  result: ProductInboxListResult
): ProductInboxProjectionEnvelope {
  return { session, snapshot: result };
}

function taskList(
  workspaceId: string,
  status: string,
  version = 1
): ProductInboxListResult {
  return {
    activeWorkspaceId: workspaceId,
    items: [
      {
        archiveVersion: version,
        conversationId: "conversation-a",
        groupId: "grp_test",
        id: "conversation-a",
        kind: "agent_task",
        source: "salix.conversation",
        status,
        title: "Account A task",
        updatedAt: 1,
        workspaceId,
        workspaceName: "Account A",
      },
    ],
    source: "live-sync",
  };
}

function snapshot(workspaceId: string): ProductInboxListResult {
  return {
    activeWorkspaceId: workspaceId,
    items: [],
    source: "live-sync",
  };
}
