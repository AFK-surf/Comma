import { createCommaApi, type CommaApiSessionTransport } from "@comma/app";
import { describe, expect, it, vi } from "vitest";

describe("Comma API host Session transport", () => {
  it.each([
    {
      label: "JSON",
      response: { data: [] },
      run: (api: ReturnType<typeof createCommaApi>) => api.listWorkspaces(),
    },
    {
      label: "upload",
      response: { name: "note.txt", path: "files/note.txt", size: 4 },
      run: (api: ReturnType<typeof createCommaApi>) =>
        api.uploadGroupFile("group-1", {
          data: new Blob(["test"]),
          name: "note.txt",
        }),
    },
  ])("applies the exact lifecycle lease to every $label request", async (testCase) => {
    const fetchMock = vi.fn(async () => jsonResponse(testCase.response));
    const transport = webTransport();
    const api = createCommaApi({
      baseUrl: "https://api.example",
      fetch: fetchMock,
      sessionTransport: transport,
      token: "",
    });

    await testCase.run(api);

    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining("/v1/"),
      expect.objectContaining({
        credentials: "include",
        headers: expect.objectContaining({
          "x-comma-expected-auth-session-id": "11111111-1111-4111-8111-111111111111",
          "x-comma-session-lifecycle-version": "1",
          "x-comma-session-transport": "cookie",
        }),
        signal: transport.signal,
      })
    );
  });

  it("applies the exact lifecycle lease and rejection report to SSE", async () => {
    const reportSessionRejection = vi.fn();
    const transport = webTransport(reportSessionRejection);
    const fetchMock = vi.fn(async () => jsonResponse({ error: "unauthorized" }, 401));
    const api = createCommaApi({
      baseUrl: "https://api.example",
      fetch: fetchMock,
      sessionTransport: transport,
      token: "",
    });

    await expect(
      api.streamConversationEvents("group-1", "conversation-1", {
        onEvent: () => {},
      })
    ).rejects.toMatchObject({ status: 401 });

    expect(fetchMock).toHaveBeenCalledWith(
      "https://api.example/v1/comma/groups/group-1/conversations/conversation-1/events",
      expect.objectContaining({
        credentials: "include",
        headers: expect.objectContaining({
          "x-comma-expected-auth-session-id": "11111111-1111-4111-8111-111111111111",
          "x-comma-session-lifecycle-version": "1",
          "x-comma-session-transport": "cookie",
        }),
        signal: transport.signal,
      })
    );
    expect(reportSessionRejection).toHaveBeenCalledOnce();
    expect(reportSessionRejection).toHaveBeenCalledWith(401);
  });

  it.each([
    {
      body: { error: "session_changed" },
      label: "server session_changed",
    },
    {
      body: localSessionLeaseUnavailable(),
      label: "Main lease unavailable",
    },
  ])(
    "reports an exact $label JSON 409 to the credential-owning transport",
    async ({ body }) => {
      const reportSessionRejection = vi.fn();
      const api = createCommaApi({
        baseUrl: "https://api.example",
        fetch: vi.fn(async () => jsonResponse(body, 409)),
        sessionTransport: webTransport(reportSessionRejection),
        token: "",
      });

      await expect(api.listWorkspaces()).rejects.toMatchObject({ status: 409 });
      expect(reportSessionRejection).toHaveBeenCalledWith(409);
    }
  );

  it("preserves the Session transport for an ordinary business JSON 409", async () => {
    const reportSessionRejection = vi.fn();
    const api = createCommaApi({
      baseUrl: "https://api.example",
      fetch: vi.fn(async () => jsonResponse({ error: "exists" }, 409)),
      sessionTransport: webTransport(reportSessionRejection),
      token: "",
    });

    await expect(api.listWorkspaces()).rejects.toMatchObject({
      body: { error: "exists" },
      status: 409,
    });
    expect(reportSessionRejection).not.toHaveBeenCalled();
  });

  it.each([
    {
      body: { error: "session_changed" },
      expectedReports: 1,
      label: "exact session_changed",
    },
    {
      body: localSessionLeaseUnavailable(),
      expectedReports: 1,
      label: "exact Main lease-unavailable",
    },
    {
      body: { error: "conflict" },
      expectedReports: 0,
      label: "ordinary business conflict",
    },
  ])(
    "classifies an SSE $label 409 without broad status inference",
    async ({ body, expectedReports }) => {
      const reportSessionRejection = vi.fn();
      const api = createCommaApi({
        baseUrl: "https://api.example",
        fetch: vi.fn(async () => jsonResponse(body, 409)),
        sessionTransport: webTransport(reportSessionRejection),
        token: "",
      });

      await expect(
        api.streamConversationEvents("workspace-1", "conversation-1", {
          onEvent: () => {},
        })
      ).rejects.toMatchObject({ status: 409 });
      expect(reportSessionRejection).toHaveBeenCalledTimes(expectedReports);
      if (expectedReports > 0) {
        expect(reportSessionRejection).toHaveBeenCalledWith(409);
      }
    }
  );

  it("rejects a renderer bearer combined with a host Session transport", () => {
    expect(() =>
      createCommaApi({
        baseUrl: "https://api.example",
        sessionTransport: webTransport(),
        token: "must-not-enter-renderer",
      })
    ).toThrow(/cannot be used together/);
  });
});

function webTransport(
  reportSessionRejection: (status: 401 | 409) => void = () => {}
): CommaApiSessionTransport {
  return {
    credentials: "include",
    signal: new AbortController().signal,
    applyHeaders(headers) {
      headers["x-comma-expected-auth-session-id"] =
        "11111111-1111-4111-8111-111111111111";
      headers["x-comma-session-lifecycle-version"] = "1";
      headers["x-comma-session-transport"] = "cookie";
    },
    reportSessionRejection,
  };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}

function localSessionLeaseUnavailable() {
  return {
    error: {
      code: "session_product_lease_unavailable",
      recovery: {
        authorityInstanceId: "authority-1",
        generation: 2,
        revision: 3,
      },
    },
  };
}
