import { describe, expect, test } from "bun:test";

import {
  GitHubRepositoryObserver,
  type GitHubObserverClient,
  GoogleWorkspaceObserver,
  type GoogleObserverClients,
  LinearWorkspaceObserver,
  type LinearObserverClient,
  NotionMcpPageObserver,
  type NotionObserverClient,
  SlackObserver,
} from "../src/observers";
import type { SlackWebClient } from "../src/slack";

const observedAt = new Date("2026-07-17T10:00:00.000Z");
const now = () => observedAt;

describe("external provider observers", () => {
  test("observes only the requested Slack user's thread replies", async () => {
    const client: SlackWebClient = {
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
        replies: async () => ({
          ok: true,
          messages: [
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
        }),
      },
    };
    const observer = new SlackObserver(
      {
        token: "token",
        workspaceId: "T_EVAL",
        allowedChannelIds: ["C_EVAL"],
        pollMs: 100,
      },
      client,
      now
    );

    expect(
      await observer.observe({
        kind: "thread",
        channelId: "C_EVAL",
        threadTs: "100.000001",
        replyUserId: "U_EVALENS",
      })
    ).toEqual({
      provider: "slack",
      resourceType: "thread",
      lookup: "C_EVAL:100.000001:replyUser=U_EVALENS",
      exists: true,
      observedAt: observedAt.toISOString(),
      resource: {
        channelId: "C_EVAL",
        threadTs: "100.000001",
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
      },
    });

    expect(
      await observer.observe({
        kind: "thread",
        channelId: "C_EVAL",
        threadTs: "100.000001",
        replyUserId: "U_ABSENT",
      })
    ).toMatchObject({ exists: false, provider: "slack", resourceType: "thread" });
  });

  test("turns missing Slack resources into observations but preserves auth errors", async () => {
    const base: SlackWebClient = {
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
        replies: async () => ({ ok: false, error: "thread_not_found" }),
      },
    };
    const config = {
      token: "token",
      workspaceId: "T_EVAL",
      allowedChannelIds: ["C_EVAL"],
      pollMs: 100,
    };
    const missing = new SlackObserver(config, base, now);
    expect(
      await missing.observe({
        kind: "thread",
        channelId: "C_EVAL",
        threadTs: "404.000001",
      })
    ).toMatchObject({ exists: false, resourceType: "thread" });

    const authError = { data: { error: "invalid_auth" } };
    const invalidAuth = new SlackObserver(
      config,
      {
        ...base,
        conversations: { replies: async () => Promise.reject(authError) },
      },
      now
    );
    await expect(
      invalidAuth.observe({
        kind: "thread",
        channelId: "C_EVAL",
        threadTs: "100.000001",
      })
    ).rejects.toBe(authError);
  });

  test("observes a GitHub issue and its labels through the Octokit boundary", async () => {
    const client: GitHubObserverClient = {
      rest: {
        issues: {
          get: async () => ({
            data: {
              number: 42,
              title: "[evalens] integration check",
              state: "open",
              html_url: "https://github.com/comma/eval/issues/42",
              labels: [{ name: "evalens-run" }, "triage"],
            },
          }),
          listForRepo: async () => ({
            data: [
              {
                number: 42,
                title: "[evalens] integration check",
                state: "open",
                html_url: "https://github.com/comma/eval/issues/42",
                labels: [{ name: "evalens-run" }],
              },
            ],
          }),
          getLabel: async () => ({
            data: { name: "evalens-run", color: "00ff00" },
          }),
        },
      },
    };
    const observer = new GitHubRepositoryObserver("token", client, now);

    expect(
      await observer.observe({
        kind: "issue",
        owner: "comma",
        repo: "eval",
        issueNumber: 42,
      })
    ).toEqual({
      provider: "github",
      resourceType: "issue",
      lookup: "comma/eval#42",
      exists: true,
      observedAt: observedAt.toISOString(),
      resource: {
        owner: "comma",
        repo: "eval",
        number: 42,
        title: "[evalens] integration check",
        state: "open",
        url: "https://github.com/comma/eval/issues/42",
        labels: ["evalens-run", "triage"],
      },
    });
    expect(
      await observer.observe({
        kind: "label",
        owner: "comma",
        repo: "eval",
        name: "evalens-run",
      })
    ).toMatchObject({ exists: true, resourceType: "label" });
    expect(
      await observer.observe({
        kind: "issue",
        owner: "comma",
        repo: "eval",
        title: "[evalens] integration check",
      })
    ).toMatchObject({
      exists: true,
      lookup: "comma/eval:title=[evalens] integration check",
      resource: { number: 42 },
    });
  });

  test("turns only GitHub 404 into a missing observation", async () => {
    const notFound = { status: 404 };
    const unauthorized = { status: 401 };
    const observer = new GitHubRepositoryObserver(
      "token",
      githubThrowingClient(notFound),
      now
    );
    expect(
      await observer.observe({
        kind: "issue",
        owner: "comma",
        repo: "eval",
        issueNumber: 404,
      })
    ).toMatchObject({ exists: false, resourceType: "issue" });

    const invalidAuth = new GitHubRepositoryObserver(
      "token",
      githubThrowingClient(unauthorized),
      now
    );
    await expect(
      invalidAuth.observe({
        kind: "issue",
        owner: "comma",
        repo: "eval",
        issueNumber: 1,
      })
    ).rejects.toBe(unauthorized);
  });

  test("observes Linear issue placement and priority through the official SDK boundary", async () => {
    const client: LinearObserverClient = {
      issue: async () => ({
        id: "issue-id",
        identifier: "EVAL-42",
        title: "Evalens integration issue",
        priority: 4,
        priorityLabel: "Low",
        url: "https://linear.app/comma/issue/EVAL-42",
        team: Promise.resolve({ id: "team-id", name: "Eval", key: "EVAL" }),
        project: Promise.resolve({ id: "project-id", name: "Evalens" }),
      }),
      issues: async () => ({
        nodes: [
          {
            id: "issue-id",
            identifier: "EVAL-42",
            title: "Evalens integration issue",
            priority: 4,
            priorityLabel: "Low",
            url: "https://linear.app/comma/issue/EVAL-42",
          },
        ],
      }),
      team: async () => ({ id: "team-id", name: "Eval", key: "EVAL" }),
      project: async () => ({
        id: "project-id",
        name: "Evalens",
        slugId: "evalens",
      }),
    };
    const observer = new LinearWorkspaceObserver("token", client, now);

    expect(
      await observer.observe({ kind: "issue", idOrIdentifier: "EVAL-42" })
    ).toEqual({
      provider: "linear",
      resourceType: "issue",
      lookup: "EVAL-42",
      exists: true,
      observedAt: observedAt.toISOString(),
      resource: {
        id: "issue-id",
        identifier: "EVAL-42",
        title: "Evalens integration issue",
        priority: 4,
        priorityLabel: "Low",
        url: "https://linear.app/comma/issue/EVAL-42",
        team: { id: "team-id", name: "Eval", key: "EVAL" },
        project: { id: "project-id", name: "Evalens" },
      },
    });
    expect(await observer.observe({ kind: "team", id: "team-id" })).toMatchObject({
      exists: true,
      resourceType: "team",
    });
    expect(await observer.observe({ kind: "project", id: "project-id" })).toMatchObject(
      { exists: true, resourceType: "project" }
    );
    expect(
      await observer.observe({
        kind: "issue",
        title: "Evalens integration issue",
        teamId: "team-id",
      })
    ).toMatchObject({ exists: true, resource: { identifier: "EVAL-42" } });
  });

  test("returns a missing Linear issue but preserves provider failures", async () => {
    const client: LinearObserverClient = {
      issue: async () => undefined,
      issues: async () => ({ nodes: [] }),
      team: async () => undefined,
      project: async () => undefined,
    };
    const observer = new LinearWorkspaceObserver("token", client, now);
    expect(
      await observer.observe({ kind: "issue", title: "[evalens] absent" })
    ).toMatchObject({ exists: false, resourceType: "issue" });

    const authError = { status: 401 };
    const invalidAuth = new LinearWorkspaceObserver(
      "token",
      { ...client, issues: async () => Promise.reject(authError) },
      now
    );
    await expect(
      invalidAuth.observe({ kind: "issue", title: "[evalens] any" })
    ).rejects.toBe(authError);
  });

  test("observes a Notion MCP page title and exact parent, while preserving auth errors", async () => {
    const client: NotionObserverClient = {
      fetch: async () => ({
        metadata: {
          title: "[evalens] run note",
          url: "https://notion.so/page-id",
          is_archived: false,
        },
        text: '<ancestor-path><data-source url="collection://parent-id" /></ancestor-path>',
      }),
      search: async () => ({
        results: [{ id: "page-id", title: "[evalens] run note" }],
      }),
    };
    const observer = new NotionMcpPageObserver("token", client, now);
    expect(
      await observer.observe({ pageId: "page-id", expectedParentId: "parent-id" })
    ).toEqual({
      provider: "notion",
      resourceType: "page",
      lookup: "page-id",
      exists: true,
      observedAt: observedAt.toISOString(),
      resource: {
        id: "page-id",
        title: "[evalens] run note",
        url: "https://notion.so/page-id",
        archived: false,
        expectedParentId: "parent-id",
        parentMatched: true,
      },
    });
    expect(
      await observer.observe({
        title: "[evalens] run note",
        expectedParentId: "parent-id",
      })
    ).toMatchObject({
      exists: true,
      lookup: "title=[evalens] run note",
      resource: { id: "page-id", parentMatched: true },
    });

    const authError = { code: "unauthorized" };
    const invalidAuth = new NotionMcpPageObserver(
      "token",
      {
        fetch: async () => Promise.reject(authError),
      },
      now
    );
    await expect(invalidAuth.observe({ pageId: "page-id" })).rejects.toBe(authError);

    const missing = new NotionMcpPageObserver(
      "token",
      {
        fetch: async () => {
          throw new Error("fetch must not run when search has no exact match");
        },
        search: async () => ({ results: [] }),
      },
      now
    );
    expect(await missing.observe({ title: "[evalens] absent" })).toMatchObject({
      exists: false,
      resourceType: "page",
    });

    const deleted = new NotionMcpPageObserver(
      "token",
      {
        fetch: async () => Promise.reject({ code: "object_not_found" }),
      },
      now
    );
    expect(await deleted.observe({ pageId: "deleted-page" })).toMatchObject({
      exists: false,
      lookup: "deleted-page",
    });
  });

  test("observes seeded Gmail, Drive, Calendar, and Chat records", async () => {
    const clients = googleClients();
    const observer = new GoogleWorkspaceObserver("token", clients, now);

    const [gmail, drive, calendar, chat] = await Promise.all([
      observer.observe({ kind: "gmail", query: "subject:evalens-fixture" }),
      observer.observe({ kind: "drive", query: "name = 'Evalens fixture'" }),
      observer.observe({
        kind: "calendar",
        calendarId: "primary",
        privateExtendedProperty: ["evalensRun=42"],
      }),
      observer.observe({
        kind: "chat",
        spaceName: "spaces/AAA",
        filter: 'createTime > "2026-07-17T00:00:00Z"',
      }),
    ]);

    expect(gmail).toMatchObject({
      exists: true,
      resourceType: "gmail-message",
      resource: {
        records: [{ id: "gmail-1", subject: "Evalens fixture" }],
      },
    });
    expect(drive).toMatchObject({
      exists: true,
      resourceType: "drive-file",
      resource: { records: [{ id: "drive-1", name: "Evalens fixture" }] },
    });
    expect(calendar).toMatchObject({
      exists: true,
      resourceType: "calendar-event",
      resource: { records: [{ id: "event-1", summary: "Evalens launch" }] },
    });
    expect(chat).toMatchObject({
      exists: true,
      resourceType: "chat-message",
      resource: { records: [{ name: "spaces/AAA/messages/1", text: "launch" }] },
    });
  });

  test("returns missing Google observations but preserves provider failures", async () => {
    const observer = new GoogleWorkspaceObserver("token", emptyGoogleClients(), now);
    const observations = await Promise.all([
      observer.observe({ kind: "gmail", query: "subject:absent" }),
      observer.observe({ kind: "drive", query: "name = 'absent'" }),
      observer.observe({ kind: "calendar", calendarId: "primary", query: "absent" }),
      observer.observe({ kind: "chat", spaceName: "spaces/AAA" }),
    ]);
    expect(observations.every((entry) => entry.exists === false)).toBe(true);

    const authError = { status: 401 };
    const clients = emptyGoogleClients();
    clients.gmail.users.messages.list = async () => Promise.reject(authError);
    await expect(
      new GoogleWorkspaceObserver("token", clients, now).observe({
        kind: "gmail",
        query: "subject:any",
      })
    ).rejects.toBe(authError);
  });
});

function githubThrowingClient(error: unknown): GitHubObserverClient {
  return {
    rest: {
      issues: {
        get: async () => Promise.reject(error),
        listForRepo: async () => Promise.reject(error),
        getLabel: async () => Promise.reject(error),
      },
    },
  };
}

function googleClients(): GoogleObserverClients {
  return {
    gmail: {
      users: {
        messages: {
          list: async () => ({ data: { messages: [{ id: "gmail-1" }] } }),
          get: async () => ({
            data: {
              id: "gmail-1",
              threadId: "thread-1",
              snippet: "launch date",
              payload: {
                headers: [{ name: "Subject", value: "Evalens fixture" }],
              },
            },
          }),
        },
      },
    },
    drive: {
      files: {
        list: async () => ({
          data: {
            files: [
              {
                id: "drive-1",
                name: "Evalens fixture",
                mimeType: "application/vnd.google-apps.document",
                parents: ["folder-1"],
                trashed: false,
              },
            ],
          },
        }),
      },
    },
    calendar: {
      events: {
        list: async () => ({
          data: {
            items: [
              {
                id: "event-1",
                summary: "Evalens launch",
                status: "confirmed",
                start: { date: "2026-08-01" },
                end: { date: "2026-08-02" },
              },
            ],
          },
        }),
      },
    },
    chat: {
      spaces: {
        messages: {
          list: async () => ({
            data: {
              messages: [
                {
                  name: "spaces/AAA/messages/1",
                  text: "launch",
                  createTime: "2026-07-17T09:00:00Z",
                  thread: { name: "spaces/AAA/threads/1" },
                },
              ],
            },
          }),
        },
      },
    },
  };
}

function emptyGoogleClients(): GoogleObserverClients {
  return {
    gmail: {
      users: {
        messages: {
          list: async () => ({ data: { messages: [] } }),
          get: async () => ({ data: {} }),
        },
      },
    },
    drive: { files: { list: async () => ({ data: { files: [] } }) } },
    calendar: { events: { list: async () => ({ data: { items: [] } }) } },
    chat: {
      spaces: {
        messages: { list: async () => ({ data: { messages: [] } }) },
      },
    },
  };
}
