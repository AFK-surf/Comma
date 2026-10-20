// Ported from systems/connector/salix-connect/llm_test.go (same test names).
// The local LLM route forwards a caller's bearer as the capability token through the runtime proxy, and a meeting
// join is given that route's URL and its token.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Layer } from "effect";
import { type Message, makeConnector } from "../../src/connector/connector.ts";
import { MeetHttp } from "../../src/connector/meeting.ts";

test("TestLLMChatForwardsBearerToken", async () => {
  const c = makeConnector({});
  const captured: Array<Record<string, unknown>> = [];
  const deactivate = c.activateRuntimeTransportForTest((m: Message) =>
    Effect.sync(() => {
      captured.push(m.params!);
      c.completeRuntimeProxy({
        id: m.id,
        type: "response",
        result: {
          status: 200,
          headers: { "content-type": "application/json" },
          body_base64: Buffer.from('{"choices":[{"message":{"content":"HELLO"}}]}').toString("base64"),
        },
      });
    }),
  );
  const post = (bearer: string) =>
    c.meeting.llmChat(
      new Request("http://bridge/llm/chat", {
        method: "POST",
        headers: bearer ? { authorization: `Bearer ${bearer}` } : {},
        body: '{"messages":[{"role":"user","content":"hi"}]}',
      }),
    );
  assert.equal((await post("")).status, 401, "missing token");
  const response = await post("cap-abc");
  assert.equal(response.status, 200, "valid token");
  const decoded = (await response.json()) as { choices?: unknown[] };
  assert.ok(decoded.choices?.length, `completion did not flow back: ${JSON.stringify(decoded)}`);
  const params = captured[0];
  assert.equal(params.capability_token, "cap-abc", "the bearer was not forwarded as the capability token");
  assert.equal(params.route_path, "/llm/chat");
  assert.match(Buffer.from(String(params.body_base64), "base64").toString(), /"messages"/);
  deactivate();
});

test("TestMeetingJoinInjectsLLMURLAndPassesToken", async () => {
  let joinBody: Record<string, unknown> = {};
  const meet = Layer.succeed(MeetHttp)({
    request: (_method, _url, body) =>
      Effect.sync(() => {
        joinBody = body as Record<string, unknown>;
        return { status: 200, body: { accepted: true } };
      }),
  });
  const c = makeConnector({ meetUrl: "http://meetnative.test" }, meet);
  await Effect.runPromise(
    c.meetingJoin({ meeting_id: "m1", meet_url: "https://meet.google.com/abc-defg-hij", runtime_token: "tok", llm_capability_token: "cap-secret" }),
  );
  assert.match(String(joinBody.llm_url), /\/llm\/chat$/, "llm_url not injected");
  assert.equal(joinBody.llm_capability_token, "cap-secret");
});
