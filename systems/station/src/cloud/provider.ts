// Which control plane a station is enrolled in, and how each one is spoken to: still.fail cloud (the default, as it
// always was) or Comma (docs/cloud.md, "Control planes"). Only names, paths and signing tags differ; the scheme is one:
// Ed25519 over "<tag>:<origin>:<station>:<ts>[:<sha256 of the body>]" with the station's key, in x-<prefix>-* headers.
// cloud.json says which (`provider`, absent: still.fail).

export type Provider = "stillfail" | "comma";

export const PROVIDERS: readonly Provider[] = ["stillfail", "comma"];

export function providerOf(raw: unknown): Provider {
  return raw === "comma" ? "comma" : "stillfail";
}

export type ProviderSpec = {
  readonly provider: Provider;
  /// How it is named in logs and errors.
  readonly name: string;
  /// POST: a one-time token for the workspace's identity.
  readonly enrollPath: string;
  /// The enrollment proof's prefixes, tried in order: the next only when the control plane refuses the signature.
  readonly enrollPrefixes: readonly string[];
  /// The presence WebSocket.
  readonly connectPath: string;
  /// The connect proof's prefixes: each signs under its own tag in its own x-<prefix>-* headers.
  readonly connectPrefixes: readonly string[];
  /// Notices posted signed, under this tag; also in the former headers when `notifyFormer`.
  readonly notifyPath: string;
  readonly notifyTag: string;
  readonly notifyFormer: boolean;
  /// Traces (OTLP JSON), signed under each prefix's tag; none: the provider takes none.
  readonly telemetry: { readonly path: string; readonly prefixes: readonly string[] } | null;
  /// Where releases are: `<base>/releases/station.json` and `<base>/install.sh`.
  readonly releaseBase: (origin: string) => string;
  /// Member credentials it signs: their `iss` and header `typ`.
  readonly credential: Accepted;
  /// Bug reports to the still.fail team, and the session pages at `<origin>/o/…`.
  readonly feedback: boolean;
  readonly pages: boolean;
  /// Its gateways' iroh ids may call the device tools (`comma/tools/1`).
  readonly tools: boolean;
  /// It is told where the mesh endpoint may be reached (`reach` frames on the presence socket).
  readonly reach: boolean;
};

/// Which member credentials a station takes.
export type Accepted = { readonly issuers: readonly string[]; readonly types: readonly string[] };

export const STILLFAIL: ProviderSpec = {
  provider: "stillfail",
  name: "still.fail cloud",
  enrollPath: "/v1/stations/enroll",
  enrollPrefixes: ["stillfail", "ember"],
  connectPath: "/v1/stations/connect",
  connectPrefixes: ["stillfail", "ember"],
  notifyPath: "/v1/stations/notify",
  notifyTag: "ember-station-notify-v1",
  notifyFormer: true,
  telemetry: { path: "/v1/telemetry/traces", prefixes: ["stillfail", "ember"] },
  releaseBase: (origin) => origin,
  credential: { issuers: ["stillfail-cloud", "ember-cloud"], types: ["stillfail-member+jwt", "ember-member+jwt"] },
  feedback: true,
  pages: true,
  tools: false,
  reach: false,
};

/// The Comma control plane (contract v1, §1–3, §6–7).
export const COMMA: ProviderSpec = {
  provider: "comma",
  name: "Comma",
  enrollPath: "/v1/comma/stations/enroll",
  enrollPrefixes: ["comma"],
  connectPath: "/v1/comma/stations/connect",
  connectPrefixes: ["comma"],
  notifyPath: "/v1/comma/stations/notify",
  notifyTag: "comma-station-notify-v1",
  notifyFormer: false,
  // Comma takes no station traces yet (its tag, comma-station-telemetry-v1, is reserved).
  telemetry: null,
  releaseBase: (origin) => `${origin}/stations`,
  credential: { issuers: ["comma"], types: ["comma-member+jwt"] },
  feedback: false,
  pages: false,
  tools: true,
  reach: true,
};

export const specOf = (provider: Provider): ProviderSpec => (provider === "comma" ? COMMA : STILLFAIL);

/// The x-<prefix>-* headers of a request signed by `prefixes`: the station, the time, and each prefix's own signature
/// of `message(prefix)`. The signing scheme every provider shares; `x-stillfail-*` always carries the first prefix's.
export function signedHeaders(prefixes: readonly string[], station: string, ts: number, sign: (prefix: string) => string, extra: Record<string, string> = {}): Record<string, string> {
  const headers: Record<string, string> = {};
  for (const prefix of prefixes) {
    // Comma reads the still.fail header names (contract §1): its signature goes in them.
    const h = prefix === "comma" ? "stillfail" : prefix;
    headers[`x-${h}-station`] = station;
    headers[`x-${h}-ts`] = String(ts);
    headers[`x-${h}-signature`] = sign(prefix);
    for (const [k, v] of Object.entries(extra)) headers[`x-${h}-${k}`] = v;
  }
  return headers;
}
