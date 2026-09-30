import { createCommaApi } from "@comma/app";
import { describe, expect, it, vi } from "vitest";
import {
  commaBillingSummarySchema,
  commaConversationEventSchema,
  commaTaskParticipantStatusesSchema,
} from "../schemas";

describe("commaBillingSummarySchema", () => {
  it("accepts legacy active grants without package or source identifiers", () => {
    expect(
      commaBillingSummarySchema.parse({
        billing_account_id: "ba-workspace-1",
        current_credits: "0",
        active_grants: [
          {
            id: "legacy-grant-1",
            package_code: null,
            package_version: null,
            remaining_credits: 0,
            valid_from: "2026-09-01T00:00:00Z",
            expires_at: null,
            source_type: "legacy_grant",
            source_id: null,
          },
        ],
      })
    ).toMatchObject({ current_credits: 0 });
  });

  it("accepts the active subscription projection", () => {
    expect(
      commaBillingSummarySchema.parse({
        billing_account_id: "ba-workspace-1",
        current_credits: 20_000_000,
        active_subscription: {
          package_code: "comma_value",
          package_version: "2026-06",
          status: "active",
          source_id: "sub_1",
        },
        active_grants: [],
      })
    ).toMatchObject({
      active_subscription: {
        package_code: "comma_value",
        status: "active",
      },
    });
  });
});

describe("createCommaApi", () => {
  it("sends bearer auth to Comma product endpoints", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ data: [{ group_id: "grp1_1", id: "wsp_1", name: "Main" }] })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200/",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.listWorkspaces()).resolves.toEqual([
      { group_id: "grp1_1", id: "wsp_1", name: "Main" },
    ]);

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/workspaces",
      expect.objectContaining({
        method: "GET",
        headers: expect.objectContaining({
          authorization: "Bearer comma_sess_test",
        }),
      })
    );
  });

  it("uses the Comma Telegram product endpoints and validates their responses", async () => {
    const responses = [
      {
        bot_url: "https://t.me/CommaTestBot",
        bot_username: "CommaTestBot",
        configured: true,
        link: null,
        official_login_available: true,
        pending_claim: null,
        workspace_id: "workspace-1",
        workspace_name: "Main",
      },
      {
        authorization_url: "https://oauth.telegram.org/auth?state=test",
        expires_in_seconds: 600,
        workspace_id: "workspace-1",
      },
      { disconnected: true },
    ];
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse(responses.shift())
    );
    const api = createCommaApi({
      baseUrl: "https://api.example",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.getTelegramIntegration("workspace-1")).resolves.toMatchObject({
      configured: true,
      link: null,
    });
    await expect(api.startTelegramConnect("workspace-1")).resolves.toMatchObject({
      expires_in_seconds: 600,
    });
    await expect(api.disconnectTelegram("workspace-1")).resolves.toBe(true);

    expect(
      fetchMock.mock.calls.map(([url, init]) => ({
        method: (init as RequestInit).method,
        path: new URL(String(url)).pathname,
      }))
    ).toEqual([
      {
        method: "GET",
        path: "/v1/comma/workspaces/workspace-1/integrations/telegram",
      },
      {
        method: "POST",
        path: "/v1/comma/workspaces/workspace-1/integrations/telegram/connect",
      },
      {
        method: "DELETE",
        path: "/v1/comma/workspaces/workspace-1/integrations/telegram",
      },
    ]);
  });

  it("sends Stripe checkout to the environment-aware server return page", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        id: "cs_test_1",
        provider: "stripe",
        url: "https://checkout.stripe.com/c/pay/cs_test_1",
      })
    );
    const api = createCommaApi({
      baseUrl: "assets://.",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await api.createBillingCheckout("workspace-1", "comma_value_v1");

    const [, init] = fetchMock.mock.calls[0] as unknown as [
      RequestInfo | URL,
      RequestInit,
    ];
    expect(JSON.parse(String(init.body))).toMatchObject({
      cancel_url:
        "http://127.0.0.1:4200/v1/comma/billing/stripe/checkout/return?environment=dev&status=cancel",
      success_url:
        "http://127.0.0.1:4200/v1/comma/billing/stripe/checkout/return?environment=dev&status=success",
    });
  });

  it("returns from the Stripe billing portal through the server landing page", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        id: "bps_test_1",
        provider: "stripe",
        url: "https://billing.stripe.com/p/session/test",
      })
    );
    const api = createCommaApi({
      baseUrl: "assets://.",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await api.createBillingPortal("workspace-1");

    const [, init] = fetchMock.mock.calls[0] as unknown as [
      RequestInfo | URL,
      RequestInit,
    ];
    expect(JSON.parse(String(init.body))).toMatchObject({
      return_url:
        "http://127.0.0.1:4200/v1/comma/billing/stripe/checkout/return?environment=dev&status=portal",
    });
  });

  it("confirms the quoted subscription change with its original request identity", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        id: "bps_change_1",
        provider: "stripe",
        effect: "upgraded",
      })
    );
    const api = createCommaApi({
      baseUrl: "assets://.",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await api.changeBillingSubscription(
      "workspace-1",
      "comma_pro_v1",
      {
        amount_minor: 1000,
        currency: "usd",
        effect: "upgrade",
        current_price_id: "price_current",
        proration_date: 1234,
        period_end: 5678,
      },
      "confirmed-request"
    );

    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toContain(
      "/v1/comma/workspaces/workspace-1/billing/subscription/change"
    );
    expect(JSON.parse(String(init.body))).toMatchObject({
      plan_key: "comma_pro_v1",
      current_price_id: "price_current",
      proration_date: 1234,
      period_end: 5678,
      client_request_id: "confirmed-request",
      success_url:
        "http://127.0.0.1:4200/v1/comma/billing/stripe/checkout/return?environment=dev&status=subscription",
    });
  });

  it("uploads an avatar as authenticated multipart data", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        avatar_id: "avt_1",
        email: "ada@example.com",
        id: "usr_ada",
        name: "Ada",
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const file = new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "ada.png", {
      type: "image/png",
    });

    await expect(api.uploadAvatar(file)).resolves.toMatchObject({
      avatar_id: "avt_1",
    });

    const [, init] = fetchMock.mock.calls[0] as unknown as [
      RequestInfo | URL,
      RequestInit,
    ];
    expect(init).toMatchObject({ method: "PUT" });
    expect(init?.headers).toMatchObject({ authorization: "Bearer comma_sess_test" });
    expect(init?.body).toBeInstanceOf(FormData);
    expect((init.body as FormData).get("avatar")).toBe(file);
  });

  it("accepts imported profile names up to the physical 200-character bound", async () => {
    const importedName = "a".repeat(200);
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: vi.fn(async () =>
        jsonResponse({
          avatar_id: null,
          email: "imported@example.com",
          id: "usr_imported",
          name: importedName,
        })
      ),
    });

    await expect(api.getProfile()).resolves.toMatchObject({ name: importedName });
  });

  it("reports a terminal product 401 to the session owner", async () => {
    const onUnauthorized = vi.fn();
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "",
      fetch: vi.fn(async () => jsonResponse({ error: "unauthorized" }, 401)),
      onUnauthorized,
    });

    await expect(api.listWorkspaces()).rejects.toMatchObject({ status: 401 });
    expect(onUnauthorized).toHaveBeenCalledOnce();
  });

  it.each([403, 404])(
    "does not invalidate the session for a product %s",
    async (status) => {
      const onUnauthorized = vi.fn();
      const api = createCommaApi({
        baseUrl: "http://127.0.0.1:4200",
        token: "",
        fetch: vi.fn(async () => jsonResponse({ error: "request_failed" }, status)),
        onUnauthorized,
      });

      await expect(api.listWorkspaces()).rejects.toMatchObject({ status });
      expect(onUnauthorized).not.toHaveBeenCalled();
    }
  );

  it("accepts a 202 default Workspace bootstrap response", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            retry_after_seconds: 2,
            status: "provisioning",
            workspace: {
              group_id: "grp1_reserved",
              id: "wsp_reserved",
              name: "Default workspace",
              owner_user_id: "usr_1",
              status: "provisioning",
            },
          }),
          {
            status: 202,
            headers: { "content-type": "application/json", "retry-after": "2" },
          }
        )
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.bootstrapWorkspace()).resolves.toEqual({
      retry_after_seconds: 2,
      status: "provisioning",
      workspace: {
        group_id: "grp1_reserved",
        id: "wsp_reserved",
        name: "Default workspace",
        owner_user_id: "usr_1",
        status: "provisioning",
      },
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/me/bootstrap",
      expect.objectContaining({
        body: JSON.stringify({}),
        method: "POST",
      })
    );
  });

  it("ensures the Group-owned fixed Router Conversation", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        id: "cnv_public_chat_1",
        group_id: "grp1_1",
        title: "聊天",
        status: "active",
        kind: "user_chat",
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.ensureGroupChat("grp1_1")).resolves.toMatchObject({
      id: "cnv_public_chat_1",
      kind: "user_chat",
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/assistant-chat",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({}),
      })
    );
  });

  it("loads a bounded Task preview without requesting its transcript", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        activity_status: "idle",
        freshness: { state: "fresh" },
        id: "cnv_task_public",
        kind: "agent_task",
        status: "running",
        title: "Deploy report",
        updated_at: 2,
        group_id: "grp1_1",
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      fetch: fetchMock,
      token: "comma_sess_test",
    });

    await expect(
      api.getConversationPreview("grp1_1", "cnv_task_public")
    ).resolves.toMatchObject({ id: "cnv_task_public", title: "Deploy report" });
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_task_public/preview",
      expect.objectContaining({ method: "GET" })
    );
  });

  it("searches the bounded Task index and forwards cancellation", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        data: [
          {
            conversation_id: "cnv_task_public",
            highlights: [{ start: 7, end: 13 }],
            matched_field: "content",
            snippet: "Ship the search palette",
            title: "Comma client",
            updated_at: 2,
          },
        ],
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const controller = new AbortController();

    await expect(
      api.searchTasks("grp1_1", "search palette", {
        limit: 20,
        signal: controller.signal,
      })
    ).resolves.toEqual([
      {
        conversation_id: "cnv_task_public",
        highlights: [{ start: 7, end: 13 }],
        matched_field: "content",
        snippet: "Ship the search palette",
        title: "Comma client",
        updated_at: 2,
      },
    ]);

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/search?limit=20&q=search+palette",
      expect.objectContaining({ method: "GET", signal: controller.signal })
    );
  });

  it("polls the conversation list with its opaque ETag and reuses the public cache on 304", async () => {
    const page = {
      data: [
        {
          id: "cnv_1",
          group_id: "grp1_1",
          title: "Task",
          status: "running",
          kind: "agent_task",
          freshness: { state: "fresh" },
        },
      ],
      has_more: false,
      next_cursor: null,
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(JSON.stringify(page), {
          status: 200,
          headers: {
            "content-type": "application/json",
            etag: '"opaque-list-version"',
          },
        })
      )
      .mockResolvedValueOnce(new Response(null, { status: 304 }));
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock as unknown as typeof fetch,
    });

    await expect(api.listConversations("grp1_1")).resolves.toEqual(page.data);
    await expect(api.listConversations("grp1_1")).resolves.toEqual(page.data);

    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations",
      expect.objectContaining({
        headers: expect.objectContaining({
          "if-none-match": '"opaque-list-version"',
        }),
        method: "GET",
      })
    );
  });

  it("renames a Task through the canonical Group route", async () => {
    const task = {
      freshness: { state: "fresh" as const },
      group_id: "grp1_1",
      id: "cnv_task",
      kind: "agent_task" as const,
      status: "running",
      title: "Task",
      updated_at: 2,
    };
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (init?.method === "PATCH" && url.endsWith("/cnv_task")) {
        return jsonResponse({ ...task, title: "Renamed Task" });
      }
      return jsonResponse({ error: "not_found" }, 404);
    });
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock as unknown as typeof fetch,
    });

    await expect(
      api.renameTask("grp1_1", "cnv_task", "Renamed Task")
    ).resolves.toMatchObject({ id: "cnv_task", title: "Renamed Task" });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_task",
      expect.objectContaining({
        body: JSON.stringify({ title: "Renamed Task" }),
        method: "PATCH",
      })
    );
  });

  it("loads a single cached conversation page with explicit cursor metadata", async () => {
    const firstPage = {
      data: [
        {
          id: "cnv_1",
          group_id: "grp1_1",
          title: "First",
          status: "running",
          kind: "agent_task",
          freshness: { state: "fresh" },
        },
      ],
      has_more: true,
      next_cursor: "opaque-page-2",
    };
    const secondPage = {
      data: [
        {
          id: "cnv_2",
          group_id: "grp1_1",
          title: "Second",
          status: "completed",
          kind: "agent_task",
          freshness: { state: "fresh" },
        },
      ],
      has_more: false,
      next_cursor: null,
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(JSON.stringify(firstPage), {
          status: 200,
          headers: { "content-type": "application/json", etag: '"page-1"' },
        })
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify(secondPage), {
          status: 200,
          headers: { "content-type": "application/json", etag: '"page-2"' },
        })
      )
      .mockResolvedValueOnce(
        new Response(null, { status: 304, headers: { etag: '"page-2"' } })
      );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock as unknown as typeof fetch,
    });

    await expect(api.listConversationPage("grp1_1", { limit: 50 })).resolves.toEqual({
      data: firstPage.data,
      hasMore: true,
      nextCursor: "opaque-page-2",
    });
    await expect(
      api.listConversationPage("grp1_1", { cursor: "opaque-page-2", limit: 50 })
    ).resolves.toEqual({ data: secondPage.data, hasMore: false });
    await expect(
      api.listConversationPage("grp1_1", { cursor: "opaque-page-2", limit: 50 })
    ).resolves.toEqual({ data: secondPage.data, hasMore: false });

    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations?cursor=opaque-page-2&limit=50",
      expect.objectContaining({ method: "GET" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations?cursor=opaque-page-2&limit=50",
      expect.objectContaining({
        headers: expect.objectContaining({ "if-none-match": '"page-2"' }),
      })
    );
  });

  it("omits Authorization when the renderer has no token", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ data: [] }));
    const api = createCommaApi({
      baseUrl: "assets://.",
      token: "",
      fetch: fetchMock as unknown as typeof fetch,
    });

    await api.listWorkspaces();

    expect(fetchMock).toHaveBeenCalledWith(
      "assets://./v1/comma/workspaces",
      expect.objectContaining({
        headers: expect.not.objectContaining({
          authorization: expect.any(String),
        }),
      })
    );
  });

  it("posts user messages with a text content envelope", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        id: "cnv_1",
        kind: "user_chat",
        group_id: "grp1_1",
        title: "Thread",
        status: "waiting",
        messages: [],
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await api.sendMessage("grp1_1", "cnv_1", {
      text: "hello",
      clientRequestId: "req_1",
      clientDeviceId: "dev_local",
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_1/messages",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          message: { type: "text", text: "hello" },
          client_request_id: "req_1",
          client_device_id: "dev_local",
        }),
      })
    );
  });

  it("posts ref-only local attachments in the canonical message envelope", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        id: "cnv_1",
        kind: "user_chat",
        group_id: "grp1_1",
        title: "Thread",
        status: "waiting",
        messages: [],
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const localFile = {
      displayName: "report.pdf",
      localFileRef: `lfi1_${"a".repeat(43)}`,
      mediaType: "application/pdf",
      size: 12,
    };

    await api.sendMessage("grp1_1", "cnv_1", {
      text: "review this",
      clientRequestId: "req_local_file",
      localFiles: [localFile],
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_1/messages",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          message: {
            content: [
              { type: "text", text: "review this" },
              {
                type: "local_file",
                local_file_ref: localFile.localFileRef,
                display_name: "report.pdf",
                media_type: "application/pdf",
                size: 12,
              },
            ],
          },
          client_request_id: "req_local_file",
        }),
      })
    );
  });

  it("accepts the exact Task completion version the user reviewed", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        id: "cnv_task",
        group_id: "grp1_1",
        title: "Task",
        status: "completed",
        kind: "agent_task",
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.acceptTaskReview("grp1_1", "cnv_task", 2)).resolves.toMatchObject({
      id: "cnv_task",
      status: "completed",
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_task/accept",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ review_version: 2 }),
      })
    );
  });

  it("polls task detail with an opaque ETag and accepts 304 without JSON", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            id: "cnv_task",
            group_id: "grp1_1",
            title: "Task",
            status: "running",
            kind: "agent_task",
          }),
          {
            status: 200,
            headers: {
              "content-type": "application/json",
              etag: '"opaque-task-version"',
            },
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(null, {
          status: 304,
          headers: { etag: '"opaque-task-version"' },
        })
      );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock as unknown as typeof fetch,
    });

    const first = await api.pollConversation("grp1_1", "cnv_task");
    expect(first).toMatchObject({
      conversation: { id: "cnv_task", kind: "agent_task", status: "running" },
      etag: '"opaque-task-version"',
      notModified: false,
    });

    expect(first.etag).toBe('"opaque-task-version"');
    const second = await api.pollConversation("grp1_1", "cnv_task", {
      etag: first.etag!,
    });
    expect(second).toEqual({
      etag: '"opaque-task-version"',
      notModified: true,
    });
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_task",
      expect.objectContaining({
        headers: expect.objectContaining({
          "if-none-match": '"opaque-task-version"',
        }),
        method: "GET",
      })
    );
  });

  it("lists workspace skills and includes selected skill locations on sends", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/skills")) {
        return jsonResponse({
          data: [
            {
              skill_id: "weekly-summary",
              name: "Weekly Summary",
              location: "/.runtime/skills/weekly-summary/SKILL.md",
            },
          ],
        });
      }

      return jsonResponse({
        id: "cnv_1",
        kind: "user_chat",
        group_id: "grp1_1",
        title: "Thread",
        status: "waiting",
        messages: [],
      });
    });
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.listWorkspaceSkills("wsp_1")).resolves.toMatchObject([
      { skill_id: "weekly-summary" },
    ]);

    await api.sendMessage("grp1_1", "cnv_1", {
      text: "hello /weekly-summary",
      clientRequestId: "req_skills",
      replyToMessageId: "earlier-card",
      skills: [{ location: "/.runtime/skills/weekly-summary/SKILL.md" }],
    });

    expect(fetchMock).toHaveBeenLastCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_1/messages",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          message: { type: "text", text: "hello /weekly-summary" },
          client_request_id: "req_skills",
          reply_to_message_id: "earlier-card",
          skills: [{ location: "/.runtime/skills/weekly-summary/SKILL.md" }],
        }),
      })
    );
  });

  it("lists, installs with authorization, and uninstalls workspace plugins", async () => {
    const plugin = {
      id: "linear",
      name: "Linear",
      summary: "Plan and track product work",
      description: "Plan and track product work",
      brand: "linear",
      category: "Integrations",
      installed: false,
      locked: false,
      mcps: [{ id: "linear-mcp", name: "Linear MCP" }],
      skills: [],
    };
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);

      if (url.endsWith("/install")) {
        return jsonResponse({
          plugin,
          authorization: {
            authorizationUrl: "https://linear.app/oauth/authorize?state=state-1",
            state: "state-1",
          },
        });
      }

      return jsonResponse(
        init?.method === "GET" ? { data: [plugin] } : { ...plugin, installed: true }
      );
    });
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.listWorkspacePlugins("wsp_1")).resolves.toEqual([plugin]);
    await expect(api.installWorkspacePlugin("wsp_1", "linear")).resolves.toMatchObject({
      plugin: { id: "linear", installed: false },
      authorization: { state: "state-1" },
    });
    await api.installWorkspacePlugin("wsp_1", "linear", {
      authorizationState: "state-1",
      verifyOnly: true,
    });
    await expect(
      api.uninstallWorkspacePlugin("wsp_1", "linear")
    ).resolves.toMatchObject({
      id: "linear",
    });
    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/plugins",
      expect.objectContaining({ method: "GET" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/plugins/linear/install",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ contract: "unified_v1" }),
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/plugins/linear/install",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          contract: "unified_v1",
          authorization_state: "state-1",
          verify_only: true,
        }),
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      4,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/plugins/linear",
      expect.objectContaining({ method: "DELETE" })
    );
  });

  it("completes legacy install and authorize responses as one client operation", async () => {
    const plugin = {
      id: "linear",
      name: "Linear",
      summary: "Plan and track product work",
      category: "Integrations",
      installed: true,
      locked: false,
      mcps: [],
      skills: [],
    };
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/authorize")) {
        return jsonResponse({
          authorizationUrl: "https://linear.app/oauth/authorize?state=legacy-state",
          state: "legacy-state",
        });
      }
      return jsonResponse(plugin);
    });
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.installWorkspacePlugin("wsp_1", "linear")).resolves.toEqual({
      plugin: { ...plugin, installed: false },
      authorization: {
        authorizationUrl: "https://linear.app/oauth/authorize?state=legacy-state",
        state: "legacy-state",
      },
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/plugins/linear/authorize",
      expect.objectContaining({ method: "POST", body: JSON.stringify({}) })
    );
  });

  it("rolls back an old-server install when verify-only authorization is cancelled", async () => {
    const installedPlugin = {
      id: "linear",
      name: "Linear",
      summary: "Plan and track product work",
      category: "Integrations",
      installed: true,
      locked: false,
      mcps: [],
      skills: [],
    };
    const uninstalledPlugin = { ...installedPlugin, installed: false };
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (init?.method === "DELETE") return jsonResponse(uninstalledPlugin);
      if (url.endsWith("/authorize")) {
        return jsonResponse({
          authorizationUrl: "https://linear.app/oauth/authorize?state=replacement",
          state: "replacement",
        });
      }
      return jsonResponse(installedPlugin);
    });
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.installWorkspacePlugin("wsp_1", "linear")).resolves.toEqual({
      plugin: { ...installedPlugin, installed: false },
      authorization: {
        authorizationUrl: "https://linear.app/oauth/authorize?state=replacement",
        state: "replacement",
      },
    });
    await expect(
      api.installWorkspacePlugin("wsp_1", "linear", {
        authorizationState: "replacement",
        verifyOnly: true,
      })
    ).resolves.toEqual({ plugin: uninstalledPlugin, authorization: null });

    expect(fetchMock).toHaveBeenCalledTimes(5);
    expect(fetchMock).toHaveBeenNthCalledWith(
      5,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/plugins/linear",
      expect.objectContaining({ method: "DELETE" })
    );
  });

  it("uploads Group Router files as multipart without a Workspace ownership alias", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        path: "/uploads/1-report.txt",
        name: "report.txt",
        size: 11,
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(
      api.uploadGroupFile("grp_1", {
        data: new Blob(["hello world"], { type: "text/plain" }),
        name: "report.txt",
      })
    ).resolves.toEqual({
      path: "/uploads/1-report.txt",
      name: "report.txt",
      size: 11,
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp_1/files",
      expect.objectContaining({
        method: "POST",
        body: expect.any(FormData),
        headers: expect.objectContaining({
          accept: "application/json, text/event-stream",
          authorization: "Bearer comma_sess_test",
        }),
      })
    );
    const calls = fetchMock.mock.calls as unknown as [RequestInfo | URL, RequestInit][];
    const init = calls[0]![1];
    expect(init.headers).not.toHaveProperty("content-type");
  });

  it("surfaces upload API errors with the response status", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ error: "file_too_large" }), {
          status: 413,
          headers: { "content-type": "application/json" },
        })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(
      api.uploadGroupFile("grp_1", {
        data: new Blob(["too large"]),
        name: "huge.txt",
      })
    ).rejects.toMatchObject({ status: 413, message: "file_too_large" });
  });

  it("fetches an uploaded Group Router image with the current Session", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(Uint8Array.of(137, 80, 78, 71), {
          headers: { "content-type": "image/png" },
          status: 200,
        })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    const image = await api.fetchGroupFile("grp_1", "/uploads/opaque image.png");

    expect(image.type).toBe("image/png");
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(
      Uint8Array.of(137, 80, 78, 71)
    );
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp_1/files?path=%2Fuploads%2Fopaque+image.png",
      expect.objectContaining({
        method: "GET",
        headers: expect.objectContaining({
          authorization: "Bearer comma_sess_test",
        }),
      })
    );
  });

  it("fetches an Agent blob from its resource reference", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(Uint8Array.of(137, 80, 78, 71), {
          headers: { "content-type": "application/octet-stream" },
          status: 200,
        })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const ref = {
      hash: "b".repeat(64),
      kind: "blob" as const,
      size: 4,
      uuid: "a".repeat(32),
    };

    const image = await api.fetchAgentBlob("grp_1", "agt1_image_author", ref);

    expect(new Uint8Array(await image.arrayBuffer())).toEqual(
      Uint8Array.of(137, 80, 78, 71)
    );
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp_1/agents/agt1_image_author/resources",
      expect.objectContaining({
        body: JSON.stringify({ ref }),
        headers: expect.objectContaining({
          authorization: "Bearer comma_sess_test",
          "content-type": "application/json",
        }),
        method: "POST",
      })
    );
  });

  it("manages inbound API keys through Comma API", async () => {
    const created = {
      key_id: "gak_1",
      name: "Zendesk",
      prefix: "salix_gk_abcdef",
      status: "active",
      created_by: "comma_user:usr_1",
      created_at: 1_700_000_000,
      key: "salix_gk_abcdefsecret",
      post_message_url:
        "https://salix.example/v1/agent-groups/grp_1/router/post-message",
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(created))
      .mockResolvedValueOnce(jsonResponse([{ ...created, key: undefined }]))
      .mockResolvedValueOnce(
        jsonResponse({ ...created, key: undefined, status: "disabled" })
      )
      .mockResolvedValueOnce(jsonResponse({ deleted: true }));
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.createRouterApiKey("wsp_1", { name: "Zendesk" })).resolves.toEqual(
      created
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/router-api-keys",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ name: "Zendesk" }),
      })
    );

    // The list projection never carries the plaintext, and the schema does
    // not invent one.
    const [listed] = await api.listRouterApiKeys("wsp_1");
    expect(listed).not.toHaveProperty("key");
    expect(listed?.key_id).toBe("gak_1");

    await expect(
      api.updateRouterApiKey("wsp_1", "gak_1", { status: "disabled", expiresAt: null })
    ).resolves.toMatchObject({ status: "disabled" });
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/router-api-keys/gak_1",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ status: "disabled", expires_at: null }),
      })
    );

    await expect(api.deleteRouterApiKey("wsp_1", "gak_1")).resolves.toBeUndefined();
    expect(fetchMock).toHaveBeenNthCalledWith(
      4,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/router-api-keys/gak_1",
      expect.objectContaining({ method: "DELETE" })
    );
  });

  it("manages voice agent API keys through Comma API", async () => {
    const created = {
      key_id: "gak_v1",
      name: "Kiosk",
      prefix: "salix_vk_abcdef",
      status: "active",
      kind: "voice",
      created_at: 1_700_000_000,
      key: "salix_vk_abcdefsecret",
      sessions_url: "wss://salix.example/v1/agent-groups/grp_1/voice/sessions",
      readiness_url: "https://salix.example/v1/agent-groups/grp_1/voice",
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(created, 201))
      .mockResolvedValueOnce(jsonResponse([{ ...created, key: undefined }]))
      .mockResolvedValueOnce(jsonResponse({ deleted: true }));
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(
      api.createVoiceApiKey("wsp_1", { name: "Kiosk" })
    ).resolves.toMatchObject({
      key: "salix_vk_abcdefsecret",
      sessions_url: created.sessions_url,
    });
    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/voice-api-keys",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ name: "Kiosk" }),
      })
    );

    const [listed] = await api.listVoiceApiKeys("wsp_1");
    expect(listed).not.toHaveProperty("key");
    expect(listed?.readiness_url).toBe(created.readiness_url);

    await api.deleteVoiceApiKey("wsp_1", "gak_v1");
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/voice-api-keys/gak_v1",
      expect.objectContaining({ method: "DELETE" })
    );
  });

  it("verifies voice caller numbers and reports a number bound elsewhere", async () => {
    const status = {
      lines: ["+15550001111"],
      numbers: [
        {
          e164: "+15551234567",
          carrier: "twilio",
          line: "+15550001111",
          verified_at: 1_700_000_000_000,
          pin_set: true,
          pin_locked_until: null,
          status: "verified",
        },
      ],
      readiness: { ready: true, reason: null },
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ e164: "+15551234567", status: "pending" }))
      .mockResolvedValueOnce(jsonResponse(status))
      .mockResolvedValueOnce(jsonResponse(status))
      .mockResolvedValueOnce(jsonResponse({ ...status, numbers: [] }))
      .mockResolvedValueOnce(jsonResponse({ error: "voice_number_in_use" }, 409));
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const base = "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/integrations/voice";

    await expect(
      api.startVoiceNumberVerification("wsp_1", { e164: "+15551234567" })
    ).resolves.toEqual({ e164: "+15551234567", status: "pending" });
    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      `${base}/numbers/verify-start`,
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ e164: "+15551234567" }),
      })
    );

    const verified = await api.checkVoiceNumberVerification("wsp_1", {
      e164: "+15551234567",
      code: "123456",
    });
    expect(verified.numbers[0]).toMatchObject({ e164: "+15551234567", pin_set: true });
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      `${base}/numbers/verify-check`,
      expect.objectContaining({
        body: JSON.stringify({ e164: "+15551234567", code: "123456" }),
      })
    );

    await api.setVoiceNumberPin("wsp_1", { e164: "+15551234567", pin: "2468" });
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      `${base}/pin`,
      expect.objectContaining({
        method: "PUT",
        body: JSON.stringify({ e164: "+15551234567", pin: "2468" }),
      })
    );

    // The "+" of an E.164 number must survive the path segment.
    await expect(api.removeVoiceNumber("wsp_1", "+15551234567")).resolves.toMatchObject(
      {
        numbers: [],
      }
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      4,
      `${base}/numbers/%2B15551234567`,
      expect.objectContaining({ method: "DELETE" })
    );

    await expect(
      api.startVoiceNumberVerification("wsp_1", { e164: "+15557654321" })
    ).rejects.toMatchObject({ status: 409, body: { error: "voice_number_in_use" } });
  });

  it("mints workspace connector tokens through Comma API", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        server: "ws://127.0.0.1:4000",
        token: "salix_conn_test",
        name: "Laptop",
        alias: "comma",
      })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(
      api.createConnectorToken("wsp_1", {
        name: "Laptop",
        alias: "comma",
      })
    ).resolves.toEqual({
      server: "ws://127.0.0.1:4000",
      token: "salix_conn_test",
      name: "Laptop",
      alias: "comma",
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/workspaces/wsp_1/connector-token",
      expect.objectContaining({
        method: "POST",
        headers: expect.objectContaining({
          authorization: "Bearer comma_sess_test",
        }),
        body: JSON.stringify({
          name: "Laptop",
          alias: "comma",
        }),
      })
    );
  });

  it("parses authorized SSE conversation events", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          streamText('event: snapshot\ndata: {"type":"snapshot","messages":[]}\n\n'),
          {
            status: 200,
            headers: { "content-type": "text/event-stream" },
          }
        )
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const onEvent = vi.fn();

    await api.streamConversationEvents("grp1_1", "cnv_1", { onEvent });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_1/events",
      expect.objectContaining({
        headers: expect.objectContaining({
          authorization: "Bearer comma_sess_test",
        }),
      })
    );
    expect(onEvent).toHaveBeenCalledWith(
      { type: "snapshot", messages: [] },
      "snapshot"
    );
  });

  it("parses authorized Group task-list invalidations", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          streamText(
            'event: conversation_list_resync_required\ndata: {"type":"conversation_list_resync_required","group_id":"grp1_1","kind":"agent_task","version":"owner-a.1"}\n\nevent: conversation_list_invalidated\ndata: {"type":"conversation_list_invalidated","group_id":"grp1_1","kind":"agent_task","version":"owner-a.2"}\n\n'
          ),
          {
            status: 200,
            headers: { "content-type": "text/event-stream" },
          }
        )
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const onEvent = vi.fn();

    await api.streamConversationListEvents("grp1_1", {
      waitMs: 25_000,
      onEvent,
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/events?wait=25000",
      expect.objectContaining({
        headers: expect.objectContaining({
          authorization: "Bearer comma_sess_test",
        }),
      })
    );
    expect(onEvent).toHaveBeenNthCalledWith(1, {
      type: "conversation_list_resync_required",
      group_id: "grp1_1",
      kind: "agent_task",
      version: "owner-a.1",
    });
    expect(onEvent).toHaveBeenNthCalledWith(2, {
      type: "conversation_list_invalidated",
      group_id: "grp1_1",
      kind: "agent_task",
      version: "owner-a.2",
    });
  });

  it("passes SSE wait windows and ignores heartbeat comments", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          streamText(
            [
              ": heartbeat",
              "",
              "event: message_draft_started",
              'data: {"type":"message_draft_started","conversation_id":"cnv_1","draft_id":"draft_1","response_key":"rsp_1","revision":0,"source_message_ids":["msg_1"],"status":"started","text":"Hel"}',
              "",
              "event: message_draft_delta",
              'data: {"type":"message_draft_delta","conversation_id":"cnv_1","delta":"lo","draft_id":"draft_1","response_key":"rsp_1","revision":1,"source_message_ids":["msg_1"],"status":"delta","text":"Hello"}',
              "",
              "",
            ].join("\n")
          ),
          {
            status: 200,
            headers: { "content-type": "text/event-stream" },
          }
        )
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const onEvent = vi.fn();

    await api.streamConversationEvents("grp1_1", "cnv_1", {
      waitMs: 25_000,
      onEvent,
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp1_1/conversations/cnv_1/events?wait=25000",
      expect.any(Object)
    );
    expect(onEvent).toHaveBeenCalledTimes(2);
    expect(onEvent).toHaveBeenNthCalledWith(
      1,
      {
        type: "message_draft_started",
        conversation_id: "cnv_1",
        draft_id: "draft_1",
        response_key: "rsp_1",
        revision: 0,
        source_message_ids: ["msg_1"],
        status: "started",
        text: "Hel",
      },
      "message_draft_started"
    );
    expect(onEvent).toHaveBeenNthCalledWith(
      2,
      {
        type: "message_draft_delta",
        conversation_id: "cnv_1",
        delta: "lo",
        draft_id: "draft_1",
        response_key: "rsp_1",
        revision: 1,
        source_message_ids: ["msg_1"],
        status: "delta",
        text: "Hello",
      },
      "message_draft_delta"
    );
  });

  it("parses Comma activity SSE frames through the conversation event schema", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          streamText(
            [
              "event: activity",
              'data: {"type":"activity","conversation_id":"cnv_1","phase":"thinking","producer_epoch":"epoch-a","response_key":"rsp_activity","sequence":7,"source_message_ids":["msg_1"],"status":"running","summary":"Checking","summary_class":"public"}',
              "",
              "",
            ].join("\n")
          ),
          {
            status: 200,
            headers: { "content-type": "text/event-stream" },
          }
        )
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });
    const onEvent = vi.fn();

    await api.streamConversationEvents("grp1_1", "cnv_1", { onEvent });

    expect(onEvent).toHaveBeenCalledWith(
      {
        type: "activity",
        conversation_id: "cnv_1",
        phase: "thinking",
        producer_epoch: "epoch-a",
        response_key: "rsp_activity",
        sequence: 7,
        source_message_ids: ["msg_1"],
        status: "running",
        summary: "Checking",
        summary_class: "public",
      },
      "activity"
    );
  });

  it("rejects incomplete and duplicate-source Activity v2 frames", async () => {
    const incompleteFetch = vi.fn(
      async () =>
        new Response(
          streamText(
            [
              "event: activity",
              'data: {"type":"activity","conversation_id":"cnv_1","producer_epoch":"epoch-a","status":"running"}',
              "",
              "",
            ].join("\n")
          ),
          {
            status: 200,
            headers: { "content-type": "text/event-stream" },
          }
        )
    );

    const duplicateSourceFetch = vi.fn(
      async () =>
        new Response(
          streamText(
            [
              "event: activity",
              'data: {"type":"activity","conversation_id":"cnv_1","producer_epoch":"epoch-a","response_key":"rsp_activity","sequence":8,"source_message_ids":["msg_1","msg_1"],"status":"running","summary_class":"generic"}',
              "",
              "",
            ].join("\n")
          ),
          {
            status: 200,
            headers: { "content-type": "text/event-stream" },
          }
        )
    );

    await expect(
      createCommaApi({
        baseUrl: "http://127.0.0.1:4200",
        token: "comma_sess_test",
        fetch: incompleteFetch,
      }).streamConversationEvents("wsp_1", "cnv_1", { onEvent: vi.fn() })
    ).rejects.toThrow("Activity v2 requires response_key");

    await expect(
      createCommaApi({
        baseUrl: "http://127.0.0.1:4200",
        token: "comma_sess_test",
        fetch: duplicateSourceFetch,
      }).streamConversationEvents("wsp_1", "cnv_1", { onEvent: vi.fn() })
    ).rejects.toThrow("Activity v2 requires source_message_ids");
  });

  it("rejects Activity v2 frames with missing or invalid summary authority", async () => {
    const frame = {
      type: "activity",
      conversation_id: "cnv_1",
      producer_epoch: "epoch-a",
      response_key: "rsp_activity",
      sequence: 9,
      source_message_ids: ["msg_1"],
      phase: "thinking",
      status: "running",
      summary: "Checking",
    };
    const fetchFor = (activity: Record<string, unknown>) =>
      vi.fn(
        async () =>
          new Response(
            streamText(
              ["event: activity", `data: ${JSON.stringify(activity)}`, "", ""].join(
                "\n"
              )
            ),
            { status: 200, headers: { "content-type": "text/event-stream" } }
          )
      );

    await expect(
      createCommaApi({
        baseUrl: "http://127.0.0.1:4200",
        token: "comma_sess_test",
        fetch: fetchFor(frame),
      }).streamConversationEvents("wsp_1", "cnv_1", { onEvent: vi.fn() })
    ).rejects.toThrow("Activity v2 requires summary_class");

    await expect(
      createCommaApi({
        baseUrl: "http://127.0.0.1:4200",
        token: "comma_sess_test",
        fetch: fetchFor({ ...frame, summary_class: "private" }),
      }).streamConversationEvents("wsp_1", "cnv_1", { onEvent: vi.fn() })
    ).rejects.toThrow();

    await expect(
      createCommaApi({
        baseUrl: "http://127.0.0.1:4200",
        token: "comma_sess_test",
        fetch: fetchFor({ ...frame, summary_class: "future" }),
      }).streamConversationEvents("wsp_1", "cnv_1", { onEvent: vi.fn() })
    ).rejects.toThrow();
  });

  it("rejects contradictory or unbounded Activity summary authority", async () => {
    const base = {
      type: "activity",
      conversation_id: "cnv_1",
      phase: "thinking",
      producer_epoch: "epoch-a",
      response_key: "rsp_activity",
      sequence: 10,
      source_message_ids: ["msg_1"],
      status: "running",
    };
    const fetchFor = (activity: Record<string, unknown>) =>
      vi.fn(
        async () =>
          new Response(
            streamText(
              ["event: activity", `data: ${JSON.stringify(activity)}`, "", ""].join(
                "\n"
              )
            ),
            { status: 200, headers: { "content-type": "text/event-stream" } }
          )
      );

    for (const activity of [
      {
        ...base,
        action: "PRIVATE_GENERIC_ACTION",
        summary: "PRIVATE_GENERIC_SUMMARY",
        summary_class: "generic",
      },
      {
        ...base,
        status: "failed",
        summary: "PRIVATE_FAILURE_SUMMARY",
        summary_class: "generic",
      },
      {
        ...base,
        summary: "PRIVATE_NONE_SUMMARY",
        summary_class: "none",
      },
      {
        ...base,
        phase: "messaging",
        summary: "Public messaging is not reasoning",
        summary_class: "public",
      },
      {
        ...base,
        status: "failed",
        summary: "Public platform failure is not a tool step",
        summary_class: "public",
      },
      { ...base, summary: " ", summary_class: "public" },
      { ...base, summary: "x".repeat(513), summary_class: "public" },
      {
        ...base,
        goal: "x".repeat(513),
        summary: "Valid summary",
        summary_class: "public",
      },
    ]) {
      await expect(
        createCommaApi({
          baseUrl: "http://127.0.0.1:4200",
          token: "comma_sess_test",
          fetch: fetchFor(activity),
        }).streamConversationEvents("wsp_1", "cnv_1", { onEvent: vi.fn() })
      ).rejects.toThrow("summary_class contradicts phase/status/payload");
    }
  });

  it("accepts a canonical generic platform failure without producer prose", async () => {
    const onEvent = vi.fn();
    const fetchMock = vi.fn(
      async () =>
        new Response(
          streamText(
            [
              "event: activity",
              'data: {"type":"activity","conversation_id":"cnv_1","phase":"thinking","producer_epoch":"epoch-a","response_key":"rsp_activity","sequence":11,"source_message_ids":["msg_1"],"status":"failed","summary_class":"generic"}',
              "",
              "",
            ].join("\n")
          ),
          { status: 200, headers: { "content-type": "text/event-stream" } }
        )
    );

    await createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    }).streamConversationEvents("wsp_1", "cnv_1", { onEvent });

    expect(onEvent).toHaveBeenCalledWith(
      expect.objectContaining({
        phase: "thinking",
        status: "failed",
        summary_class: "generic",
      }),
      "activity"
    );
  });

  it("bounds public Activity prose by Unicode code points", () => {
    const frame = {
      type: "activity",
      conversation_id: "cnv_1",
      phase: "execution",
      producer_epoch: "epoch-a",
      response_key: "rsp_activity",
      sequence: 12,
      source_message_ids: ["msg_1"],
      status: "running",
      summary_class: "public",
    };

    expect(
      commaConversationEventSchema.safeParse({
        ...frame,
        summary: "😀".repeat(512),
      }).success
    ).toBe(true);
    expect(
      commaConversationEventSchema.safeParse({
        ...frame,
        summary: "😀".repeat(513),
      }).success
    ).toBe(false);
    expect(
      commaConversationEventSchema.safeParse({
        ...frame,
        summary: "e\u0301".repeat(256),
      }).success
    ).toBe(true);
    expect(
      commaConversationEventSchema.safeParse({
        ...frame,
        summary: "e\u0301".repeat(257),
      }).success
    ).toBe(false);
  });

  it("multiplexes Task participant snapshots on the existing list stream and rejects foreign/duplicate roles", async () => {
    const participant = {
      actor_id: "actor_worker",
      actor_role: "worker",
      conversation_id: "cnv_1",
      participant_id: "ptc_1",
      name: "Worker",
      state: "active",
      status: "is thinking...",
      updated_at: 1,
    };
    const event = {
      type: "task_participant_statuses",
      group_id: "grp_1",
      conversation_id: "cnv_1",
      participants: [participant],
    };
    const onParticipantStatuses = vi.fn();
    const onEvent = vi.fn();
    const fetchMock = vi.fn(
      async () =>
        new Response(
          `event: task_participant_statuses\ndata: ${JSON.stringify(event)}\n\n`,
          { headers: { "content-type": "text/event-stream" } }
        )
    );
    await createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    }).streamConversationListEvents("grp_1", {
      conversationId: "cnv_1",
      onEvent,
      onParticipantStatuses,
    });
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining("conversation_id=cnv_1"),
      expect.anything()
    );
    expect(onParticipantStatuses).toHaveBeenCalledWith(event);
    expect(onEvent).not.toHaveBeenCalled();
    expect(
      commaTaskParticipantStatusesSchema.safeParse({
        ...event,
        participants: [participant, participant],
      }).success
    ).toBe(false);
    expect(
      commaTaskParticipantStatusesSchema.safeParse({
        ...event,
        participants: [{ ...participant, conversation_id: "other" }],
      }).success
    ).toBe(false);
    expect(
      commaTaskParticipantStatusesSchema.safeParse({
        ...event,
        participants: [1, 2, 3].map((id) => ({
          ...participant,
          participant_id: String(id),
        })),
      }).success
    ).toBe(false);
  });

  it("parses the exact participant display status event", () => {
    expect(
      commaConversationEventSchema.parse({
        type: "participant_status",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        state: "error",
        status: "error: model request failed.",
        updated_at: 1_780_000_000_123,
      })
    ).toMatchObject({
      type: "participant_status",
      conversation_id: "cnv_1",
      participant_id: "ptp_1",
      state: "error",
      status: "error: model request failed.",
      updated_at: 1_780_000_000_123,
    });
  });

  it("rejects malformed Comma API responses", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ data: [{ name: "Missing id" }] })
    );
    const api = createCommaApi({
      baseUrl: "http://127.0.0.1:4200",
      token: "comma_sess_test",
      fetch: fetchMock,
    });

    await expect(api.listWorkspaces()).rejects.toThrow();
  });
});

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function streamText(text: string) {
  return new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(text));
      controller.close();
    },
  });
}
