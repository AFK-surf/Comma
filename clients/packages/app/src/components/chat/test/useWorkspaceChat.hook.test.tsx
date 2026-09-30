import { act, renderHook, waitFor } from "@comma/test-utils/render";
import type { CommaApiClient } from "@comma/app";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { ChatProvider } from "../ChatProvider";
import { useWorkspaceChat } from "../useWorkspaceChat";

describe("useWorkspaceChat bootstrap polling", () => {
  it("keeps raw provider failures out of the user-facing state", async () => {
    const api = {
      bootstrapWorkspace: vi.fn(async () => {
        throw new Error("upstream secret: request-id=private-123");
      }),
    } as Partial<CommaApiClient> as CommaApiClient;

    const { result } = renderHook(() => useWorkspaceChat({ api }), {
      wrapper: ({ children }: { children: ReactNode }) => (
        <ChatProvider api={api} productLease={testProductLease}>
          {children}
        </ChatProvider>
      ),
    });

    await waitFor(() =>
      expect(result.current.state).toEqual({
        message: "Chat is temporarily unavailable",
        status: "error",
      })
    );
    expect(JSON.stringify(result.current.state)).not.toContain("private-123");
  });

  it("caps provider delay and stops after three automatic provisioning retries", async () => {
    vi.useFakeTimers();
    const bootstrapWorkspace = vi.fn(async () => ({
      retry_after_seconds: 60,
      status: "provisioning" as const,
      workspace: {
        group_id: "grp_reserved",
        id: "wsp_reserved",
        name: "Default workspace",
        status: "provisioning" as const,
      },
    }));
    const api = {
      bootstrapWorkspace,
      ensureGroupChat: vi.fn(),
    } as Partial<CommaApiClient> as CommaApiClient;

    const { result } = renderHook(() => useWorkspaceChat({ api }), {
      wrapper: ({ children }: { children: ReactNode }) => (
        <ChatProvider api={api} productLease={testProductLease}>
          {children}
        </ChatProvider>
      ),
    });

    await act(async () => {
      await Promise.resolve();
    });
    expect(bootstrapWorkspace).toHaveBeenCalledTimes(1);
    expect(result.current.state).toEqual({
      groupId: "grp_reserved",
      retryAfterSeconds: 60,
      status: "provisioning",
      workspaceId: "wsp_reserved",
    });

    await act(async () => {
      await vi.advanceTimersByTimeAsync(9_999);
    });
    expect(bootstrapWorkspace).toHaveBeenCalledTimes(1);

    for (let expectedCalls = 2; expectedCalls <= 4; expectedCalls += 1) {
      await act(async () => {
        await vi.advanceTimersByTimeAsync(expectedCalls === 2 ? 1 : 10_000);
      });
      expect(bootstrapWorkspace).toHaveBeenCalledTimes(expectedCalls);
    }

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });
    expect(bootstrapWorkspace).toHaveBeenCalledTimes(4);
    expect(api.ensureGroupChat).not.toHaveBeenCalled();
  });
});
