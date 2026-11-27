// The system's proxy for the station's connection to Salix. The station runs on its own Node, which does not read
// the system's proxy settings; Main asks Chromium (`session.resolveProxy`) and writes the answer into the connection's
// file (systems/station/src/connector/sockets.ts dials through it first, and directly when it does not connect).

/** The URL Chromium is asked about: the server's, as an HTTP one, so the answer is the proxy an HTTPS request takes. */
export function proxyQueryUrl(server: string): string {
  return server.replace(/^ws(s?):/i, "http$1:");
}

/**
 * The proxy URL of Chromium's answer ("DIRECT", "PROXY host:port", "HTTPS host:port", "SOCKS5 host:port", or several
 * joined by ";"), or undefined for none. Only the first choice counts, and only an HTTP or HTTPS proxy: the station
 * tunnels with CONNECT. A first choice of DIRECT or SOCKS gives none, and the station dials directly as it always did.
 */
export function stationProxy(answer: string): string | undefined {
  const [kind, address] = (answer.split(";")[0] ?? "").trim().split(/\s+/);
  const scheme = { PROXY: "http", HTTPS: "https" }[kind?.toUpperCase() ?? ""];
  if (!scheme || !address) return undefined;
  try {
    return new URL(`${scheme}://${address}`).origin;
  } catch {
    return undefined;
  }
}
