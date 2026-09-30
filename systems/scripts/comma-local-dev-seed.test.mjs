import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { seedLocalDev } from "./comma-local-dev-seed.mjs";

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("Comma local dev seed", () => {
  it("refuses to mutate a non-loopback API without the explicit danger opt-in", async () => {
    let fetchCalled = false;

    await assert.rejects(
      seedLocalDev({
        apiBaseUrl: "https://api-staging.comma.surf",
        dangerousAllowNonLoopback: "",
        fetchImpl: async () => {
          fetchCalled = true;
          return json(500, { error: "must_not_run" });
        },
      }),
      /Refusing to seed non-loopback API/,
    );

    assert.equal(fetchCalled, false);
  });

  it("does not mistake a hostname beginning with 127 for a loopback IP", async () => {
    await assert.rejects(
      seedLocalDev({
        apiBaseUrl: "https://127.example.test",
        dangerousAllowNonLoopback: "",
        fetchImpl: async () => json(500, { error: "must_not_run" }),
      }),
      /Refusing to seed non-loopback API/,
    );
  });

  it("aborts a stalled API request at the configured deadline", async () => {
    let requestSignal;
    // AbortSignal.timeout() deliberately uses an unref'ed timer. Keep one
    // ordinary handle alive so Node can observe the timeout before deciding
    // that this isolated test process has no remaining work.
    const keepAlive = setTimeout(() => {}, 1_000);

    try {
      await assert.rejects(
        seedLocalDev({
          requestTimeoutMs: 5,
          fetchImpl: async (_url, init) => {
            requestSignal = init.signal;

            return new Promise((_resolve, reject) => {
              init.signal.addEventListener(
                "abort",
                () => reject(init.signal.reason),
                { once: true },
              );
            });
          },
        }),
        { name: "TimeoutError" },
      );
    } finally {
      clearTimeout(keepAlive);
    }

    assert.equal(requestSignal.aborted, true);
  });

  it("allows a non-loopback API only with the explicit danger opt-in", async () => {
    const calls = [];
    const fetchImpl = existingSeedFetch(calls);

    const result = await seedLocalDev({
      apiBaseUrl: "https://dev.example.test",
      dangerousAllowNonLoopback: "I_UNDERSTAND_THIS_MUTATES_REMOTE_DATA",
      fetchImpl,
    });

    assert.equal(result.apiBaseUrl, "https://dev.example.test");
    assert.ok(calls.length > 0);
  });

  it("is safe to rerun against an existing user, workspace, code, and grant", async () => {
    const calls = [];
    const fetchImpl = existingSeedFetch(calls);

    const result = await seedLocalDev({ fetchImpl });

    assert.deepEqual(result, {
      apiBaseUrl: "http://127.0.0.1:4200",
      conversationId: "cnv_local",
      email: "comma-local@example.com",
      groupId: "grp1_local_dev",
      mailpitUrl: "http://127.0.0.1:8025",
      sessionToken: "comma_sess_local",
      workspaceId: "wsp_local_dev",
    });
    assert.equal(
      calls.some(
        (call) =>
          call.pathName === "/v1/comma/admin/billing/redeem-codes/apply" &&
          call.body.idempotency_key ===
            "comma-local-dev:wsp_local_dev:credits-v1",
      ),
      true,
    );
    assert.equal(
      calls.some(
        (call) =>
          call.method === "GET" &&
          call.pathName ===
            "/v1/comma/admin/users?limit=1&email=comma-local%40example.com",
      ),
      true,
    );
    assert.deepEqual(
      calls.find(
        (call) =>
          call.method === "POST" &&
          call.pathName === "/v1/comma/admin/users/usr_local/sessions",
      ),
      {
        method: "POST",
        pathName: "/v1/comma/admin/users/usr_local/sessions",
        body: {
          local_dev: true,
          ttl_seconds: 315_360_000,
        },
      },
    );
  });

  for (const { name, options, error } of [
    {
      name: "rejects an invalid local developer Session lifetime before making an API request",
      options: { sessionTtlSeconds: 0 },
      error: /sessionTtlSeconds must be a positive safe integer/,
    },
    {
      name: "rejects an invalid grant generation before making an API request",
      options: { creditGrantGeneration: 0 },
      error: /creditGrantGeneration must be a positive safe integer/,
    },
  ]) {
    it(name, async () => {
      let fetchCalled = false;

      await assert.rejects(
        seedLocalDev({
          ...options,
          fetchImpl: async () => {
            fetchCalled = true;
            return json(500, { error: "must_not_run" });
          },
        }),
        error,
      );

      assert.equal(fetchCalled, false);
    });
  }

  it("uses an explicit grant generation for an idempotent local credit top-up", async () => {
    const calls = [];
    const fetchImpl = existingSeedFetch(calls);

    await seedLocalDev({ creditGrantGeneration: 2, fetchImpl });

    assert.equal(
      calls.some(
        (call) =>
          call.pathName === "/v1/comma/admin/billing/redeem-codes" &&
          call.body.code === "COMMA-LOCAL-DEV-20M-V2",
      ),
      true,
    );
    assert.equal(
      calls.some(
        (call) =>
          call.pathName === "/v1/comma/admin/billing/redeem-codes/apply" &&
          call.body.code === "COMMA-LOCAL-DEV-20M-V2" &&
          call.body.idempotency_key ===
            "comma-local-dev:wsp_local_dev:credits-v2",
      ),
      true,
    );
  });

  it("normalizes surrounding whitespace and case without collapsing plus addressing", async () => {
    const calls = [];
    const fetchImpl = existingSeedFetch(calls, {
      email: "peng+comma@gmail.com",
    });

    const result = await seedLocalDev({
      email: " Peng+Comma@Gmail.com ",
      fetchImpl,
    });

    assert.equal(result.email, "peng+comma@gmail.com");
    assert.equal(
      calls.some(
        (call) =>
          call.method === "GET" &&
          call.pathName ===
            "/v1/comma/admin/users?limit=1&email=peng%2Bcomma%40gmail.com",
      ),
      true,
    );
    assert.equal(
      calls.some(
        (call) => call.method === "POST" && call.pathName === "/v1/comma/admin/users",
      ),
      false,
    );
  });

  it("prefers an explicitly requested workspace id over an earlier name match", async () => {
    const calls = [];
    const fetchImpl = existingSeedFetch(calls, {
      conversationGroupId: "grp1_target",
      workspaces: [
        {
          id: "wsp_name_match",
          name: "Comma Local Dev",
          billing_account_id: "example-ba-wsp_name_match",
          group_id: "grp1_name_match",
        },
        {
          id: "wsp_target",
          name: "Existing target",
          billing_account_id: "example-ba-wsp_target",
          group_id: "grp1_target",
        },
      ],
    });

    const result = await seedLocalDev({ fetchImpl, workspaceId: "wsp_target" });

    assert.equal(result.workspaceId, "wsp_target");
    assert.equal(
      calls.some(
        (call) =>
          call.pathName === "/v1/comma/admin/billing/redeem-codes/apply" &&
          call.body.billing_account_id === "example-ba-wsp_target" &&
          call.body.idempotency_key === "comma-local-dev:wsp_target:credits-v1",
      ),
      true,
    );
  });

  it("does not silently fall back by name when an explicit workspace id is missing", async () => {
    const calls = [];
    const target = {
      id: "wsp_target",
      name: "Comma Local Dev",
      billing_account_id: "example-ba-wsp_target",
      group_id: "grp1_target",
    };
    let workspaceReads = 0;
    const fetchImpl = existingSeedFetch(calls, {
      bootstrapWorkspaceId: target.id,
      conversationGroupId: target.group_id,
      workspaces: () => {
        workspaceReads += 1;
        return workspaceReads === 1
          ? [
              {
                id: "wsp_name_match",
                name: "Comma Local Dev",
                billing_account_id: "example-ba-wsp_name_match",
                group_id: "grp1_name_match",
              },
            ]
          : [target];
      },
    });

    const result = await seedLocalDev({ fetchImpl, workspaceId: target.id });

    assert.equal(result.workspaceId, target.id);
    assert.equal(
      calls.some(
        (call) =>
          call.method === "POST" && call.pathName === "/v1/comma/me/bootstrap",
      ),
      true,
    );
    assert.equal(
      calls.some((call) =>
        /^\/v1\/comma\/admin\/users\/[^/]+\/workspaces$/.test(call.pathName),
      ),
      false,
    );
  });

  it("rejects a different default workspace when an explicit workspace id is requested", async () => {
    const calls = [];
    const fetchImpl = existingSeedFetch(calls, {
      bootstrapWorkspaceId: "wsp_other",
      workspaces: [
        {
          id: "wsp_name_match",
          name: "Comma Local Dev",
          billing_account_id: "example-ba-wsp_name_match",
          group_id: "grp1_name_match",
        },
      ],
    });

    await assert.rejects(
      seedLocalDev({ fetchImpl, workspaceId: "wsp_target" }),
      /Requested local workspace wsp_target is not the user's default workspace wsp_other/,
    );

    assert.equal(
      calls.some(
        (call) =>
          call.method === "PATCH" &&
          call.pathName === "/v1/comma/workspaces/wsp_other",
      ),
      false,
    );
  });

  it("bootstraps a missing workspace through the user session and waits for readiness", async () => {
    const calls = [];
    let workspaceReads = 0;
    let bootstrapCalls = 0;

    const fetchImpl = async (url, init) => {
      const parsedUrl = new URL(url);
      const pathName = parsedUrl.pathname + parsedUrl.search;
      const method = init.method;
      const body = init.body ? JSON.parse(init.body) : null;
      calls.push({ method, pathName, body });

      if (
        method === "GET" &&
        pathName === "/v1/comma/admin/users?limit=1&email=comma-local%40example.com"
      ) {
        return json(200, {
          data: [{ id: "usr_bootstrap", email: "comma-local@example.com" }],
        });
      }
      if (
        method === "POST" &&
        pathName === "/v1/comma/admin/users/usr_bootstrap/sessions"
      ) {
        return json(201, { token: "comma_sess_bootstrap" });
      }
      if (method === "GET" && pathName === "/v1/comma/workspaces") {
        workspaceReads += 1;
        return json(200, {
          data:
            workspaceReads === 1
              ? []
              : [
                  {
                    id: "wsp_bootstrap",
                    name: "Comma Local Dev",
                    billing_account_id: "example-ba-wsp_bootstrap",
                    group_id: "grp1_bootstrap",
                  },
                ],
        });
      }
      if (method === "POST" && pathName === "/v1/comma/me/bootstrap") {
        bootstrapCalls += 1;
        return bootstrapCalls === 1
          ? json(202, {
              status: "provisioning",
              workspace: { id: "wsp_bootstrap" },
            })
          : json(200, {
              status: "ready",
              workspace: { id: "wsp_bootstrap", group_id: "grp1_bootstrap" },
            });
      }
      if (method === "PATCH" && pathName === "/v1/comma/workspaces/wsp_bootstrap") {
        return json(200, { id: "wsp_bootstrap", name: body.name });
      }
      if (
        method === "GET" &&
        pathName === "/v1/comma/admin/billing/package-versions?surface=comma"
      ) {
        return json(200, {
          data: [{ package_code: "comma_addon_20m", version: "2026-06" }],
        });
      }
      if (method === "POST" && pathName === "/v1/comma/admin/billing/redeem-codes") {
        return json(400, { error: "redeem_code_exists" });
      }
      if (
        method === "POST" &&
        pathName === "/v1/comma/admin/billing/redeem-codes/apply"
      ) {
        return json(409, { error: "redeem_code_account_limit_reached" });
      }
      if (
        method === "POST" &&
        pathName === "/v1/comma/groups/grp1_bootstrap/assistant-chat"
      ) {
        return json(200, { id: "cnv_bootstrap" });
      }

      return json(500, { error: `unexpected ${method} ${pathName}` });
    };

    const result = await seedLocalDev({
      fetchImpl,
      bootstrapMaxAttempts: 3,
      bootstrapPollMs: 0,
      sleepImpl: async () => {},
    });

    assert.equal(result.workspaceId, "wsp_bootstrap");
    assert.equal(result.groupId, "grp1_bootstrap");
    assert.equal(result.conversationId, "cnv_bootstrap");
    assert.equal(bootstrapCalls, 2);
    assert.equal(
      calls.some((call) =>
        /^\/v1\/comma\/admin\/users\/[^/]+\/workspaces$/.test(call.pathName),
      ),
      false,
    );
  });

  it("stops polling when workspace bootstrap reaches the configured bound", async () => {
    let bootstrapCalls = 0;
    let sleeps = 0;

    const fetchImpl = async (url, init) => {
      const parsedUrl = new URL(url);
      const pathName = parsedUrl.pathname + parsedUrl.search;

      if (
        init.method === "GET" &&
        pathName === "/v1/comma/admin/users?limit=1&email=comma-local%40example.com"
      ) {
        return json(200, {
          data: [{ id: "usr_timeout", email: "comma-local@example.com" }],
        });
      }
      if (
        init.method === "POST" &&
        pathName === "/v1/comma/admin/users/usr_timeout/sessions"
      ) {
        return json(201, { token: "comma_sess_timeout" });
      }
      if (init.method === "GET" && pathName === "/v1/comma/workspaces") {
        return json(200, { data: [] });
      }
      if (init.method === "POST" && pathName === "/v1/comma/me/bootstrap") {
        bootstrapCalls += 1;
        return json(202, {
          status: "provisioning",
          workspace: { id: "wsp_timeout" },
        });
      }

      return json(500, { error: `unexpected ${init.method} ${pathName}` });
    };

    await assert.rejects(
      seedLocalDev({
        fetchImpl,
        bootstrapMaxAttempts: 2,
        bootstrapPollMs: 0,
        sleepImpl: async () => {
          sleeps += 1;
        },
      }),
      /Timed out waiting for Comma workspace bootstrap/,
    );

    assert.equal(bootstrapCalls, 2);
    assert.equal(sleeps, 1);
  });
});

function existingSeedFetch(calls, options = {}) {
  const { email = "comma-local@example.com" } = options;
  const configuredWorkspaces = options.workspaces || [
    {
      id: "wsp_local_dev",
      name: "Comma Local Dev",
      billing_account_id: "example-ba-wsp_local_dev",
      group_id: "grp1_local_dev",
    },
  ];
  const conversationGroupId = options.conversationGroupId || "grp1_local_dev";

  return async (url, init) => {
    const pathName = new URL(url).pathname + new URL(url).search;
    const method = init.method;
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ method, pathName, body });

    if (
      method === "GET" &&
      pathName === `/v1/comma/admin/users?limit=1&email=${encodeURIComponent(email)}`
    ) {
      return json(200, {
        data: [{ id: "usr_local", email }],
      });
    }
    if (
      method === "POST" &&
      pathName === "/v1/comma/admin/users/usr_local/sessions"
    ) {
      return json(201, { token: "comma_sess_local" });
    }
    if (method === "GET" && pathName === "/v1/comma/workspaces") {
      const workspaces =
        typeof configuredWorkspaces === "function"
          ? configuredWorkspaces()
          : configuredWorkspaces;
      return json(200, { data: workspaces });
    }
    if (method === "POST" && pathName === "/v1/comma/me/bootstrap") {
      return json(200, {
        status: "ready",
        workspace: {
          id: options.bootstrapWorkspaceId,
          group_id: options.bootstrapGroupId || conversationGroupId,
        },
      });
    }
    if (
      method === "PATCH" &&
      pathName === `/v1/comma/workspaces/${options.bootstrapWorkspaceId}`
    ) {
      return json(200, {
        id: options.bootstrapWorkspaceId,
        name: body.name,
      });
    }
    if (
      method === "GET" &&
      pathName === "/v1/comma/admin/billing/package-versions?surface=comma"
    ) {
      return json(200, {
        data: [{ package_code: "comma_addon_20m", version: "2026-06" }],
      });
    }
    if (method === "POST" && pathName === "/v1/comma/admin/billing/redeem-codes") {
      return json(400, { error: "redeem_code_exists" });
    }
    if (
      method === "POST" &&
      pathName === "/v1/comma/admin/billing/redeem-codes/apply"
    ) {
      return json(409, { error: "redeem_code_account_limit_reached" });
    }
    if (
      method === "POST" &&
      pathName === `/v1/comma/groups/${conversationGroupId}/assistant-chat`
    ) {
      return json(200, { id: "cnv_local" });
    }

    return json(500, { error: `unexpected ${method} ${pathName}` });
  };
}
