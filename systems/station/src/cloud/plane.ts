// The station's control plane: what it is told by, and tells, whoever keeps its workspace (docs/cloud.md, "Control planes").
// One shape for every provider (provider.ts): cloud.json and its changes, the presence socket, notices, traces, where
// its releases are and which member credentials it takes. still.fail cloud's is what the station always did; Comma's
// speaks its contract (v1). The service (services.ts `ControlPlane`) follows cloud.json's provider, read anew at each
// use, so a station enrolled elsewhere while it runs follows without a restart.
import { Effect, Stream, type SubscriptionRef } from "effect";
import type { Notice } from "../read/notices.ts";
import { otlpBody } from "../mesh/traces.ts";
import { nowSecs } from "../ops/files.ts";
import { type StationKey, sha256hex } from "./key.ts";
import { presence } from "./presence.ts";
import { type Accepted, type Provider, type ProviderSpec, signedHeaders, specOf } from "./provider.ts";
import { signedPost } from "./signed.ts";
import type { Cloud as CloudState } from "./state.ts";

export type ControlPlaneShape = {
  /// cloud.json in memory, and its changes as they happen.
  readonly state: CloudState;
  readonly changes: Stream.Stream<void>;
  /// The provider spoken to now.
  readonly spec: () => ProviderSpec;
  /// The presence socket, kept for good (until interrupted) while the station answers.
  readonly presence: Effect.Effect<never>;
  /// A batch of notices (at most 50) for people's devices.
  readonly notify: (notices: Notice[]) => Effect.Effect<void, Error>;
  /// A batch of the mesh's spans; dropped where the provider takes none.
  readonly traces: (spans: unknown[]) => Effect.Effect<void, Error>;
  /// Where the station's releases and installer are (`<base>/releases/station.json`, `<base>/install.sh`), while in a
  /// workspace.
  readonly releaseBase: () => string | null;
  /// Which member credentials the station takes now.
  readonly credential: () => Accepted;
};

export type PlaneParts = {
  state: CloudState;
  changes: Stream.Stream<void>;
  key: StationKey;
  up: SubscriptionRef.SubscriptionRef<boolean>;
  /// The provider: fixed, or as cloud.json says (the live station's).
  provider?: Provider;
};

export function makeControlPlane({ state, changes, key, up, provider }: PlaneParts): ControlPlaneShape {
  const spec = () => specOf(provider ?? state.provider());
  return {
    state,
    changes,
    spec,
    presence: presence({ cloud: { state, changes }, key, up, spec }),
    notify: (notices) =>
      Effect.tryPromise({
        try: async () => {
          const plane = spec();
          // Signed over "<tag>:<origin>:<station>:<ts>:<sha256 of the body, hex>"; still.fail's under both names.
          await signedPost(state, key, plane.notifyPath, plane.notifyTag, { notices }, plane.notifyFormer, plane.name);
        },
        catch: (e) => e as Error,
      }),
    traces: (spans) =>
      Effect.tryPromise({
        try: async () => {
          const plane = spec();
          const s = state.state;
          if (s === null || plane.telemetry === null) return;
          const body = otlpBody(s.station, spans);
          const ts = nowSecs();
          const digest = sha256hex(body);
          const headers = { "content-type": "application/json", ...signedHeaders(plane.telemetry.prefixes, s.station, ts, (prefix) => key.sign(`${prefix}-station-telemetry-v1:${s.origin}:${s.station}:${ts}:${digest}`)) };
          const response = await fetch(`${s.origin}${plane.telemetry.path}`, { method: "POST", headers, body, signal: AbortSignal.timeout(30_000) });
          if (!response.ok) throw new Error(`${plane.name} answered ${response.status}`);
        },
        catch: (e) => e as Error,
      }),
    releaseBase: () => {
      const origin = state.state?.origin;
      return origin ? spec().releaseBase(origin) : null;
    },
    credential: () => spec().credential,
  };
}
