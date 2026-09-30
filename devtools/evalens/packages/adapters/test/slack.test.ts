import { describe, expect, test } from "bun:test";

import {
  createSlackEvaluationTools,
  SlackDriver,
  SlackFixtureCleaner,
  SlackObserver,
  type SlackWebClient,
} from "../src/slack";

const config = {
  token: "xoxp-test",
  workspaceId: "T_EVAL",
  allowedChannelIds: ["C_EVAL"],
  pollMs: 100,
};

function client(overrides: Partial<SlackWebClient> = {}): SlackWebClient {
  return {
    auth: {
      test: async () => ({ ok: true, team_id: "T_EVAL", user_id: "U_DRIVER" }),
    },
    chat: {
      postMessage: async ({ channel }) => ({
        ok: true,
        channel,
        ts: "100.000001",
      }),
    },
    conversations: {
      replies: async () => ({ ok: true, messages: [] }),
    },
    ...overrides,
  };
}

describe("Slack evaluation boundaries", () => {
  test("creates explicit driver, observer, and fixture-cleaner boundaries", () => {
    const tools = createSlackEvaluationTools(config, client());
    expect(tools.driver).toBeInstanceOf(SlackDriver);
    expect(tools.observer).toBeInstanceOf(SlackObserver);
    expect(tools.fixtureCleaner).toBeInstanceOf(SlackFixtureCleaner);
  });

  test("requires the configured user identity and accepts Slack app attribution", async () => {
    const valid = new SlackDriver(config, client());
    expect(await valid.preflight()).toEqual({
      workspaceId: "T_EVAL",
      userId: "U_DRIVER",
    });

    const appAttributedUser = new SlackDriver(
      config,
      client({
        auth: {
          test: async () => ({
            ok: true,
            team_id: "T_EVAL",
            user_id: "U_BOT",
            bot_id: "B_BOT",
          }),
        },
      })
    );
    expect(await appAttributedUser.preflight()).toEqual({
      workspaceId: "T_EVAL",
      userId: "U_BOT",
      botId: "B_BOT",
    });
  });

  test("posts a real Slack mention only in an allowed channel", async () => {
    const calls: unknown[] = [];
    const driver = new SlackDriver(
      config,
      client({
        chat: {
          postMessage: async (input) => {
            calls.push(input);
            return { ok: true, channel: input.channel, ts: "100.000001" };
          },
        },
      })
    );

    expect(
      await driver.postMention({
        channelId: "C_EVAL",
        botUserId: "U_EVALENS",
        text: "do the task",
      })
    ).toEqual({
      channelId: "C_EVAL",
      ts: "100.000001",
      text: "<@U_EVALENS> do the task",
    });
    expect(calls).toEqual([{ channel: "C_EVAL", text: "<@U_EVALENS> do the task" }]);

    await expect(
      driver.postMention({
        channelId: "C_OTHER",
        botUserId: "U_EVALENS",
        text: "do the task",
      })
    ).rejects.toThrow("not allowed");
  });

  test("polls the thread and returns only replies from the Salix bot", async () => {
    let time = 0;
    let reads = 0;
    const observer = new SlackObserver(
      config,
      client({
        conversations: {
          replies: async () => {
            reads += 1;
            return {
              ok: true,
              messages:
                reads === 1
                  ? [{ ts: "100.000001", user: "U_DRIVER", text: "trigger" }]
                  : [
                      { ts: "100.000001", user: "U_DRIVER", text: "trigger" },
                      {
                        ts: "101.000001",
                        thread_ts: "100.000001",
                        user: "U_OTHER",
                        text: "noise",
                      },
                      {
                        ts: "102.000001",
                        thread_ts: "100.000001",
                        user: "U_EVALENS",
                        bot_id: "B_EVALENS",
                        text: "done",
                      },
                    ],
            };
          },
        },
      }),
      () => new Date(time),
      () => time,
      async (durationMs) => {
        time += durationMs;
      }
    );

    const observed = await observer.waitForBotReplies({
      channelId: "C_EVAL",
      threadTs: "100.000001",
      botUserId: "U_EVALENS",
      timeoutMs: 1_000,
      settleMs: 100,
    });

    expect(observed).toEqual({
      channelId: "C_EVAL",
      threadTs: "100.000001",
      botUserId: "U_EVALENS",
      elapsedMs: 200,
      timedOut: false,
      messages: [
        {
          ts: "102.000001",
          threadTs: "100.000001",
          userId: "U_EVALENS",
          botId: "B_EVALENS",
          text: "done",
          files: [],
          reactions: [],
        },
      ],
    });
  });

  test("performs a final provider read at the reply timeout boundary", async () => {
    let time = 0;
    let reads = 0;
    const observer = new SlackObserver(
      config,
      client({
        conversations: {
          replies: async () => {
            reads += 1;
            return {
              ok: true,
              messages: [
                { ts: "100.000001", user: "U_DRIVER", text: "trigger" },
                ...(time >= 100
                  ? [
                      {
                        ts: "101.000001",
                        thread_ts: "100.000001",
                        user: "U_EVALENS",
                        text: "late reply",
                      },
                    ]
                  : []),
              ],
            };
          },
        },
      }),
      () => new Date(time),
      () => time,
      async (durationMs) => {
        time += durationMs;
      }
    );

    const observed = await observer.waitForBotReplies({
      channelId: "C_EVAL",
      threadTs: "100.000001",
      botUserId: "U_EVALENS",
      timeoutMs: 100,
      pollMs: 60,
      settleMs: 100,
    });

    expect(reads).toBe(3);
    expect(observed.timedOut).toBe(true);
    expect(observed.messages.map((message) => message.text)).toEqual(["late reply"]);
  });

  test("rejects malformed Slack messages instead of filling missing fields", async () => {
    const observer = new SlackObserver(
      config,
      client({
        conversations: {
          replies: async () => ({
            ok: true,
            messages: [{ text: "message without a timestamp" }],
          }),
        },
      })
    );

    await expect(
      observer.readThread({ channelId: "C_EVAL", threadTs: "100.000001" })
    ).rejects.toThrow("Slack message is malformed");
  });

  test("rejects a successful thread response without a messages collection", async () => {
    const observer = new SlackObserver(
      config,
      client({
        conversations: {
          replies: async () => ({ ok: true }),
        },
      })
    );

    await expect(
      observer.readThread({ channelId: "C_EVAL", threadTs: "100.000001" })
    ).rejects.toThrow();
  });

  test("reads the uploaded file from the SDK uploadV2 completion batch", async () => {
    const driver = new SlackDriver(
      config,
      client({
        files: {
          uploadV2: async () => ({
            ok: true,
            files: [
              {
                ok: true,
                files: [
                  {
                    id: "F_EVAL",
                    permalink: "https://example.slack.com/files/F_EVAL",
                  },
                ],
              },
            ],
          }),
        },
      })
    );

    expect(
      await driver.uploadTextFile({
        channelId: "C_EVAL",
        filename: "fixture.txt",
        content: "fixture",
      })
    ).toEqual({
      fileId: "F_EVAL",
      permalink: "https://example.slack.com/files/F_EVAL",
    });
  });

  test("requires the target bot to be in the evaluation channel", async () => {
    const member = new SlackObserver(
      config,
      client({
        conversations: {
          replies: async () => ({ ok: true, messages: [] }),
          info: async () => ({ ok: true, channel: { is_member: true } }),
        },
      })
    );
    await expect(member.assertChannelMember("C_EVAL")).resolves.toBeUndefined();

    const absent = new SlackObserver(
      config,
      client({
        conversations: {
          replies: async () => ({ ok: true, messages: [] }),
          info: async () => ({ ok: true, channel: { is_member: false } }),
        },
      })
    );
    await expect(absent.assertChannelMember("C_EVAL")).rejects.toThrow("not a member");
  });

  test("treats already-removed Slack resources as successful cleanup", async () => {
    const cleaner = new SlackFixtureCleaner(config, client());
    expect(
      await cleaner.cleanup(() =>
        Promise.reject(new Error("An API error occurred: message_not_found"))
      )
    ).toBeUndefined();
    expect(
      await cleaner.cleanup(() =>
        Promise.reject(new Error("An API error occurred: no_pin"))
      )
    ).toBeUndefined();
    expect(
      await cleaner.cleanup(() =>
        Promise.reject(new Error("An API error occurred: missing_scope"))
      )
    ).toBe("An API error occurred: missing_scope");
  });
});
