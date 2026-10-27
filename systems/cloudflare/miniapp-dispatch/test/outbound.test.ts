import { afterEach, describe, expect, test, vi } from "vitest";
import outbound, { type OutboundEnv } from "../src/outbound";

afterEach(() => {
  vi.unstubAllGlobals();
});

function upstream() {
  const sent: Request[] = [];
  vi.stubGlobal("fetch", async (request: Request) => {
    sent.push(request);
    return new Response("upstream");
  });
  return sent;
}

const egress = ["api.open-meteo.com", "evil.comma.surf", "afk.surf"];

describe("outbound Worker", () => {
  test("an https request to a listed host leaves, with redirects returned to the app", async () => {
    const sent = upstream();
    const response = await outbound.fetch(new Request("https://API.open-meteo.com/v1/forecast?lat=1"), { egress, app: "x7k2q9" });
    expect(response.status).toBe(200);
    expect(sent.map((r) => [r.url, r.redirect])).toEqual([["https://api.open-meteo.com/v1/forecast?lat=1", "manual"]]);
  });

  test("Comma hosts, IP literals, local names, other hosts, ports and plain http are blocked", async () => {
    const sent = upstream();
    const env: OutboundEnv = { egress, app: "x7k2q9", MINIAPP_BLOCKED_HOSTS: "corp.example.net" };
    for (const url of [
      "https://evil.comma.surf/",
      "https://afk.surf/",
      "https://salix-vm-gateway-prod.afk.surf/internal/v1/sandboxes",
      "https://127.0.0.1/",
      "https://2130706433/",
      "https://[::1]/",
      "https://169.254.169.254/latest/meta-data",
      "https://localhost/",
      "https://metadata.internal/",
      "https://db.corp.example.net/",
      "https://api.other.com/",
      "https://api.open-meteo.com:8443/",
      "http://api.open-meteo.com/",
    ]) {
      const response = await outbound.fetch(new Request(url), env);
      expect(response.status, url).toBe(403);
      expect(await response.json(), url).toMatchObject({ error: "egress_blocked" });
    }
    expect(sent).toHaveLength(0);
  });

  test("an app without egress hosts reaches nothing", async () => {
    const sent = upstream();
    expect((await outbound.fetch(new Request("https://api.open-meteo.com/"), {})).status).toBe(403);
    expect(sent).toHaveLength(0);
  });

  test("the per-app rate limit refuses requests over the budget", async () => {
    const sent = upstream();
    const keys: string[] = [];
    let remaining = 1;
    const limiter = {
      async limit({ key }: { key: string }) {
        keys.push(key);
        return { success: remaining-- > 0 };
      },
    } as RateLimit;
    const env: OutboundEnv = { egress, app: "x7k2q9", EGRESS_LIMITER: limiter };
    expect((await outbound.fetch(new Request("https://api.open-meteo.com/"), env)).status).toBe(200);
    expect((await outbound.fetch(new Request("https://api.open-meteo.com/"), env)).status).toBe(429);
    expect(keys).toEqual(["x7k2q9", "x7k2q9"]);
    expect(sent).toHaveLength(1);
  });
});
