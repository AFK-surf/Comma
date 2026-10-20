// Ported from systems/connector/salix-connect/comma_client_cli_test.go (same test name).
// `comma call <module> <api> --json` posts to Main's declarative API with the bearer Main launched it with.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Layer } from "effect";
import { ClientControl } from "../../src/connector/connector.ts";
import { runCommaClientCli } from "../../src/connector/comma-client-cli.ts";

test("TestCommaClientCLICallsDeclarativeMainAPIWithInjectedBearer", async () => {
  let got: Record<string, unknown> = {};
  const control = Layer.succeed(ClientControl)({
    call: (token, body) =>
      token === "launch-token"
        ? Effect.sync(() => {
            got = body as Record<string, unknown>;
            return { ok: true };
          })
        : Effect.fail(new Error("unauthorized")),
  });
  const output: string[] = [];
  await Effect.runPromise(
    runCommaClientCli(["call", "global-settings", "update", "--json", '{"showInDock":false}'], {
      env: { COMMA_CLIENT_CONTROL_URL: "http://main.test", COMMA_CLIENT_CONTROL_TOKEN: "launch-token" },
      stdout: (line) => void output.push(line),
    }).pipe(Effect.provide(control)),
  );
  assert.match(output.join(""), /"ok":true/);
  assert.equal(got.module, "global-settings");
  assert.equal(got.api, "update");
  assert.deepEqual(got.input, { showInDock: false });
});
