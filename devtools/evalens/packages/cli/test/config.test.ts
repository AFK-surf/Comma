import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import {
  EvalensConfigSchema,
  loadEvalensConfig,
  resolveRunRetryOptions,
} from "@evalens/cli/config";

describe("Evalens config", () => {
  test("loads local outputDir relative to the config file and defaults concurrency", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-config-"));
    try {
      const configPath = path.join(directory, "config", "evalens.config.json");
      await mkdir(path.dirname(configPath), { recursive: true });
      await Bun.write(configPath, JSON.stringify({ local: { outputDir: "../runs" } }));
      expect(await loadEvalensConfig(configPath)).toEqual({
        adapters: {},
        concurrency: 1,
        local: { outputDir: path.join(directory, "runs") },
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("parses built-in adapter config and rejects unknown adapters", () => {
    expect(
      EvalensConfigSchema.parse({
        local: { outputDir: "runs" },
        adapters: {
          salix: {
            baseUrl: "https://salix.example.com",
            token: "secret",
            templateId: "tmpl-evalens",
          },
        },
      }).adapters
    ).toEqual({
      salix: {
        baseUrl: "https://salix.example.com",
        token: "secret",
        tenantId: "evalens",
        templateId: "tmpl-evalens",
      },
    });
    expect(() =>
      EvalensConfigSchema.parse({
        local: { outputDir: "runs" },
        adapters: { custom: {} },
      })
    ).toThrow();
    expect(() =>
      EvalensConfigSchema.parse({
        local: { outputDir: "runs" },
        adapters: {
          salix: {
            baseUrl: "https://salix.example.com",
            token: "tenant-token",
            adminToken: "must-not-be-accepted",
          },
        },
      })
    ).toThrow();
  });

  test("requires credentials to be literal values in the selected config", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-config-local-"));
    try {
      const configPath = path.join(directory, "evalens.config.json");
      await Bun.write(
        configPath,
        JSON.stringify({
          adapters: {
            salix: {
              baseUrl: "https://salix.example.com",
              token: { $env: "EVALENS_SALIX_TOKEN" },
            },
          },
          local: { outputDir: "runs" },
        })
      );

      await expect(loadEvalensConfig(configPath)).rejects.toThrow("expected string");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("only exposes the run retry count and resolves internal backoff defaults", () => {
    const retry = EvalensConfigSchema.parse({
      local: { outputDir: "runs" },
      retry: { maxRetries: 7 },
    }).retry;
    expect(retry).toEqual({ maxRetries: 7 });
    expect(resolveRunRetryOptions(retry)).toEqual({
      maxRetries: 7,
      initialDelayMs: 5_000,
      maxDelayMs: 60_000,
      multiplier: 2,
    });
    expect(() =>
      EvalensConfigSchema.parse({
        local: { outputDir: "runs" },
        retry: { maxRetries: 7, multiplier: 3 },
      })
    ).toThrow();
  });

  test("parses structured Codex auth JSON", () => {
    const authJson = {
      auth_mode: "chatgpt",
      OPENAI_API_KEY: null,
      tokens: {
        access_token: "access-token",
        refresh_token: "refresh-token",
        account_id: "account-id",
      },
      last_refresh: "2026-07-13T00:00:00Z",
    };

    const parsed = EvalensConfigSchema.parse({
      local: { outputDir: "runs" },
      adapters: { codex: { authJson } },
    });
    expect(parsed.adapters?.codex).toEqual({
      command: "codex",
      authJson,
      env: {},
      sandbox: "workspace-write",
      approvalPolicy: "never",
      skipGitRepoCheck: true,
    });
    expect(
      EvalensConfigSchema.safeParse({
        local: { outputDir: "runs" },
        adapters: { codex: { authJson: "not-an-object" } },
      }).success
    ).toBe(false);
  });

  test("parses Slack driver safety boundaries and polling defaults", () => {
    const parsed = EvalensConfigSchema.parse({
      local: { outputDir: "runs" },
      adapters: {
        slack: {
          token: "xoxp-eval-driver",
          workspaceId: "T_EVAL",
          allowedChannelIds: ["C_EVAL"],
          expectedUserId: "U_DRIVER",
          otherAppDriver: {
            token: "xoxb-eval-driver",
            expectedBotUserId: "U_OTHER_APP_BOT",
          },
        },
      },
    });

    expect(parsed.adapters?.slack).toEqual({
      token: "xoxp-eval-driver",
      workspaceId: "T_EVAL",
      allowedChannelIds: ["C_EVAL"],
      expectedUserId: "U_DRIVER",
      pollMs: 1_000,
      otherAppDriver: {
        token: "xoxb-eval-driver",
        expectedBotUserId: "U_OTHER_APP_BOT",
      },
    });
  });

  test("parses provider-neutral Salix integration fixtures", () => {
    const parsed = EvalensConfigSchema.parse({
      local: { outputDir: "runs" },
      adapters: {
        salix: {
          baseUrl: "https://salix.example.com",
          integrations: [
            {
              id: "slack",
              provider: "slack",
              credentials: {
                type: "app",
                appId: "A_EVAL",
                clientId: "client",
                clientSecret: "secret",
                signingSecret: "signing",
                botToken: "xoxb-eval",
              },
            },
            {
              id: "github",
              provider: "GITHUB",
              alias: "github",
              credentials: { type: "oauth", accessToken: "token" },
              scopes: ["repo"],
              plugin: {
                pluginId: "github",
                connectionId: "github-managed",
              },
            },
            {
              id: "notion",
              provider: "notion",
              alias: "notion",
              credentials: { type: "oauth", accessToken: "token" },
              plugin: {
                pluginId: "notion",
                connectionId: "notion-native",
              },
            },
          ],
        },
      },
    });

    expect(parsed.adapters?.salix?.integrations?.map((item) => item.provider)).toEqual([
      "slack",
      "github",
      "notion",
    ]);
    expect(
      EvalensConfigSchema.safeParse({
        local: { outputDir: "runs" },
        adapters: {
          salix: {
            baseUrl: "https://salix.example.com",
            integrations: [
              {
                id: "same",
                provider: "github",
                alias: "github",
                credentials: { type: "oauth", accessToken: "one" },
              },
              {
                id: "same",
                provider: "linear",
                alias: "linear",
                credentials: { type: "oauth", accessToken: "two" },
              },
            ],
          },
        },
      }).success
    ).toBe(false);
  });

  test("requires exactly one strict target", () => {
    const remote = {
      url: "https://evalens.example.com",
      access: { clientId: "client", clientSecret: "secret" },
      r2: {
        accountId: "account",
        bucket: "evalens-results",
        accessKeyId: "key",
        secretAccessKey: "secret",
      },
    };
    expect(
      EvalensConfigSchema.safeParse({ local: { outputDir: "runs" } }).success
    ).toBe(true);
    expect(EvalensConfigSchema.safeParse({ remote }).success).toBe(true);
    expect(EvalensConfigSchema.safeParse({}).success).toBe(false);
    expect(
      EvalensConfigSchema.safeParse({ local: { outputDir: "runs" }, remote }).success
    ).toBe(false);
    expect(
      EvalensConfigSchema.safeParse({ remote: { ...remote, unknown: true } }).success
    ).toBe(false);
  });
});
