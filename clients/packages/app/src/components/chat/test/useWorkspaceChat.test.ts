import { CommaApiError, type CommaApiClient } from "@comma/app";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { resolveWorkspaceChat } from "../useWorkspaceChat";

describe("Workspace Chat resolution", () => {
  beforeEach(() => {
    installNativeBridgeMock({ platform: "web" });
  });

  it("uses the server ensure endpoint and does not create a client fallback", async () => {
    const api = createWorkspaceChatApi({
      ensureGroupChat: vi.fn(async () => {
        throw new CommaApiError(404, "not_found");
      }),
      getConversation: vi.fn(async () => {
        throw new CommaApiError(404, "not_found");
      }),
    });

    await expect(resolveWorkspaceChat({ api })).resolves.toEqual({
      status: "hidden",
    });

    expect(api.bootstrapWorkspace).toHaveBeenCalledTimes(1);
    expect(api.listWorkspaces).not.toHaveBeenCalled();
    expect(api.ensureGroupChat).toHaveBeenCalledWith("grp_1");
    expect(api.getConversation).not.toHaveBeenCalled();
  });

  it("returns an explicit provisioning state without entering Chat", async () => {
    const api = createWorkspaceChatApi({
      bootstrapWorkspace: vi.fn(async () => ({
        retry_after_seconds: 2,
        status: "provisioning" as const,
        workspace: {
          group_id: "grp_reserved",
          id: "wsp_reserved",
          name: "Default workspace",
          status: "provisioning" as const,
        },
      })),
    });

    await expect(resolveWorkspaceChat({ api })).resolves.toEqual({
      groupId: "grp_reserved",
      retryAfterSeconds: 2,
      status: "provisioning",
      workspaceId: "wsp_reserved",
    });

    expect(api.ensureGroupChat).not.toHaveBeenCalled();
  });

  it.each([
    { expectedStatus: "unauthorized", responseStatus: 401 },
    { expectedStatus: "hidden", responseStatus: 403 },
  ] as const)(
    "maps HTTP $responseStatus to $expectedStatus",
    async ({ expectedStatus, responseStatus }) => {
      const api = createWorkspaceChatApi({
        ensureGroupChat: vi.fn(async () => {
          throw new CommaApiError(responseStatus, "request_failed");
        }),
      });

      await expect(resolveWorkspaceChat({ api })).resolves.toEqual({
        status: expectedStatus,
      });
    }
  );

  it("passes through an unauthorized native resolution", async () => {
    const resolveNativeWorkspaceChat = vi.fn(async () => ({
      status: "unauthorized" as const,
    }));
    installNativeBridgeMock({
      chat: {
        resolveWorkspaceChat: resolveNativeWorkspaceChat,
      },
      platform: "electron",
    });

    await expect(
      resolveWorkspaceChat({
        api: createWorkspaceChatApi(),
        session: testProductLease,
      })
    ).resolves.toEqual({
      status: "unauthorized",
    });
    expect(resolveNativeWorkspaceChat).toHaveBeenCalledWith({
      session: testProductLease,
    });
  });

  it("preserves Main's canonical timestamps in a native ready resolution", async () => {
    const resolveNativeWorkspaceChat = vi.fn(async () => ({
      conversationId: "cnv_native",
      createdAt: 1_720_000_000,
      groupId: "grp_native",
      status: "ready" as const,
      updatedAt: 1_720_000_003,
      workspaceId: "wsp_native",
    }));
    installNativeBridgeMock({
      chat: { resolveWorkspaceChat: resolveNativeWorkspaceChat },
      platform: "electron",
    });

    await expect(
      resolveWorkspaceChat({
        api: createWorkspaceChatApi(),
        defaultTitle: "Native Chat",
        session: testProductLease,
      })
    ).resolves.toMatchObject({
      conversation: {
        created_at: 1_720_000_000,
        id: "cnv_native",
        title: "Native Chat",
        updated_at: 1_720_000_003,
      },
      groupId: "grp_native",
      status: "ready",
      workspaceId: "wsp_native",
    });
  });

  it("fails closed when native Workspace Chat resolution has no Session lease", async () => {
    const resolveNativeWorkspaceChat = vi.fn();
    installNativeBridgeMock({
      chat: { resolveWorkspaceChat: resolveNativeWorkspaceChat },
      platform: "electron",
    });

    await expect(
      resolveWorkspaceChat({ api: createWorkspaceChatApi() })
    ).rejects.toThrow("requires the active Session product lease");
    expect(resolveNativeWorkspaceChat).not.toHaveBeenCalled();
  });

  it("uses the server default Workspace instead of a stale local selection", async () => {
    const ensureGroupChat = vi.fn(async (groupId: string) => ({
      group_id: groupId,
      id: `cnv_public_${groupId}`,
      title: "聊天",
      status: "active",
      kind: "user_chat" as const,
    }));
    const api = createWorkspaceChatApi({
      listWorkspaces: vi.fn(async () => [
        { group_id: "grp_1", id: "wsp_1", name: "Main" },
        { group_id: "grp_2", id: "wsp_2", name: "Second" },
      ]),
      ensureGroupChat,
    });

    await expect(
      resolveWorkspaceChat({ api, workspaceId: "wsp_2" })
    ).resolves.toMatchObject({
      status: "ready",
      groupId: "grp_1",
      workspaceId: "wsp_1",
      conversation: { id: "cnv_public_grp_1", kind: "user_chat" },
    });

    expect(ensureGroupChat).toHaveBeenCalledWith("grp_1");
    expect(api.bootstrapWorkspace).toHaveBeenCalledOnce();
    expect(api.listWorkspaces).not.toHaveBeenCalled();
  });

  it("does not show another workspace Chat on an explicit route scope", async () => {
    const api = createWorkspaceChatApi();

    await expect(
      resolveWorkspaceChat({
        api,
        exactWorkspace: true,
        workspaceId: "wsp_missing",
      })
    ).resolves.toEqual({ status: "hidden" });

    expect(api.ensureGroupChat).not.toHaveBeenCalled();
    expect(api.bootstrapWorkspace).not.toHaveBeenCalled();
  });

  it("resolves only the requested Workspace on an explicit route scope", async () => {
    const ensureGroupChat = vi.fn(async (groupId: string) => ({
      group_id: groupId,
      id: `cnv_public_${groupId}`,
      title: "聊天",
      status: "active",
      kind: "user_chat" as const,
    }));
    const api = createWorkspaceChatApi({
      ensureGroupChat,
      listWorkspaces: vi.fn(async () => [
        { group_id: "grp_1", id: "wsp_1", name: "Main" },
        { group_id: "grp_2", id: "wsp_2", name: "Requested" },
      ]),
    });

    await expect(
      resolveWorkspaceChat({
        api,
        exactWorkspace: true,
        workspaceId: "wsp_2",
      })
    ).resolves.toMatchObject({
      conversation: { id: "cnv_public_grp_2", kind: "user_chat" },
      groupId: "grp_2",
      status: "ready",
      workspaceId: "wsp_2",
    });

    expect(api.listWorkspaces).toHaveBeenCalledOnce();
    expect(ensureGroupChat).toHaveBeenCalledWith("grp_2");
    expect(api.bootstrapWorkspace).not.toHaveBeenCalled();
  });
});

function createWorkspaceChatApi(overrides: Partial<CommaApiClient> = {}) {
  return {
    bootstrapWorkspace: vi.fn(async () => ({
      status: "ready" as const,
      workspace: {
        group_id: "grp_1",
        id: "wsp_1",
        name: "Main",
        status: "ready" as const,
      },
    })),
    listWorkspaces: vi.fn(async () => [
      { group_id: "grp_1", id: "wsp_1", name: "Main" },
    ]),
    ensureGroupChat: vi.fn(async () => ({
      group_id: "grp_1",
      id: "cnv_public_chat_1",
      title: "聊天",
      status: "active",
      kind: "user_chat",
    })),
    getConversation: vi.fn(),
    ...overrides,
  } as unknown as CommaApiClient;
}
