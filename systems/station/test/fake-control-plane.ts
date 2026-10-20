// A control plane small enough for tests (still.fail cloud's or Comma's, contract v1): enrollment, the presence socket,
// signed posts. It checks every signature as the real ones do (Ed25519 by the station's id over the provider's tag) and
// records what it was asked, so a test says what went over the wire.
import { createHash, createPublicKey, generateKeyPairSync, sign, verify, type KeyObject } from "node:crypto";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";

/// An Ed25519 public key from its raw 32 bytes, hex.
export function publicOf(hex: string): KeyObject {
  return createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(hex, "hex").toString("base64url") }, format: "jwk" });
}

export const checks = (station: string, message: string, signature: string) => {
  try {
    return verify(null, Buffer.from(message), publicOf(station), Buffer.from(signature, "hex"));
  } catch {
    // No station, or not a key.
    return false;
  }
};

const sha256hex = (b: Buffer) => createHash("sha256").update(b).digest("hex");

export type Asked = { method: string; path: string; headers: IncomingMessage["headers"]; body: Buffer; verified: string[] };

/// The workspace's grant key: what members' credentials are signed with.
export class GrantKey {
  readonly private: KeyObject;
  readonly jwk: { kty: string; crv: string; x: string; kid: string };
  readonly kid: string;
  constructor(kid = "k1") {
    this.kid = kid;
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    this.private = privateKey;
    this.jwk = { ...(publicKey.export({ format: "jwk" }) as any), kid };
  }

  credential(header: Record<string, unknown>, claims: Record<string, unknown>): string {
    const b64 = (v: unknown) => Buffer.from(JSON.stringify(v)).toString("base64url");
    const head = `${b64({ alg: "EdDSA", kid: this.kid, ...header })}.${b64(claims)}`;
    return `${head}.${sign(null, Buffer.from(head), this.private).toString("base64url")}`;
  }
}

export type FakeOptions = { provider: "stillfail" | "comma"; gateways?: string[] };

export class FakeControlPlane {
  readonly asked: Asked[] = [];
  readonly sockets: WebSocket[] = [];
  /// What stations said on the presence socket besides "ping" (tool results), parsed.
  readonly heard: any[] = [];
  readonly grant = new GrantKey();
  gateways: string[];
  origin = "";
  private server: Server;
  private wss = new WebSocketServer({ noServer: true });
  private provider: "stillfail" | "comma";

  constructor(options: FakeOptions) {
    this.provider = options.provider;
    this.gateways = options.gateways ?? [];
    this.server = createServer((req, res) => {
      const parts: Buffer[] = [];
      req.on("data", (c) => parts.push(c));
      req.on("end", () => {
        const body = Buffer.concat(parts);
        const asked: Asked = { method: req.method ?? "", path: req.url ?? "", headers: req.headers, body, verified: [] };
        this.asked.push(asked);
        const reply = this.answer(asked);
        res.writeHead(reply[0], { "content-type": "application/json" }).end(JSON.stringify(reply[1]));
      });
    });
    this.server.on("upgrade", (req, socket, head) => {
      const asked: Asked = { method: "GET", path: req.url ?? "", headers: req.headers, body: Buffer.alloc(0), verified: [] };
      this.asked.push(asked);
      const want = this.provider === "comma" ? "/v1/comma/stations/connect" : "/v1/stations/connect";
      const station = String(req.headers["x-stillfail-station"] ?? "");
      const ts = String(req.headers["x-stillfail-ts"] ?? "");
      const tag = this.provider === "comma" ? "comma" : "stillfail";
      if (asked.path !== want || !checks(station, `${tag}-station-connect-v1:${this.origin}:${station}:${ts}`, String(req.headers["x-stillfail-signature"] ?? ""))) {
        socket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
        return;
      }
      asked.verified.push(tag);
      if (req.headers["x-ember-signature"] && checks(station, `ember-station-connect-v1:${this.origin}:${station}:${ts}`, String(req.headers["x-ember-signature"]))) asked.verified.push("ember");
      this.wss.handleUpgrade(req, socket, head, (ws) => {
        this.sockets.push(ws);
        ws.on("message", (data) => {
          const text = data.toString();
          if (text === "ping") ws.send("pong");
          else this.heard.push(JSON.parse(text));
        });
        ws.send(JSON.stringify(this.state(station)));
      });
    });
  }

  state(station: string) {
    const state: Record<string, unknown> = {
      type: "state", peers: [{ id: station, name: "studio", version: "1" }], workspace: "ws1", workspace_name: "Team", name: "studio",
      origin: this.origin, relay_urls: [], grant_keys: { keys: [this.grant.jwk] }, revocations: [],
    };
    if (this.provider === "comma") state.gateway_keys = this.gateways;
    return state;
  }

  /// A device tool request pushed as Comma does over the presence socket (contract §8, presence transport).
  tool(id: string, request: unknown) {
    for (const ws of this.sockets) ws.send(JSON.stringify({ type: "tool", id, request }));
  }

  /// The roster, gateways and the rest pushed again to every station connected.
  push(station: string) {
    for (const ws of this.sockets) ws.send(JSON.stringify(this.state(station)));
  }

  async start(): Promise<string> {
    await new Promise<void>((resolve) => this.server.listen(0, "127.0.0.1", resolve));
    this.origin = `http://127.0.0.1:${(this.server.address() as AddressInfo).port}`;
    return this.origin;
  }

  async close() {
    for (const ws of this.sockets) ws.terminate();
    this.wss.close();
    this.server.closeAllConnections();
    await new Promise((resolve) => this.server.close(resolve));
  }

  /// The release the station is offered (`<base>/releases/station.json`).
  release = { version: "0.1.9999" };

  private answer(a: Asked): [number, unknown] {
    const comma = this.provider === "comma";
    if (a.method === "GET" && a.path.split("?")[0] === (comma ? "/stations/releases/station.json" : "/releases/station.json")) return [200, this.release];
    if (a.path === (comma ? "/v1/comma/stations/enroll" : "/v1/stations/enroll")) {
      const { token, station, signature } = JSON.parse(a.body.toString());
      const tag = comma ? "comma" : "stillfail";
      if (!checks(station, `${tag}-station-enroll-v1:${this.origin}:${token}:${station}`, signature)) return [401, { error: "invalid_signature" }];
      a.verified.push(tag);
      const answer: Record<string, unknown> = { workspace: "ws1", workspace_name: "Team", name: "studio", station, relay_urls: [], grant_keys: { keys: [this.grant.jwk] } };
      if (comma) Object.assign(answer, { provider: "comma", gateway_keys: this.gateways });
      else answer.relay_url = "";
      return [200, answer];
    }
    // A signed post: by the station in the headers, over its tag and the body's digest.
    const station = String(a.headers["x-stillfail-station"] ?? "");
    const ts = String(a.headers["x-stillfail-ts"] ?? "");
    const digest = sha256hex(a.body);
    const tags = a.path.endsWith("/notify") ? [comma ? "comma-station-notify-v1" : "ember-station-notify-v1"] : ["stillfail-station-telemetry-v1"];
    for (const tag of tags) if (checks(station, `${tag}:${this.origin}:${station}:${ts}:${digest}`, String(a.headers["x-stillfail-signature"] ?? ""))) a.verified.push(tag);
    if (a.headers["x-ember-signature"]) {
      const emberTag = a.path.endsWith("/notify") ? "ember-station-notify-v1" : "ember-station-telemetry-v1";
      if (checks(station, `${emberTag}:${this.origin}:${station}:${ts}:${digest}`, String(a.headers["x-ember-signature"]))) a.verified.push(`ember:${emberTag}`);
    }
    return a.verified.length > 0 ? [200, {}] : [401, { error: "invalid_signature" }];
  }
}
