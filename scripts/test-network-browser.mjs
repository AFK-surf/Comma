// Chromium launch arguments that keep a Playwright browser off the real
// network (docs/testing.md#no-real-network): every host name but this
// machine's fails to resolve, as one that does not exist. A page still
// reaches the hosts a test routes itself (`page.route`), which never resolve.
//
// This machine is `localhost`, `*.localhost`, loopback, the hosts in
// COMMA_TEST_NETWORK_ALLOW (comma-separated) and `extraHosts`.
// COMMA_TEST_NETWORK=live or report leaves the browser's resolver alone.

/** @param {string[]} [extraHosts] */
export function browserNetworkArgs(extraHosts = []) {
  const mode = process.env.COMMA_TEST_NETWORK;
  if (mode === "live" || mode === "report") return [];
  const allow = (process.env.COMMA_TEST_NETWORK_ALLOW ?? "")
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
  const local = [
    "localhost",
    "*.localhost",
    "127.0.0.1",
    "[::1]",
    ...allow,
    ...extraHosts,
  ];
  return [
    `--host-resolver-rules=MAP * ~NOTFOUND, ${local.map((host) => `EXCLUDE ${host}`).join(", ")}`,
  ];
}
