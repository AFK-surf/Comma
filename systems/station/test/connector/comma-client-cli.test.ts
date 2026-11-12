// Ported from systems/connector/salix-connect/comma_client_cli_test.go (same test name).
// `comma call <module> <api> --json` posts to Main's declarative API with the bearer Main launched it with. Without
// Main, `comma tools | describe | call` reach Salix through the station's MCP endpoint of the session that runs it
// (its URL and token in the environment), as the salix_tools and salix_call tools.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Layer } from "effect";
import { ClientControl } from "../../src/connector/connector.ts";
import { StationMcp, runCommaClientCli } from "../../src/connector/comma-client-cli.ts";

const noMain = Layer.succeed(ClientControl)({ call: () => Effect.fail(new Error("no Main here")) });
const noStation = Layer.succeed(StationMcp)({ call: () => Effect.fail(new Error("no station here")) });

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
    }).pipe(Effect.provide(Layer.merge(control, noStation))),
  );
  assert.match(output.join(""), /"ok":true/);
  assert.equal(got.module, "global-settings");
  assert.equal(got.api, "update");
  assert.deepEqual(got.input, { showInDock: false });
});

test("without Main, comma tools | describe | call reach Salix through the station's MCP endpoint as the session", async () => {
  const asked: { url: string; token: string; message: any }[] = [];
  const listed = [{ name: "fs.write_file", description: "Create a visible file, or replace one whole.", input_schema: { type: "object" } }];
  const station = Layer.succeed(StationMcp)({
    call: (url, token, message: any) => {
      asked.push({ url, token, message });
      if (url !== "http://station.test/mcp" || token !== "session-token") return Effect.fail(new Error("unauthorized"));
      const reply = (result: unknown) => Effect.succeed({ jsonrpc: "2.0", id: message.id, result });
      if (message.params.name === "salix_tools") return reply({ content: [{ type: "text", text: JSON.stringify(listed) }] });
      if (message.params.arguments.tool === "env.exec") return reply({ isError: true, content: [{ type: "text", text: "The call was refused (too_many_calls): this station has 4 calls in flight" }] });
      return reply({ content: [{ type: "text", text: "wrote 5 bytes to /a.md" }] });
    },
  });
  const env = { COMMA_STATION_MCP_URL: "http://station.test/mcp", COMMA_STATION_MCP_TOKEN: "session-token" };
  const run = async (args: string[]) => {
    const output: string[] = [];
    await Effect.runPromise(runCommaClientCli(args, { env, stdout: (line) => void output.push(line) }).pipe(Effect.provide(Layer.merge(noMain, station))));
    return output.join("");
  };

  assert.deepEqual(JSON.parse(await run(["tools"])), listed);
  assert.deepEqual(asked.at(-1)!.message.params, { name: "salix_tools", arguments: {} });
  assert.deepEqual(JSON.parse(await run(["describe", "fs.write_file"])), listed[0]);
  await assert.rejects(run(["describe", "env.exec"]), /no Salix tool "env.exec"/);

  assert.equal(await run(["call", "fs.write_file", "--json", '{"path":"/a.md","content":"hello"}']), "wrote 5 bytes to /a.md\n");
  assert.deepEqual(asked.at(-1)!.message.params, { name: "salix_call", arguments: { tool: "fs.write_file", args: { path: "/a.md", content: "hello" } } });
  assert.equal(await run(["call", "fs.write_file"]), "wrote 5 bytes to /a.md\n");
  assert.deepEqual(asked.at(-1)!.message.params.arguments.args, {});
  // What the station refused is the command's failure.
  await assert.rejects(run(["call", "env.exec", "--json", '{"cmd":"ls"}']), /refused \(too_many_calls\)/);
  await assert.rejects(run(["call", "fs.write_file", "--json", "[1]"]), /--json must be a JSON object/);
  await assert.rejects(run(["call"]), /usage: comma call <tool>/);
  await assert.rejects(run(["modules"]), /unknown comma command "modules"/);
});

test("comma exec runs a command through env.exec with a managed credential: its output, stderr and exit code are the command's", async () => {
  const asked: any[] = [];
  const station = Layer.succeed(StationMcp)({
    call: (_url, _token, message: any) => {
      asked.push(message.params.arguments);
      return Effect.succeed({ jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: JSON.stringify({ exit_code: 3, status: "completed", stdout: "out\n", stderr: "err\n" }) }] } });
    },
  });
  const env = { COMMA_STATION_MCP_URL: "http://station.test/mcp", COMMA_STATION_MCP_TOKEN: "session-token" };
  const out: string[] = [];
  const err: string[] = [];
  let code = 0;
  const run = (args: string[]) =>
    Effect.runPromise(
      runCommaClientCli(args, { env, cwd: "/work", stdout: (t) => void out.push(t), stderr: (t) => void err.push(t), exit: (c) => void (code = c) }).pipe(Effect.provide(Layer.merge(noMain, station))),
    );

  await run(["exec", "--credential", "lark/ann=LARKSUITE_CLI_USER_ACCESS_TOKEN", "--credential", "lark/ann:client_id=LARKSUITE_CLI_APP_ID", "--env", "LARKSUITE_CLI_BRAND=lark", "--", "lark-cli", "im", "it's"]);
  assert.deepEqual(asked.at(-1), {
    tool: "env.exec",
    args: {
      device_id: "self",
      environment: "self",
      description: "comma exec",
      command: "lark-cli im 'it'\\''s'",
      credential_env: [
        { env_var: "LARKSUITE_CLI_USER_ACCESS_TOKEN", provider: "lark", alias: "ann", value: "access_token" },
        { env_var: "LARKSUITE_CLI_APP_ID", provider: "lark", alias: "ann", value: "client_id" },
      ],
      env: { LARKSUITE_CLI_BRAND: "lark" },
      working_dir: "/work",
    },
  });
  assert.equal(out.join(""), "out\n");
  assert.equal(err.join(""), "err\n");
  assert.equal(code, 3);

  await run(["exec", "--credential", "lark/ann=TOKEN", "--timeout", "30", "--", "ls"]);
  assert.equal(asked.at(-1).args.timeout, 30);

  await assert.rejects(run(["exec", "--", "ls"]), /usage: comma exec/);
  await assert.rejects(run(["exec", "--credential", "lark=TOKEN", "--", "ls"]), /usage: comma exec/);
  await assert.rejects(run(["exec", "--credential", "lark/ann=TOKEN"]), /usage: comma exec/);
});

test("with neither Main nor the station's endpoint, comma says it is unavailable", async () => {
  await assert.rejects(
    Effect.runPromise(runCommaClientCli(["tools"], { env: {}, stdout: () => {} }).pipe(Effect.provide(Layer.merge(noMain, noStation)))),
    /unavailable in this environment/,
  );
});
