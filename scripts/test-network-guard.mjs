// Keeps a Node or Bun test run off the real network
// (docs/testing.md#no-real-network). Load it before the tests: Vitest
// `setupFiles` (through clients/packages/test-utils/src/setup-network.ts),
// `node --import`, or a Bun `preload`.
//
// A connection to a host that is not this machine throws, naming the host,
// and the run fails: Vitest fails the test that made it, other runners exit
// non-zero. This machine is loopback, `localhost` and `*.localhost`, its own
// host name and interface addresses, and the hosts in COMMA_TEST_NETWORK_ALLOW
// (comma-separated). Unix sockets are not checked. Subprocesses inherit an
// environment that keeps them offline (proxies on a closed local port, npm,
// pip, uv, cargo, Go and git offline).
//
// COMMA_TEST_NETWORK=report lets connections through and only reports them,
// to stderr and, with COMMA_TEST_NETWORK_REPORT naming a file, as JSON lines.
// COMMA_TEST_NETWORK=live turns the guard off: only for a test of an external
// service on purpose, which PR CI does not run.
import { appendFileSync } from "node:fs";
import { createRequire } from "node:module";
import { hostname, networkInterfaces } from "node:os";

const require = createRequire(import.meta.url);
const net = require("node:net");
const stateKey = Symbol.for("comma.test.networkGuard");
const mode = process.env.COMMA_TEST_NETWORK ?? "enforce";
const closedProxy = "http://127.0.0.1:9";

/** Environment variables that keep subprocesses offline. */
export function offlineEnv(allow = allowed()) {
  const noProxy = ["localhost", "127.0.0.1", "::1", ".localhost", ...allow].join(",");
  return {
    HTTP_PROXY: closedProxy,
    HTTPS_PROXY: closedProxy,
    ALL_PROXY: closedProxy,
    http_proxy: closedProxy,
    https_proxy: closedProxy,
    all_proxy: closedProxy,
    NO_PROXY: noProxy,
    no_proxy: noProxy,
    npm_config_offline: "true",
    PIP_NO_INDEX: "1",
    UV_OFFLINE: "1",
    CARGO_NET_OFFLINE: "true",
    GOPROXY: "off",
    GIT_ALLOW_PROTOCOL: "file",
  };
}

function allowed() {
  return (process.env.COMMA_TEST_NETWORK_ALLOW ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
}

const state = (globalThis[stateKey] ??= { installed: false, blocked: [] });

/** Connections refused since the last call, oldest first. */
export function takeBlocked() {
  return state.blocked.splice(0);
}

export class NetworkBlocked extends Error {
  constructor(host, test) {
    super(
      `tests must not use the real network: ${test ? `"${test}"` : "a test"} connected to ${host}. ` +
        "Use a local fixture or fake; a test of an external service on purpose is a live test, " +
        "which PR CI does not run (docs/testing.md#no-real-network)"
    );
    this.name = "NetworkBlocked";
    this.host = host;
  }
}

const localNames = new Set(["localhost", hostname().toLowerCase(), ...allowed()]);
const localAddresses = new Set(
  Object.values(networkInterfaces())
    .flat()
    .map((entry) => entry?.address)
    .filter(Boolean)
);
for (const entry of allowed()) if (net.isIP(entry)) localAddresses.add(entry);

/** Whether `host` (a name or an address) is this machine. */
export function isLocal(host) {
  const name = String(host)
    .toLowerCase()
    .replace(/\.$/, "")
    .replace(/^\[|\]$/g, "");
  if (name === "" || localNames.has(name) || name.endsWith(".localhost")) return true;
  if (net.isIPv4(name))
    return name.startsWith("127.") || name === "0.0.0.0" || localAddresses.has(name);
  if (net.isIPv6(name)) {
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(name);
    if (mapped) return isLocal(mapped[1]);
    return name === "::1" || name === "::" || localAddresses.has(name);
  }
  return false;
}

/** The current test's name, where the runner tells it. */
function currentTest() {
  try {
    return globalThis.expect?.getState?.().currentTestName ?? undefined;
  } catch {
    return undefined;
  }
}

/** Checks a connection to `host`; throws when the guard refuses it. */
export function check(host, port) {
  if (mode === "live" || isLocal(host)) return;
  refuse(port == null ? String(host) : `${host}:${port}`);
}

function refuse(what) {
  const test = currentTest();
  if (mode === "report") {
    process.stderr.write(
      `[network guard] report: ${what}${test ? ` from "${test}"` : ""}\n`
    );
    const file = process.env.COMMA_TEST_NETWORK_REPORT;
    if (file)
      appendFileSync(
        file,
        `${JSON.stringify({ host: what, test, file: process.argv[1], stack: new Error().stack?.split("\n").slice(2, 12) })}\n`
      );
    return;
  }
  const error = new NetworkBlocked(what, test);
  state.blocked.push(error);
  process.stderr.write(
    `[network guard] ${error.message}\n${error.stack?.split("\n").slice(1, 10).join("\n")}\n`
  );
  process.exitCode = 1;
  throw error;
}

// `socket.connect(options | port, host? | path, listener?)`, or the normalized
// argument array `net.connect` passes.
function connectTarget(args) {
  const first = Array.isArray(args[0]) ? args[0][0] : args[0];
  if (first && typeof first === "object") {
    if (first.path != null) return null;
    return { host: first.host ?? "localhost", port: first.port, options: first };
  }
  if (typeof first === "string" && !/^\d+$/.test(first)) return null;
  return { host: typeof args[1] === "string" ? args[1] : "localhost", port: first };
}

function checkedLookup(lookup, host, port) {
  return (name, options, callback) =>
    lookup(name, options, (error, address, family) => {
      if (error) return callback(error);
      const addresses = Array.isArray(address)
        ? address.map((entry) => entry.address)
        : [address];
      try {
        for (const entry of addresses)
          if (!isLocal(entry)) refuse(`${host} (${entry}):${port}`);
      } catch (refused) {
        return callback(refused);
      }
      return callback(error, address, family);
    });
}

if (!state.installed && mode !== "live") {
  state.installed = true;
  for (const [key, value] of Object.entries(offlineEnv())) process.env[key] = value;

  // `net.connect`, `tls.connect`, `http`/`https` agents and Node's `fetch`
  // (undici) all connect through here.
  const connect = net.Socket.prototype.connect;
  net.Socket.prototype.connect = function (...args) {
    const to = connectTarget(args);
    if (
      to &&
      typeof to.options?.lookup === "function" &&
      !isLocal(to.host) &&
      mode !== "live"
    )
      // The caller resolves the name itself (an address pinned against DNS
      // rebinding): the address it answers is where the socket goes.
      to.options.lookup = checkedLookup(to.options.lookup, to.host, to.port);
    else if (to) check(to.host, to.port);
    return connect.apply(this, args);
  };

  // Bun's `fetch` and `Bun.connect` do not go through `node:net`.
  if (globalThis.Bun) {
    const fetch = globalThis.fetch;
    globalThis.fetch = Object.assign(function (input, init) {
      const url = new URL(input instanceof Request ? input.url : String(input));
      if (
        url.protocol === "http:" ||
        url.protocol === "https:" ||
        url.protocol === "ws:" ||
        url.protocol === "wss:"
      )
        check(url.hostname, url.port || undefined);
      return fetch.call(this, input, init);
    }, fetch);
    const bunConnect = Bun.connect;
    Bun.connect = function (options) {
      if (options?.hostname != null && options.unix == null)
        check(options.hostname, options.port);
      return bunConnect.call(this, options);
    };
  }
}
